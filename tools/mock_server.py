#!/usr/bin/env python3
"""OpenAI-compatible mock server for testing Parley. Python 3 standard library only.

Usage:  python3 tools/mock_server.py [PORT]        (default 8765, binds 127.0.0.1 only)
Then point a Parley provider at http://127.0.0.1:8765/v1

Endpoints:
  GET  /v1/models             lists the mock models below
  POST /v1/chat/completions   streams (SSE) a reply; the mode is picked by the model name:
    mock-plain               plain content (also used for unknown model names)
    mock-reasoning-content   reasoning in delta.reasoning_content, then content
    mock-reasoning           reasoning in delta.reasoning, then content
    mock-think-tags          inline <think>...</think>, tags split across chunks
    mock-orphan-think        only a closing </think> (as if the prompt template opened it)
    mock-error               HTTP 400 {"error":{"message":"mock bad request"}}
    mock-stream-error        some content, then a stream-level {"error":{...}} payload
    mock-slow                one token every 200 ms (for testing Stop)

  GET/POST /redirect-to-PORT/REST   answers 307 with Location http://localhost:PORT/REST
                                    (tests that the client never follows redirects)
  POST /v1/chat/completions with model mock-sse-error-field / mock-sse-error-event /
       mock-bare-error / mock-empty: a 200 stream that carries an error as an "error:" SSE
       field, as an "event: error" event, as a bare JSON line, or carries no content at all.

Every reply echoes the last user message text and the number of image_url parts received,
so attachment delivery is visible. Requests are never logged.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = [
    "mock-plain",
    "mock-reasoning-content",
    "mock-reasoning",
    "mock-think-tags",
    "mock-orphan-think",
    "mock-error",
    "mock-stream-error",
    "mock-slow",
    "mock-sse-error-field",
    "mock-sse-error-event",
    "mock-bare-error",
    "mock-empty",
]

SLOW_TOKENS = 50
SLOW_INTERVAL = 0.2


def last_user_message(messages):
    """Returns (text, image_count) for the last user message."""
    for msg in reversed(messages or []):
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            return content, 0
        texts, images = [], 0
        if isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    texts.append(str(part.get("text", "")))
                elif part.get("type") == "image_url":
                    images += 1
        return "\n".join(texts), images
    return "", 0


def split_tokens(text, size=12):
    """Splits text into fixed-size pieces (deliberately not on word boundaries)."""
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ParleyMock/1.0"

    # Privacy: never log requests or content.
    def log_message(self, format, *args):  # noqa: A002
        pass

    # ---- helpers -------------------------------------------------------

    def send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def start_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.wfile.flush()

    def write_chunk(self, text):
        data = text.encode("utf-8")
        if not data:
            return
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def end_stream(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def sse(self, obj, space=True):
        prefix = "data: " if space else "data:"
        self.write_chunk(prefix + json.dumps(obj) + "\n\n")

    def redirect_if_requested(self, path):
        """Handles /redirect-to-PORT/REST with a 307. Returns True if it answered."""
        prefix = "/redirect-to-"
        if not path.startswith(prefix):
            return False
        rest = path[len(prefix):]
        port, _, tail = rest.partition("/")
        self.send_response(307)
        self.send_header("Location", "http://localhost:%s/%s" % (port, tail))
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.wfile.flush()
        return True

    # ---- routing -------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if self.redirect_if_requested(path):
            return
        if path in ("/v1/models", "/models"):
            now = int(time.time())
            self.send_json(200, {
                "object": "list",
                "data": [{"id": m, "object": "model", "created": now, "owned_by": "mock"} for m in MODELS],
            })
        else:
            self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        if self.redirect_if_requested(path):
            return
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self.send_json(404, {"error": {"message": "not found"}})
            return
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": {"message": "invalid JSON body"}})
            return

        model = str(req.get("model") or "mock-plain")
        if model == "mock-error":
            self.send_json(400, {"error": {"message": "mock bad request"}})
            return

        text, images = last_user_message(req.get("messages"))
        echo = 'You said: "%s" (%d image%s received)' % (text, images, "" if images == 1 else "s")

        if req.get("stream") is False:
            self.send_json(200, self.completion(model, echo))
            return

        try:
            self.start_stream()
            self.stream(model, echo)
            self.end_stream()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # The client stopped reading (e.g. the user pressed Stop).
            self.close_connection = True

    # ---- responses -----------------------------------------------------

    def chunk(self, model, delta=None, finish=None):
        return {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}],
        }

    def completion(self, model, content):
        return {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
        }

    def stream(self, model, echo):
        self.write_chunk(": mock stream start\n\n")  # SSE comment
        self.sse(self.chunk(model, {"role": "assistant", "content": ""}))

        completion_tokens = 0

        def content(piece, space=True):
            self.sse(self.chunk(model, {"content": piece}), space=space)

        if model == "mock-reasoning-content":
            for piece in ["Let me think", " about this", " request."]:
                self.sse(self.chunk(model, {"reasoning_content": piece, "content": None}))
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model == "mock-reasoning":
            for piece in ["Considering", " the user's", " message."]:
                self.sse(self.chunk(model, {"reasoning": piece}))
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece, space=False)  # also exercises "data:" without a space
                completion_tokens += 1

        elif model == "mock-think-tags":
            for piece in ["<thi", "nk>Let me", " think...</th", "ink>\n\n"]:
                content(piece)
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model == "mock-orphan-think":
            for piece in ["The user wants", " an echo.</thi", "nk>\n"]:
                content(piece)
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model == "mock-stream-error":
            content("Partial answer")
            self.sse({"error": {"message": "mock stream error", "type": "server_error"}})
            self.write_chunk("data: [DONE]\n\n")
            return

        elif model == "mock-sse-error-field":
            # llama.cpp style: an "error:" field line instead of "data:".
            self.write_chunk('error: {"code": 500, "message": "boom", "type": "server_error"}\n\n')
            return

        elif model == "mock-sse-error-event":
            self.write_chunk('event: error\ndata: {"message": "context length exceeded"}\n\n')
            return

        elif model == "mock-bare-error":
            self.write_chunk('{"error": {"message": "bare failure"}}\n')
            return

        elif model == "mock-empty":
            self.sse(self.chunk(model, {}, finish="stop"))
            self.write_chunk("data: [DONE]\n\n")
            return

        elif model == "mock-slow":
            content(echo + "\n")
            for i in range(1, SLOW_TOKENS + 1):
                time.sleep(SLOW_INTERVAL)
                content("token%d " % i)
                completion_tokens += 1

        else:  # mock-plain and unknown models
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        self.sse(self.chunk(model, {}, finish="stop"))
        self.sse({
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [],
            "usage": {"prompt_tokens": 10, "completion_tokens": completion_tokens, "total_tokens": 10 + completion_tokens},
        })
        self.write_chunk("data: [DONE]\n\n")


def watch_parent():
    """Exit when the launching process goes away, so test runs never leave a server behind."""
    parent = os.getppid()
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            os._exit(0)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=watch_parent, daemon=True).start()
    print("Parley mock server on http://127.0.0.1:%d/v1" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
