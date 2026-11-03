#!/usr/bin/env python3
"""OpenAI-compatible mock server for testing Parley. Python 3 standard library only.

Usage:  python3 tools/mock_server.py [PORT] [FLAVOR] [API_KEY]   (default 8765, binds 127.0.0.1 only)
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
  strata-share   Strata desktop's "share on network" port (apps/host/server/local-share.mjs): only
               GET /v1/models, POST /v1/chat/completions and /v1/messages exist; every other path
               is a 404 with the bare text "Not found". The list says owned_by "strata" and has no
               context field (native mode). A body over 12 MiB gets a plain-text 500 "Request failed".
  strata-engine  Strata's engine server (serve/server.py): GET /health without a key
               (service "strata", max_context, images false), /v1/models without owned_by (status,
               meta.n_ctx, architecture.input_modalities ["text"]), /props (build_info "Strata …").
               Pictures are off: any image is a 400.
  With API_KEY, the Strata flavors want "Authorization: Bearer API_KEY" (or x-api-key) on every
  route but /health and /mock/*, and answer 401 as Strata does. Other flavors ignore the key.

Strata flavors stream as Strata does: ": keep-alive" comments, prompt_progress chunks when the
request has "return_progress": true, reasoning_content, then content, and a last chunk with
finish_reason, usage (always, with prompt_tokens_details.cached_tokens) and llama.cpp timings.
The context is STRATA_CTX tokens (prompt ≈ characters / 4); prompt + max_tokens over it is
shortened (fit_max_tokens, the default) or, for strata-nofit, a 400 with Strata's own text; a
prompt that alone does not fit is always a 400. reasoning_effort "none" turns thinking off.
Models: strata-qwen (normal), strata-nofit, strata-slow (prompt reading for ~2 s, then one
token every 150 ms), strata-loading (share: not in /v1/models, which lists ready models only, and
400 "This model is not ready."; engine: 503 "the engine is starting"), strata-novision (share: images are a 400), strata-length (thinking uses up
max_tokens: no content, finish_reason "length").
GET /mock/last-request (every flavor) returns the last chat request body without its messages
(message_count instead), so tests can check which fields were sent.

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
API_KEY = ""
DEFAULT_LOADED_CONTEXT = 8192
MAX_CONTEXT = 32768
NOT_LOADED_MAX_CONTEXT = 131072
LLAMACPP_N_CTX = 16384
LLAMACPP_N_CTX_TRAIN = 131072

STATE_LOCK = threading.Lock()
# LM Studio-like model state, in memory: key -> {"max": int, "instances": [{"id", "context_length"}]}
LMS_MODELS = {}
COUNTERS = {"chat": 0, "stream_options_rejected": 0, "load": 0, "unload": 0, "get_other": 0}
LAST_REQUEST = {}

STRATA_MODELS = ["strata-qwen", "strata-nofit", "strata-slow", "strata-loading", "strata-novision", "strata-length"]
STRATA_CTX = 8192
STRATA_SLACK = 8               # serve/server.py CTX_SLACK
STRATA_SHARE_BODY_LIMIT = 12 * 1024 * 1024
STRATA_EFFORTS = {"none", "off", "minimal", "disabled", "false", "low", "medium", "high", "xhigh", "max", "maximum"}


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
        if self.mock_control(path):
            return
        if FLAVOR.startswith("strata"):
            self.strata_get(path)
            return
        if self.redirect_if_requested(path):
            return
        if path in ("/models", "/chat/completions"):
            self.send_unexpected_endpoint("GET", path)
        elif path == "/v1/models":
            self.send_json(200, self.openai_model_list())
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
        if FLAVOR.startswith("strata"):
            self.strata_post(path, length)
            return
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
            LAST_REQUEST.clear()
            LAST_REQUEST.update({k: v for k, v in req.items() if k != "messages"})
            LAST_REQUEST["message_count"] = len(req.get("messages") or [])
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

    # ---- mock control (every flavor) -------------------------------------

    def mock_control(self, path):
        if path == "/mock/requests":
            with STATE_LOCK:
                self.send_json(200, dict(COUNTERS))
            return True
        if path == "/mock/last-request":
            with STATE_LOCK:
                self.send_json(200, dict(LAST_REQUEST))
            return True
        return False

    def send_text(self, status, text, content_type=None):
        body = text.encode("utf-8")
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def send_json_utf8(self, status, obj):
        # Node's res.end(JSON) with "application/json; charset=utf-8" (apps/host/server/util.mjs).
        self.send_text(status, json.dumps(obj), "application/json; charset=utf-8")

    # ---- Strata --------------------------------------------------------

    def strata_authorized(self):
        if not API_KEY:
            return True
        auth = self.headers.get("Authorization") or ""
        return auth == "Bearer " + API_KEY or (self.headers.get("x-api-key") or "") == API_KEY

    def strata_unauthorized(self):
        if FLAVOR == "strata-share":
            self.send_json_utf8(401, {"error": "Invalid API key"})
        else:
            self.send_json(401, {"error": {"type": "authentication_error", "message": "missing or wrong API key"}})

    def strata_share_path_ok(self, path):
        if path in ("/v1/models", "/v1/chat/completions", "/v1/messages"):
            return True
        with STATE_LOCK:
            COUNTERS["get_other"] += 1
        self.send_text(404, "Not found")          # res.writeHead(404); res.end('Not found')
        return False

    def strata_share_path_ok_drained(self, path, length):
        if path in ("/v1/models", "/v1/chat/completions", "/v1/messages"):
            return True
        self.drain(length)
        return self.strata_share_path_ok(path)

    def strata_get(self, path):
        if FLAVOR == "strata-share":
            if not self.strata_share_path_ok(path):
                return
            if not self.strata_authorized():
                self.strata_unauthorized()
                return
            if path == "/v1/models":
                self.send_json_utf8(200, {"object": "list", "data": [{
                    "id": m, "object": "model", "owned_by": "strata",
                    "meta": {"instanceId": "inst-%d" % i, "gpus": [0], "label": "Qwen3.8 Flash Next", "aliases": []},
                } for i, m in enumerate(STRATA_MODELS) if m != "strata-loading"]})
            else:
                self.send_json_utf8(404, {"error": "No route for GET %s" % path})
            return
        # strata-engine
        if path in ("/health", "/api/health"):
            self.send_json(200, {"status": "ok", "max_context": STRATA_CTX, "model": "strata-qwen", "images": False,
                                 "api_key": bool(API_KEY), "image_generation": False, "loaded": True, "service": "strata"})
            return
        if not self.strata_authorized():
            self.strata_unauthorized()
            return
        if path in ("/v1/models", "/models"):
            self.send_json(200, {"object": "list", "data": [{
                "id": m, "object": "model", "status": {"value": "loaded" if m == "strata-qwen" else "unloaded"},
                "meta": {"n_ctx": STRATA_CTX},
                "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
            } for m in STRATA_MODELS]})
        elif path == "/props":
            self.send_json(200, {"default_generation_settings": {"n_ctx": STRATA_CTX, "params": {"temperature": 0.6, "n_predict": -1}},
                                 "total_slots": 1, "model_alias": "strata-qwen", "modalities": {"vision": False},
                                 "is_sleeping": False, "build_info": "Strata 0.2.10"})
        else:
            with STATE_LOCK:
                COUNTERS["get_other"] += 1
            self.send_json(404, {"error": {"message": "not found"}})

    def drain(self, length):
        """Reads and drops a request body (answering before it is read can reset the connection)."""
        remaining = length
        while remaining > 0:
            got = self.rfile.read(min(remaining, 1 << 20))
            if not got:
                break
            remaining -= len(got)

    def strata_post(self, path, length):
        # Strata's order (local-share.mjs, index.mjs openai()): path, then key, then the body.
        if FLAVOR == "strata-share" and not self.strata_share_path_ok_drained(path, length):
            return
        if not self.strata_authorized():
            self.drain(length)
            self.strata_unauthorized()
            return
        if FLAVOR == "strata-share" and length > STRATA_SHARE_BODY_LIMIT:
            # readBody throws past 12 MiB, local-share.mjs's catch answers a bare 500.
            self.drain(length)
            self.send_text(500, "Request failed")
            return
        raw = self.rfile.read(length) if length > 0 else b""
        if path != "/v1/chat/completions":
            self.send_json(404, {"error": {"message": "not found"}})
            return
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            if FLAVOR == "strata-share":
                self.send_text(500, "Request failed")
            else:
                self.send_json(400, {"error": {"type": "invalid_request_error", "message": "the request is not JSON"}})
            return
        model = str(req.get("model") or "strata-qwen")
        messages = req.get("messages") or []
        with STATE_LOCK:
            COUNTERS["chat"] += 1
            LAST_REQUEST.clear()
            LAST_REQUEST.update({k: v for k, v in req.items() if k != "messages"})
            LAST_REQUEST["message_count"] = len(messages)

        def invalid(message, status=400):
            self.send_json(status, {"error": {"type": "invalid_request_error", "message": message}})

        if model == "strata-loading":
            if FLAVOR == "strata-share":
                self.send_json(400, {"error": {"message": "This model is not ready.", "type": "invalid_request_error",
                                               "param": "model", "code": None}})
            else:
                self.send_json(503, {"error": {"type": "server_error",
                                               "message": "the engine is starting (a minute or two); try again shortly"}})
            return
        effort = req.get("reasoning_effort")
        if effort is not None and effort is not False and str(effort).strip().lower() not in STRATA_EFFORTS:
            invalid("unknown reasoning effort %r: use none, low, medium or high" % effort)
            return
        budget = req.get("reasoning_budget_tokens")
        if budget is not None and (isinstance(budget, bool) or not isinstance(budget, int)):
            invalid("reasoning_budget_tokens=%r: expected a whole number of tokens (0: no budget)" % budget)
            return
        images = sum(1 for m in messages if isinstance(m, dict) and isinstance(m.get("content"), list)
                     for part in m["content"] if isinstance(part, dict) and part.get("type") == "image_url")
        if images and (FLAVOR == "strata-engine" or model == "strata-novision"):
            invalid("this server was started without the vision encoder (run setup again and choose 'vision'), "
                    "so it cannot read images")
            return

        prompt = 0
        for m in messages:
            content = m.get("content") if isinstance(m, dict) else ""
            if isinstance(content, list):
                content = " ".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
            prompt += 4 + len(str(content or "")) // 4
        room = STRATA_CTX - STRATA_SLACK - prompt
        max_new = req.get("max_tokens", req.get("max_completion_tokens"))
        if not isinstance(max_new, int) or isinstance(max_new, bool) or max_new <= 0:
            max_new = None
        if room < 1:
            invalid("request exceeds the context window: prompt (%d tokens) leaves no room to answer in the context "
                    "(%d); requests are never truncated" % (prompt, STRATA_CTX))
            return
        if max_new is None:
            max_new = room
        elif max_new > room:
            if model == "strata-nofit":
                invalid("request exceeds the context window: prompt (%d tokens) + max tokens (%d) exceeds the context "
                        "(%d); requests are never truncated. Send a smaller max_tokens (at most %d here), or add "
                        "\"fit_max_tokens\": true to the model's strata-<model>.json to shorten it to the room left (#545)"
                        % (prompt, max_new, STRATA_CTX, max(0, room)))
                return
            max_new = max(1, room)

        text, _ = last_user_message(messages)
        echo = 'You said: "%s" (%d image%s received)' % (text, images, "" if images == 1 else "s")
        thinking = effort is None or not (effort is False or str(effort).strip().lower() in ("none", "off", "minimal", "disabled", "false"))
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.flush()
            self.strata_stream(req, model, echo, prompt, max_new, thinking)
            self.end_stream()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    def strata_stream(self, req, model, echo, prompt, max_new, thinking):
        cid = "chatcmpl-" + "0" * 24
        created = int(time.time())

        def chunk(delta, finish=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": created, "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

        slow = model == "strata-slow"
        self.sse(chunk({"role": "assistant", "content": ""}))
        cached = prompt // 2
        if slow:
            # A long conversation, mostly in Strata's cache (as the snapshot harness shows it).
            prompt, cached = max(prompt, 40960), 30000
        steps = 8 if slow else 2
        for i in range(1, steps + 1):
            # One keep-alive per prompt-reading line; the progress fills it in when asked for.
            if req.get("return_progress"):
                processed = cached + (prompt - cached) * i // (steps + 1)
                self.sse({**chunk({}), "prompt_progress": {"total": prompt, "cache": cached, "processed": processed,
                                                           "time_ms": 250 * i}})
            else:
                self.write_chunk(": keep-alive\n\n")
            if slow:
                time.sleep(0.25)

        generated = 0
        thoughts = ["The user", " wants an", " echo."]
        if model == "strata-length":
            thoughts = ["Let me", " think", " about", " this", " at", " length"]
        if thinking:
            for piece in thoughts:
                if generated >= max_new:
                    break
                self.sse(chunk({"reasoning_content": piece}))
                generated += 1
        finish = "stop"
        if model == "strata-length":
            finish = "length"
        else:
            for piece in split_tokens(echo, 6 if slow else 12):
                if generated >= max_new:
                    finish = "length"
                    break
                self.sse(chunk({"content": piece}))
                generated += 1
                if slow:
                    time.sleep(0.15)
        last = chunk({}, finish)
        last["usage"] = {"prompt_tokens": prompt, "completion_tokens": generated, "total_tokens": prompt + generated,
                         "prompt_tokens_details": {"cached_tokens": cached}}
        prompt_ms = 2.0 * (prompt - cached) + 1
        last["timings"] = {"cache_n": cached, "prompt_n": prompt - cached, "prompt_ms": prompt_ms,
                           "prompt_per_token_ms": prompt_ms / max(1, prompt - cached),
                           "prompt_per_second": 1000.0 * (prompt - cached) / prompt_ms,
                           "predicted_n": generated, "predicted_ms": 1000.0 * generated / 61.5,
                           "predicted_per_token_ms": 1000.0 / 61.5, "predicted_per_second": 61.5}
        self.sse(last)
        self.write_chunk("data: [DONE]\n\n")

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
    global FLAVOR, API_KEY
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    if len(sys.argv) > 2:
        FLAVOR = sys.argv[2]
        if FLAVOR not in ("lmstudio", "lmstudio-v0", "llamacpp", "vllm", "ollama", "plain", "strata-share", "strata-engine"):
            sys.exit("unknown flavor: %s" % FLAVOR)
    if len(sys.argv) > 3:
        API_KEY = sys.argv[3]
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
