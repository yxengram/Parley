#!/usr/bin/env python3
"""OpenAI-compatible mock server for testing Parley. Python 3 standard library only.

Usage:  python3 tools/mock_server.py [PORT] [FLAVOR]   (default 8765, binds 127.0.0.1 only)
Then point a Parley provider at http://127.0.0.1:8765/v1

FLAVOR picks which native (non-OpenAI) endpoints exist, for context-length discovery:
  lmstudio     (default) LM Studio 0.4: GET /api/v1/models and /api/v0/models, POST
               /api/v1/models/load and /unload (change the in-memory loaded context length).
               Unknown routes such as /props answer 200 {"error":"Unexpected endpoint…"}.
  lmstudio-v0  LM Studio before 0.4: only /api/v0/models; /api/v1/* answers 200 {"error":…}.
  llamacpp     llama.cpp: GET /props (n_ctx), /v1/models with owned_by "llamacpp" and meta.
  vllm         vLLM: /v1/models entries carry owned_by "vllm" and max_model_len.
  ollama       Ollama: GET /api/ps lists running models with context_length.
  plain        none of the above (like a hosted API): native routes are 404.

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
    mock-slow-think          reasoning_content then content, one piece every 150 ms
                             (snapshot harness: captures thinking mid-stream)

  GET /models, POST /chat/completions (no /v1)   mimic LM Studio's answer to an unknown
                             endpoint: HTTP 200 {"error":"Unexpected endpoint or method. (...)"}

  GET/POST /redirect-to-PORT/REST   answers 307 with Location http://localhost:PORT/REST
                                    (tests that the client never follows redirects)
  POST /v1/chat/completions with model mock-sse-error-field / mock-sse-error-event /
       mock-bare-error / mock-empty: a 200 stream that carries an error as an "error:" SSE
       field, as an "event: error" event, as a bare JSON line, or carries no content at all.

Usage and timing:
  stream_options {"include_usage": true} adds a final usage chunk (choices: []); without it no
  usage is sent.
  mock-no-stream-options   HTTP 400 "Unrecognized request argument supplied: stream_options"
                           whenever the request has stream_options; a plain reply otherwise
  mock-timings             the last chunk carries llama.cpp-style "timings"
  mock-notloaded           listed by LM Studio endpoints as not loaded
  GET /mock/requests       counters: chat requests, stream_options rejections, loads, unloads

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
    "mock-slow-think",
    "mock-sse-error-field",
    "mock-sse-error-event",
    "mock-bare-error",
    "mock-empty",
    "mock-no-stream-options",
    "mock-timings",
    "mock-notloaded",
]

FLAVOR = "lmstudio"
DEFAULT_LOADED_CONTEXT = 8192
MAX_CONTEXT = 32768
NOT_LOADED_MAX_CONTEXT = 131072
LLAMACPP_N_CTX = 16384
LLAMACPP_N_CTX_TRAIN = 131072

STATE_LOCK = threading.Lock()
# LM Studio-like model state, in memory: key -> {"max": int, "instances": [{"id", "context_length"}]}
LMS_MODELS = {}
COUNTERS = {"chat": 0, "stream_options_rejected": 0, "load": 0, "unload": 0}


def reset_lms_state():
    LMS_MODELS.clear()
    for m in MODELS:
        if m == "mock-notloaded":
            LMS_MODELS[m] = {"max": NOT_LOADED_MAX_CONTEXT, "instances": []}
        else:
            LMS_MODELS[m] = {"max": MAX_CONTEXT, "instances": [{"id": m, "context_length": DEFAULT_LOADED_CONTEXT}]}


reset_lms_state()


def lms_v1_listing():
    with STATE_LOCK:
        return {"models": [{
            "type": "llm",
            "publisher": "mock",
            "key": key,
            "display_name": key,
            "architecture": "mock",
            "quantization": {"name": "Q4_K_M", "bits_per_weight": 4},
            "size_bytes": 1000,
            "params_string": "1B",
            "loaded_instances": [{
                "id": inst["id"],
                "config": {"context_length": inst["context_length"], "eval_batch_size": 512,
                           "parallel": 4, "flash_attention": True, "offload_kv_cache_to_gpu": True},
                "remaining_ttl_seconds": 3600,
            } for inst in state["instances"]],
            "max_context_length": state["max"],
            "format": "gguf",
            "capabilities": {"vision": False, "trained_for_tool_use": False},
        } for key, state in LMS_MODELS.items()]}


def lms_v0_listing():
    with STATE_LOCK:
        data = []
        for key, state in LMS_MODELS.items():
            entry = {"id": key, "object": "model", "type": "llm", "publisher": "mock", "arch": "mock",
                     "compatibility_type": "gguf", "quantization": "Q4_K_M",
                     "state": "loaded" if state["instances"] else "not-loaded",
                     "max_context_length": state["max"]}
            if state["instances"]:
                entry["loaded_context_length"] = state["instances"][0]["context_length"]
            data.append(entry)
        return {"object": "list", "data": data}

SLOW_TOKENS = 50
SLOW_INTERVAL = 0.2
SLOW_THINK_INTERVAL = 0.15


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

    def send_unexpected_endpoint(self, method, path):
        # LM Studio answers a request without the /v1 prefix with 200 and an error body.
        self.send_json(200, {"error": f"Unexpected endpoint or method. ({method} {path})"})

    # ---- routing -------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if self.redirect_if_requested(path):
            return
        if path in ("/models", "/chat/completions"):
            self.send_unexpected_endpoint("GET", path)
        elif path == "/v1/models":
            self.send_json(200, self.openai_model_list())
        elif path == "/mock/requests":
            with STATE_LOCK:
                self.send_json(200, dict(COUNTERS))
        elif self.native_get(path):
            pass
        else:
            self.send_json(404, {"error": {"message": "not found"}})

    def openai_model_list(self):
        now = int(time.time())
        data = []
        for m in MODELS:
            entry = {"id": m, "object": "model", "created": now, "owned_by": "mock"}
            if FLAVOR in ("lmstudio", "lmstudio-v0"):
                entry["owned_by"] = "organization_owner"
            elif FLAVOR == "llamacpp":
                entry["owned_by"] = "llamacpp"
                entry["meta"] = {"vocab_type": 2, "n_vocab": 151936, "n_ctx": LLAMACPP_N_CTX,
                                 "n_ctx_train": LLAMACPP_N_CTX_TRAIN, "n_embd": 2048, "n_params": 1000, "size": 1000}
            elif FLAVOR == "vllm":
                entry["owned_by"] = "vllm"
                entry["root"] = m
                entry["parent"] = None
                entry["max_model_len"] = MAX_CONTEXT
            data.append(entry)
        return {"object": "list", "data": data}

    def native_get(self, path):
        """Flavor-specific native endpoints. Returns True if it answered."""
        if FLAVOR == "lmstudio":
            if path == "/api/v1/models":
                self.send_json(200, lms_v1_listing())
                return True
            if path == "/api/v0/models":
                self.send_json(200, lms_v0_listing())
                return True
            if path.startswith("/api/") or path == "/props":
                self.send_unexpected_endpoint("GET", path)
                return True
        elif FLAVOR == "lmstudio-v0":
            if path == "/api/v0/models":
                self.send_json(200, lms_v0_listing())
                return True
            if path.startswith("/api/") or path == "/props":
                self.send_unexpected_endpoint("GET", path)
                return True
        elif FLAVOR == "llamacpp" and path == "/props":
            self.send_json(200, {
                "default_generation_settings": {"n_ctx": LLAMACPP_N_CTX, "params": {"temperature": 0.8}},
                "total_slots": 1, "model_path": "/models/mock.gguf", "modalities": {"vision": False},
                "build_info": "b0-mock", "is_sleeping": False,
            })
            return True
        elif FLAVOR == "ollama" and path == "/api/ps":
            self.send_json(200, {"models": [{
                "name": "mock-plain:latest", "model": "mock-plain:latest", "size": 1000, "digest": "0" * 64,
                "details": {"family": "mock"}, "expires_at": "2099-01-01T00:00:00Z", "size_vram": 1000,
                "context_length": 4096,
            }]})
            return True
        return False

    def lms_load(self, req):
        key = str(req.get("model") or "")
        try:
            ctx = int(req.get("context_length") or DEFAULT_LOADED_CONTEXT)
        except (TypeError, ValueError):
            self.send_json(400, {"error": {"message": "context_length must be an integer"}})
            return
        with STATE_LOCK:
            COUNTERS["load"] += 1
            state = LMS_MODELS.get(key)
            if state is None:
                result = (404, {"error": {"message": "Model not found: %s" % key}})
            elif ctx < 1 or ctx > state["max"]:
                result = (400, {"error": {"message": "context_length %d is out of range (max %d)" % (ctx, state["max"])}})
            else:
                # Like LM Studio: loading a loaded model adds another instance ("key:2").
                ids = {i["id"] for i in state["instances"]}
                instance_id, n = key, 2
                while instance_id in ids:
                    instance_id, n = "%s:%d" % (key, n), n + 1
                state["instances"].append({"id": instance_id, "context_length": ctx})
                body = {"type": "llm", "instance_id": instance_id, "load_time_seconds": 0.01, "status": "loaded"}
                if req.get("echo_load_config"):
                    body["load_config"] = {"context_length": ctx, "eval_batch_size": 512,
                                           "flash_attention": True, "offload_kv_cache_to_gpu": True}
                result = (200, body)
        self.send_json(*result)

    def lms_unload(self, req):
        instance_id = str(req.get("instance_id") or "")
        with STATE_LOCK:
            COUNTERS["unload"] += 1
            for state in LMS_MODELS.values():
                before = len(state["instances"])
                state["instances"] = [i for i in state["instances"] if i["id"] != instance_id]
                if len(state["instances"]) != before:
                    result = (200, {"instance_id": instance_id})
                    break
            else:
                result = (404, {"error": {"message": "No loaded instance: %s" % instance_id}})
        self.send_json(*result)

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        if self.redirect_if_requested(path):
            return
        if path in ("/models", "/chat/completions"):
            self.send_unexpected_endpoint("POST", path)
            return
        if FLAVOR == "lmstudio" and path in ("/api/v1/models/load", "/api/v1/models/unload"):
            try:
                req = json.loads(raw.decode("utf-8") or "{}")
            except (ValueError, UnicodeDecodeError):
                self.send_json(400, {"error": {"message": "invalid JSON body"}})
                return
            if path.endswith("/load"):
                self.lms_load(req)
            else:
                self.lms_unload(req)
            return
        if path != "/v1/chat/completions":
            self.send_json(404, {"error": {"message": "not found"}})
            return
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": {"message": "invalid JSON body"}})
            return

        model = str(req.get("model") or "mock-plain")
        with STATE_LOCK:
            COUNTERS["chat"] += 1
        if model == "mock-no-stream-options" and "stream_options" in req:
            with STATE_LOCK:
                COUNTERS["stream_options_rejected"] += 1
            self.send_json(400, {"error": {"message": "Unrecognized request argument supplied: stream_options",
                                           "type": "invalid_request_error", "param": None, "code": None}})
            return
        if model == "mock-error":
            self.send_json(400, {"error": {"message": "mock bad request"}})
            return

        text, images = last_user_message(req.get("messages"))
        echo = 'You said: "%s" (%d image%s received)' % (text, images, "" if images == 1 else "s")

        if req.get("stream") is False:
            self.send_json(200, self.completion(model, echo))
            return

        try:
            options = req.get("stream_options")
            include_usage = isinstance(options, dict) and options.get("include_usage") is True
            self.start_stream()
            self.stream(model, echo, include_usage)
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

    def stream(self, model, echo, include_usage=False):
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

        elif model == "mock-slow-think":
            thoughts = ("The user wants a migration plan. Core Data and SwiftData can share one "
                        "store file, so the safest order is: model parity first, then read paths, "
                        "then write paths, with a feature flag at each step.")
            for piece in split_tokens(thoughts, 9):
                self.sse(self.chunk(model, {"reasoning_content": piece, "content": None}))
                completion_tokens += 1
                time.sleep(SLOW_THINK_INTERVAL)
            for piece in split_tokens(echo, 6):
                content(piece)
                completion_tokens += 1
                time.sleep(SLOW_THINK_INTERVAL)

        else:  # mock-plain and unknown models
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        final = self.chunk(model, {}, finish="stop")
        if model == "mock-timings":
            # llama.cpp attaches its own measurements to the last chunk.
            final["timings"] = {"cache_n": 0, "prompt_n": 10, "prompt_ms": 12.5, "prompt_per_token_ms": 1.25,
                                "prompt_per_second": 800.0, "predicted_n": completion_tokens,
                                "predicted_ms": 1000.0 * completion_tokens / 123.4,
                                "predicted_per_token_ms": 1000.0 / 123.4, "predicted_per_second": 123.4}
        self.sse(final)
        if include_usage:
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
    global FLAVOR
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    if len(sys.argv) > 2:
        FLAVOR = sys.argv[2]
        if FLAVOR not in ("lmstudio", "lmstudio-v0", "llamacpp", "vllm", "ollama", "plain"):
            sys.exit("unknown flavor: %s" % FLAVOR)
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=watch_parent, daemon=True).start()
    print("Parley mock server (%s) on http://127.0.0.1:%d/v1" % (FLAVOR, server.server_address[1]), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
