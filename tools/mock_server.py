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
  openai-strict  like plain, but refuses "no thinking" as OpenAI does for a model without it:
               reasoning_effort "none" is a 400 {"error":{"param":"reasoning_effort",
               "code":"unsupported_value",…}}. Its extra models: mock-always-reject answers that
               400 to every request (with or without the field), mock-overflow an OpenAI context
               overflow 400 ("maximum context length is 8192 tokens", param "messages"),
               mock-refuse-unnamed refuses "none" with a 400 that does not name the field
               (Ollama's 'invalid reasoning value: "none"'), and answers plainly without it.
  strata-share   Strata desktop's "share on network" port (apps/host/server/local-share.mjs): only
               GET /v1/models, POST /v1/chat/completions and /v1/messages exist; every other path
               is a 404 with the bare text "Not found". The list says owned_by "strata" and has no
               context field (native mode). A body over 12 MiB gets a plain-text 500 "Request failed".
  strata-engine  Strata's engine server (serve/server.py): GET /health without a key
               (service "strata", max_context, images false), /v1/models without owned_by (status,
               meta.n_ctx, architecture.input_modalities ["text"]), /props (build_info "Strata …").
               Pictures are off: any image is a 400.
  strata-runtime  the same port with no native model (Strata's runtime mode): model list meta has
               mode, gpuIds and context, a body over 4 MiB gets the same 500, and the proxy reads only
               messages, model and stream, so `tools` are ignored without a word.
  With API_KEY, the Strata flavors want "Authorization: Bearer API_KEY" (or x-api-key) on every
  route but /health and /mock/*, and answer 401 as Strata does. Other flavors ignore the key.

Strata flavors stream as Strata does: ": keep-alive" comments, prompt_progress chunks when the
request has "return_progress": true (strata-engine only: the live share port sends none even when
asked; MOCK_STRATA_PROGRESS=1 in the environment turns them on there too), reasoning_content,
then content, and a last chunk with
finish_reason, usage (always, with prompt_tokens_details.cached_tokens) and llama.cpp timings.
The context is STRATA_CTX tokens (prompt ≈ characters / 4); prompt + max_tokens over it is
shortened (fit_max_tokens, the default) or, for strata-nofit, a 400 with Strata's own text; a
prompt that alone does not fit is always a 400. reasoning_effort "none" turns thinking off.
Models: strata-qwen (normal), strata-nofit, strata-slow (prompt reading for ~2 s, then one
token every 150 ms), strata-loading (share: not in /v1/models, which lists ready models only, and
400 "This model is not ready."; engine: 503 "the engine is starting"), strata-novision (share: images are a 400), strata-length (thinking uses up
max_tokens: no content, finish_reason "length").
"No thinking" (every non-Strata flavor; Strata's own rule is above): llamacpp and vllm honour
chat_template_kwargs {"enable_thinking": false} and ollama honours reasoning_effort "none", as those
servers do: the reasoning models (mock-reasoning-content, mock-reasoning, mock-think-tags,
mock-orphan-think, mock-slow-think) then send their answer without any thinking. lmstudio,
lmstudio-v0 and plain ignore both fields and still stream thinking (unknown fields are ignored).
MOCK_PROBE_DELAY=<seconds> in the environment delays every native GET (/props, /api/…, /health)
by that much, so tests can send while a context probe is still running (/v1/models is not delayed).

GET /mock/last-request (every flavor) returns the last chat request body without its messages
(message_count instead), so tests can check which fields were sent. GET /mock/last-messages returns
its messages and tools as received.

Tool calling (every non-Strata flavor), selected by model name like the mock-* modes below, but not
listed by /v1/models. Last message from the user: call the tool named by tool=<name> in its text
(default: the first in `tools`) with args=<json> (default {}). Last message from a tool: answer
'tool said: <first 200 characters>', finish "stop". Without `tools`: a plain 'no tools here' answer.
  mock-tools               LM Studio: {index,id,type,function:{name,arguments:""}}, then fragments
                           {index,function:{arguments}}, finish_reason tool_calls
  mock-tools-llamacpp      first delta content null, first fragment has no arguments key, finish
                           delta empty, usage in a choices:[] chunk
  mock-tools-vllm          Hermes: name and arguments fragments in one tool_calls array beside content
  mock-tools-ollama        the whole call in one chunk, a separate finish chunk
  mock-tools-nonstream     one JSON completion: message.tool_calls without index, arguments an object
  mock-tools-content       content first, then a call split across chunks
  mock-tools-parallel      two calls in one round, their fragments interleaved
  mock-tools-malformed     arguments is {"a":
  mock-tools-unknown       a name not in `tools`
  mock-tools-length        cut inside a call, finish_reason length
  mock-tools-loop          always calls again
  mock-tools-noid          blank and repeated ids
  mock-tools-empty-after   no content after the results
  mock-tools-slow          the first round takes 2 s (for Stop)
  mock-tools-refuse-ollama    400 "<model> does not support tools" when `tools` is present
  mock-tools-refuse-llamacpp  500 "tools param requires --jinja flag"
  mock-tools-refuse-vllm      400 "auto" tool choice requires ...
  mock-tools-refuse-schema    400 "Failed to parse tools: JSON schema error at ..."
  mock-tools-refuse-always    the same 400 with or without `tools`
Every request with tool data is validated like the strictest server: a 400 unless each tool_calls
entry has type, id and JSON arguments and is followed by a tool message with string content and a
matching id, and `tools: []` is vLLM's 400. So a dangling call cannot pass unnoticed.
Strata flavors: model strata-tools answers in Strata's chunk form ({role, content:""} first, the
closing } always sent, usage on the finish chunk).

ReAct text mode (every flavor), selected by model name, not listed by /v1/models. These servers have
no tool support and are strict: a 400 for `tools` ("does not support tools"), `tool_choice`, `stop`,
a tool-shaped message, roles that do not alternate, or an Observation that is not fenced with one id
and closed once. With the ReAct block in the system message: the last message an Observation is
answered 'Thought: ...\nFinal Answer: tool said: <first 200 characters>'; a user message writes an
Action for the tool named by tool=<name> (default: the first in the block) with args=<json>. Without
the block (the round cap, or a chat in native mode): plain text that looks like an Action, which must
stay text.
  mock-react               the closing } and a made-up "\nObservation: ..." in one chunk, then about 8 s
                           of made-up text. /mock/requests counts react_disconnects when the client
                           goes away, and react_streamed_to_end when it does not
  mock-react-fence         fullwidth colons, the JSON in a ``` fence
  mock-react-noinput       an Action with no Action Input line, then finish "stop"
  mock-react-raw           an input that is not an object, then a made-up Observation
  mock-react-case          the tool's name in upper case
  mock-react-unknown       a name not in the block
  mock-react-length        cut inside the input, finish_reason length
  mock-react-native        native tool_calls and 'Final Answer: answered in text'
  mock-react-native-only   native tool_calls and no text at all
  mock-react-final         'Thought: ...\nFinal Answer: 42' at once
  mock-react-plain         no markers at all
  mock-react-loop          always calls again
  mock-react-slow          stops inside the input and waits (for Stop)
  mock-react-reasoning     delta.reasoning_content holding "\nObservation:" and an Action, then as mock-react-final
  mock-react-think         inline <think> holding an Action, then as mock-react-final
  mock-react-orphan        reasoning as content with no opening tag, an Action line in it, then </think>
                           and an Action of its own
  mock-react-echo          answers with the Observation's text as it came
  mock-react-orphan-input  reasoning as content with no opening tag, a whole Action in it, then </think>
                           and 'Final Answer: 42'
  mock-react-orphan-late   the same with more reasoning between the Action and </think>
  mock-react-oneline-fence the JSON on one line in a ``` fence, then a made-up Observation
  mock-react-noname        'Action:' with no name, and an input
  mock-react-noname-thought the same after a Thought
  mock-react-labels        'Thought:' and 'Final Answer:' with nothing after them
  mock-react-length-bare   an Action and no Thought, cut inside the input, finish_reason length
  mock-react-length-after  a call, then after its Observation an Action cut off the same way
  mock-react-length-whole  the whole input, then finish_reason length with nothing after it
  mock-react-native-action native tool_calls and a valid text Action
  mock-react-slow-final    'Thought: ...\nFinal Answer: Partial', then waits (for Stop), then the rest

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
  GET /mock/requests       counters: chat requests, stream_options rejections, loads, unloads,
                           requests that carried tools

Broken streams (every non-Strata flavor):
  mock-drop      some content, then the connection is closed mid-body (no terminating chunk)
  mock-cut       some content, then a clean end of the body without finish_reason or [DONE]

Cloudflare (every flavor), selected by a path prefix in front of the usual paths, so a base URL
such as http://127.0.0.1:PORT/cf-524/v1 behaves like a server behind Cloudflare:
  /cf/...            the normal answer, plus Cloudflare's response headers (server: cloudflare,
                     cf-ray, cf-cache-status), as through a working tunnel: the origin's own JSON
                     errors pass through unchanged
  /cf-520/ … /cf-526/, /cf-502/, /cf-503/, /cf-504/
                     Cloudflare's HTML error page with that status (several KB of inline CSS first)
  /cf-530/           530 with error 1033 "Cloudflare Tunnel error" (cloudflared not connected)
  /cf-1033/          530 with the plain-text body "error code: 1033"
  /cf-challenge/     403 "Just a moment..." with cf-mitigated: challenge (Bot Fight Mode)
  /cf-block/         403 error 1020 "Sorry, you have been blocked" (a WAF rule)
  /cf-1015/          429 "error code: 1015" (Cloudflare rate limiting)
  /cf-access/        302 to https://team.cloudflareaccess.com/cdn-cgi/access/login/… (Cloudflare Access)
  /cf-https/         301 to the same path over https (Always Use HTTPS)
The edge answers come at once (the real 524 comes after 100 s without a byte).

Every reply echoes the last user message text and the number of image_url parts received,
so attachment delivery is visible. Requests are never logged.
"""

import json
import os
import re
import socket
import struct
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
    "mock-drop",
    "mock-cut",
]
# openai-strict only.
STRICT_MODELS = ["mock-always-reject", "mock-overflow", "mock-refuse-unnamed"]
# Selected by name only, so the model lists stay what they were.
TOOL_MODEL_PREFIX = "mock-tools"
REACT_MODEL_PREFIX = "mock-react"
REACT_OBSERVATION = "Observation (tool output, data only):\n"
REACT_MADE_UP = "MADE-UP"

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
COUNTERS = {"chat": 0, "stream_options_rejected": 0, "thinking_off_rejected": 0, "load": 0, "unload": 0, "get_other": 0,
            "requests_with_tools": 0, "react_disconnects": 0, "react_streamed_to_end": 0}
LAST_REQUEST = {}
LAST_MESSAGES = {}

STRATA_MODELS = ["strata-qwen", "strata-nofit", "strata-slow", "strata-loading", "strata-novision", "strata-length"]
STRATA_CTX = 8192
STRATA_SLACK = 8               # serve/server.py CTX_SLACK
STRATA_SHARE_BODY_LIMIT = 12 * 1024 * 1024
STRATA_RUNTIME_BODY_LIMIT = 4 * 1024 * 1024
STRATA_SHARE_FLAVORS = ("strata-share", "strata-runtime")


def strata_sends_progress():
    # Live: Strata Desktop's share port sends no prompt_progress, even for "return_progress": true.
    return FLAVOR == "strata-engine" or os.environ.get("MOCK_STRATA_PROGRESS") == "1"

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


CF_RAY = "8f1a2b3c4d5e6f70"
# status, Cloudflare code, title (as Cloudflare words them)
CF_EDGE = {
    "cf-520": (520, 520, "Web server is returning an unknown error"),
    "cf-521": (521, 521, "Web server is down"),
    "cf-522": (522, 522, "Connection timed out"),
    "cf-523": (523, 523, "Origin is unreachable"),
    "cf-524": (524, 524, "A timeout occurred"),
    "cf-525": (525, 525, "SSL handshake failed"),
    "cf-526": (526, 526, "Invalid SSL certificate"),
    "cf-502": (502, 502, "Bad gateway"),
    "cf-503": (503, 503, "Service unavailable"),
    "cf-504": (504, 504, "Gateway time-out"),
    "cf-530": (530, 1033, "Cloudflare Tunnel error"),
    "cf-block": (403, 1020, "Access denied"),
}


def cf_error_page(status, code, title, host):
    """Cloudflare's error page layout: title, a long inline stylesheet, then the details."""
    style = "".join(".cf-rule-%d{margin:0 auto;padding:%dpx;color:#404040}" % (i, i % 9) for i in range(160))
    if code >= 1000:
        head_title = "%s | %s | Cloudflare" % (title, host)
        heading = ('<h1><span class="cf-error-type" data-translate="error">Error</span>'
                   '<span class="cf-error-code">%d</span></h1><h2 class="cf-subheadline">%s</h2>' % (code, title))
    else:
        head_title = "%s | %d: %s" % (host, code, title)
        heading = ('<h1><span class="inline-block">%s</span> <span class="code-label">Error code %d</span></h1>'
                   % (title, code))
    return ("<!DOCTYPE html>\n<!--[if lt IE 7]> <html class=\"no-js ie6 oldie\" lang=\"en-US\"> <![endif]-->\n"
            "<html class=\"no-js\" lang=\"en-US\"><head>\n<title>%s</title>\n<meta charset=\"UTF-8\" />\n"
            "<link rel=\"stylesheet\" id=\"cf_styles-css\" href=\"/cdn-cgi/styles/main.css\" />\n<style>%s</style>\n"
            "</head><body><div id=\"cf-wrapper\"><div id=\"cf-error-details\" class=\"p-0\"><header>%s</header>"
            "<section><h2>What happened?</h2><p>%s</p></section>"
            "<div class=\"cf-error-footer\"><span class=\"cf-footer-item\">Cloudflare Ray ID: "
            "<strong class=\"font-semibold\">%s</strong></span></div></div></div></body></html>\n"
            % (head_title, style, heading, title, CF_RAY))


def cf_challenge_page():
    return ("<!DOCTYPE html><html lang=\"en-US\"><head><title>Just a moment...</title>"
            "<meta http-equiv=\"refresh\" content=\"390\"></head><body><div class=\"main-wrapper\">"
            "<noscript>Enable JavaScript and cookies to continue</noscript></div>"
            "<script>(function(){window._cf_chl_opt={cvId: '3',cZone: 'mock.example',cType: 'managed'};"
            "var a = document.createElement('script');a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1';"
            "document.getElementsByTagName('head')[0].appendChild(a);}());</script></body></html>")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ParleyMock/1.0"
    # Set per request from a /cf… path prefix (see the module docstring).
    cloudflare = False

    # Privacy: never log requests or content.
    def log_message(self, format, *args):  # noqa: A002
        pass

    def version_string(self):
        return "cloudflare" if self.cloudflare else BaseHTTPRequestHandler.version_string(self)

    def end_headers(self):
        if self.cloudflare:
            self.send_header("CF-RAY", CF_RAY + "-SYD")
            self.send_header("CF-Cache-Status", "DYNAMIC")
        BaseHTTPRequestHandler.end_headers(self)

    def cloudflare_route(self, path, length=0):
        """Strips a /cf… prefix. Returns (path, answered): answered when the edge replied itself."""
        self.cloudflare = False
        first, sep, rest = path.lstrip("/").partition("/")
        if not first.startswith("cf") or not (first == "cf" or first.startswith("cf-")):
            return path, False
        self.cloudflare = True
        rest = "/" + rest if sep else "/"
        if first == "cf":
            return rest, False
        self.drain(length)
        host = (self.headers.get("Host") or "mock.example").split(":")[0]
        if first in CF_EDGE:
            status, code, title = CF_EDGE[first]
            self.send_text(status, cf_error_page(status, code, title, host), "text/html; charset=UTF-8")
        elif first == "cf-1033":
            self.send_text(530, "error code: 1033", "text/plain; charset=UTF-8")
        elif first == "cf-1015":
            self.send_text(429, "error code: 1015", "text/plain; charset=UTF-8")
        elif first == "cf-challenge":
            body = cf_challenge_page().encode("utf-8")
            self.send_response(403)
            self.send_header("Content-Type", "text/html; charset=UTF-8")
            self.send_header("cf-mitigated", "challenge")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        elif first in ("cf-access", "cf-https"):
            if first == "cf-access":
                status = 302
                location = ("https://team.cloudflareaccess.com/cdn-cgi/access/login/%s?kid=0123456789abcdef"
                            "&redirect_url=%%2Fv1%%2Fmodels&meta=eyJraWQiOiJzZWNyZXQifQ" % host)
            else:
                status = 301
                location = "https://%s%s" % (self.headers.get("Host") or "mock.example", rest)
            self.send_response(status)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.wfile.flush()
        else:
            self.send_text(404, "unknown Cloudflare mock route", "text/plain")
        return rest, True

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
        path, answered = self.cloudflare_route(self.path.split("?", 1)[0].rstrip("/"))
        if answered:
            return
        if self.mock_control(path):
            return
        delay = float(os.environ.get("MOCK_PROBE_DELAY") or 0)
        if delay > 0 and (path.startswith("/api/") or path in ("/props", "/health")):
            time.sleep(delay)
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
        for m in MODELS + (STRICT_MODELS if FLAVOR == "openai-strict" else []):
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
        length = int(self.headers.get("Content-Length") or 0)
        path, answered = self.cloudflare_route(self.path.split("?", 1)[0].rstrip("/"), length)
        if answered:
            return
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
            LAST_MESSAGES.clear()
            LAST_MESSAGES.update({"messages": req.get("messages"), "tools": req.get("tools")})
            if req.get("tools"):
                COUNTERS["requests_with_tools"] += 1
        if model.startswith(REACT_MODEL_PREFIX):
            self.react_reply(req, model)
            return
        problem = self.tool_request_problem(req)
        if problem:
            self.send_json(400, {"error": {"message": problem}})
            return
        if model == "mock-no-stream-options" and "stream_options" in req:
            with STATE_LOCK:
                COUNTERS["stream_options_rejected"] += 1
            self.send_json(400, {"error": {"message": "Unrecognized request argument supplied: stream_options",
                                           "type": "invalid_request_error", "param": None, "code": None}})
            return
        if model == "mock-error":
            self.send_json(400, {"error": {"message": "mock bad request"}})
            return
        if FLAVOR == "openai-strict":
            if model == "mock-overflow":
                self.send_json(400, {"error": {
                    "message": "This model's maximum context length is 8192 tokens. However, your messages resulted "
                               "in 9000 tokens. Please reduce the length of the messages.",
                    "type": "invalid_request_error", "param": "messages", "code": "context_length_exceeded"}})
                return
            if model == "mock-refuse-unnamed" and req.get("reasoning_effort") == "none":
                with STATE_LOCK:
                    COUNTERS["thinking_off_rejected"] += 1
                self.send_json(400, {"error": 'invalid reasoning value: "none" (must be "high", "medium", "low")'})
                return
            if model == "mock-always-reject" or req.get("reasoning_effort") == "none":
                with STATE_LOCK:
                    COUNTERS["thinking_off_rejected"] += 1
                self.send_json(400, {"error": {
                    "message": "Unsupported value: 'none' is not supported with the '%s' model. Supported values "
                               "are: 'low', 'medium', and 'high'." % model,
                    "type": "invalid_request_error", "param": "reasoning_effort", "code": "unsupported_value"}})
                return

        if model.startswith(TOOL_MODEL_PREFIX):
            self.tool_reply(req, model)
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
            if self.stream(model, echo, include_usage, thinking=self.thinks(req)) == "drop":
                self.drop_connection()
                return
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
        if path == "/mock/last-messages":
            with STATE_LOCK:
                self.send_json(200, dict(LAST_MESSAGES))
            return True
        return False

    def drop_connection(self):
        """Resets the connection in the middle of a chunked body (a dead origin or tunnel)."""
        self.close_connection = True
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()
        except OSError:
            pass

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
        if FLAVOR in STRATA_SHARE_FLAVORS:
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
        if FLAVOR in STRATA_SHARE_FLAVORS:
            if not self.strata_share_path_ok(path):
                return
            if not self.strata_authorized():
                self.strata_unauthorized()
                return
            if path == "/v1/models" and FLAVOR == "strata-runtime":
                self.send_json_utf8(200, {"object": "list", "data": [{
                    "id": m, "object": "model", "owned_by": "strata",
                    "meta": {"instanceId": "inst-%d" % i, "mode": "cpu", "gpuIds": [], "context": STRATA_CTX},
                } for i, m in enumerate(STRATA_MODELS) if m != "strata-loading"]})
            elif path == "/v1/models":
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
        if FLAVOR in STRATA_SHARE_FLAVORS and not self.strata_share_path_ok_drained(path, length):
            return
        if not self.strata_authorized():
            self.drain(length)
            self.strata_unauthorized()
            return
        limit = STRATA_RUNTIME_BODY_LIMIT if FLAVOR == "strata-runtime" else STRATA_SHARE_BODY_LIMIT
        if FLAVOR in STRATA_SHARE_FLAVORS and length > limit:
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
            if FLAVOR in STRATA_SHARE_FLAVORS:
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
            LAST_MESSAGES.clear()
            LAST_MESSAGES.update({"messages": messages, "tools": req.get("tools")})
            if req.get("tools"):
                COUNTERS["requests_with_tools"] += 1

        def invalid(message, status=400):
            self.send_json(status, {"error": {"type": "invalid_request_error", "message": message}})

        if model == "strata-loading":
            if FLAVOR in STRATA_SHARE_FLAVORS:
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

        if model.startswith(REACT_MODEL_PREFIX):
            self.react_reply(req, model)
            return

        if model == "strata-tools" and FLAVOR != "strata-runtime":
            problem = self.tool_request_problem(req)
            if problem:
                invalid(problem)
                return
            if req.get("tools"):
                self.strata_tool_reply(req, model)
                return

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
            if req.get("return_progress") and strata_sends_progress():
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

    # ---- tool calling --------------------------------------------------

    @staticmethod
    def tool_request_problem(req):
        """Why the strictest server would refuse this request's tool data, or None."""
        if "tools" in req and not req["tools"]:
            return "`tools` must not be an empty array. Either provide at least one tool or omit the field entirely."
        messages = req.get("messages") or []
        for i, message in enumerate(messages):
            calls = message.get("tool_calls") if isinstance(message, dict) else None
            if not calls:
                continue
            following = messages[i + 1:i + 1 + len(calls)]
            for j, call in enumerate(calls):
                function = call.get("function") or {}
                if call.get("type") != "function" or not call.get("id") or not function.get("name"):
                    return "tool call %d of message %d lacks type, id or name" % (j, i)
                try:
                    json.loads(function.get("arguments"))
                except (TypeError, ValueError):
                    return "invalid tool call arguments"
                if j >= len(following) or following[j].get("role") != "tool":
                    return "tool call %s has no result" % call.get("id")
                if following[j].get("tool_call_id") != call.get("id") or not isinstance(following[j].get("content"), str):
                    return "the result of tool call %s is malformed" % call.get("id")
        return None

    @staticmethod
    def tool_plan(req):
        """What the user text asks for: (tool name, arguments as JSON text)."""
        text, _ = last_user_message(req.get("messages"))
        names = [((t or {}).get("function") or {}).get("name") for t in req.get("tools") or []]
        name = names[0] if names else "no_tool"
        match = re.search(r"tool=(\S+)", text)
        if match:
            name = match.group(1)
        match = re.search(r"args=(\{.*\})", text)
        return name, match.group(1) if match else "{}", names

    def tool_reply(self, req, model):
        refusals = {
            "mock-tools-refuse-ollama": (400, {"error": {"message": "%s does not support tools" % model,
                                                         "type": "invalid_request_error", "param": None, "code": None}}),
            "mock-tools-refuse-llamacpp": (500, {"error": {"code": 500, "message": "tools param requires --jinja flag",
                                                           "type": "server_error"}}),
            "mock-tools-refuse-vllm": (400, {"object": "error", "message": '"auto" tool choice requires '
                                             '--enable-auto-tool-choice and --tool-call-parser to be set'}),
            "mock-tools-refuse-schema": (400, {"error": {"message": "Failed to parse tools: JSON schema error at /properties/x: "
                                                                    "schema must be an object"}}),
        }
        if model == "mock-tools-refuse-always":
            self.send_json(400, {"error": {"message": "%s does not support tools" % model}})
            return
        if model in refusals and req.get("tools"):
            self.send_json(*refusals[model])
            return

        messages = req.get("messages") or []
        last = messages[-1] if messages else {}
        options = req.get("stream_options")
        include_usage = isinstance(options, dict) and options.get("include_usage") is True
        calling = bool(req.get("tools")) and (last.get("role") != "tool" or model == "mock-tools-loop")

        if model == "mock-tools-nonstream":
            self.nonstream_tool_reply(req, model, calling, last)
            return
        try:
            self.start_stream()
            if calling:
                self.stream_tool_call(req, model, include_usage)
            else:
                self.stream_after_tools(model, last, include_usage, req)
            self.end_stream()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    @staticmethod
    def after_tools_text(model, last, req):
        if model == "mock-tools-empty-after":
            return ""
        if last.get("role") == "tool":
            return "tool said: " + str(last.get("content"))[:200]
        return "no tools here"

    def stream_after_tools(self, model, last, include_usage, req):
        self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
        for piece in split_tokens(self.after_tools_text(model, last, req)):
            self.sse(self.chunk(model, {"content": piece}))
        self.finish_tool_stream(model, "stop", include_usage)

    def finish_tool_stream(self, model, reason, include_usage):
        self.sse(self.chunk(model, {}, finish=reason))
        if include_usage:
            self.sse({"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": int(time.time()),
                      "model": model, "choices": [],
                      "usage": {"prompt_tokens": 50, "completion_tokens": 12, "total_tokens": 62}})
        self.write_chunk("data: [DONE]\n\n")

    def stream_tool_call(self, req, model, include_usage):
        name, arguments, names = self.tool_plan(req)
        call_id = "call_%04d" % len(req.get("messages") or [])
        pieces = split_tokens(arguments, 4)

        def tool(entries, **extra):
            self.sse(self.chunk(model, dict({"tool_calls": entries}, **extra)))

        if model == "mock-tools-llamacpp":
            self.sse(self.chunk(model, {"role": "assistant", "content": None}))
            tool([{"index": 0, "id": call_id, "type": "function", "function": {"name": name}}])
            for piece in pieces:
                tool([{"index": 0, "function": {"arguments": piece}}])
        elif model == "mock-tools-vllm":
            self.sse(self.chunk(model, {"role": "assistant"}))
            tool([{"index": 0, "type": "function", "id": call_id, "function": {"name": name}},
                  {"index": 0, "function": {"arguments": arguments}}], content="Let me look.")
        elif model == "mock-tools-ollama":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            tool([{"id": call_id, "index": 0, "type": "function", "function": {"name": name, "arguments": arguments}}])
        elif model == "mock-tools-parallel":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            second = names[1] if len(names) > 1 else name
            second_pieces = split_tokens('{"n":2}', 3)
            tool([{"index": 0, "id": call_id + "a", "type": "function", "function": {"name": name, "arguments": ""}}])
            tool([{"index": 1, "id": call_id + "b", "type": "function", "function": {"name": second, "arguments": ""}}])
            for i in range(max(len(pieces), len(second_pieces))):
                if i < len(pieces):
                    tool([{"index": 0, "function": {"arguments": pieces[i]}}])
                if i < len(second_pieces):
                    tool([{"index": 1, "function": {"arguments": second_pieces[i]}}])
        elif model == "mock-tools-malformed":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            tool([{"index": 0, "id": call_id, "type": "function", "function": {"name": name, "arguments": '{"a":'}}])
        elif model == "mock-tools-unknown":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            tool([{"index": 0, "id": call_id, "type": "function", "function": {"name": "no_such_tool", "arguments": "{}"}}])
        elif model == "mock-tools-length":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            tool([{"index": 0, "id": call_id, "type": "function", "function": {"name": name, "arguments": '{"text":"cut'}}])
            self.finish_tool_stream(model, "length", include_usage)
            return
        elif model == "mock-tools-noid":
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            tool([{"index": 0, "id": "", "type": "function", "function": {"name": name, "arguments": "{}"}}])
            tool([{"index": 1, "id": "same", "type": "function", "function": {"name": name, "arguments": "{}"}}])
            tool([{"index": 2, "id": "same", "type": "function", "function": {"name": name, "arguments": "{}"}}])
        else:
            # mock-tools, mock-tools-content, mock-tools-loop, mock-tools-slow, mock-tools-empty-after
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            if model == "mock-tools-content":
                for piece in split_tokens("Let me check that for you."):
                    self.sse(self.chunk(model, {"content": piece}))
            if model == "mock-tools-slow":
                time.sleep(2)
            tool([{"index": 0, "id": call_id, "type": "function", "function": {"name": name, "arguments": ""}}])
            for piece in pieces:
                tool([{"index": 0, "function": {"arguments": piece}}])
        self.finish_tool_stream(model, "tool_calls", include_usage)

    def nonstream_tool_reply(self, req, model, calling, last):
        if calling:
            name, arguments, _ = self.tool_plan(req)
            call = {"id": "call_whole", "type": "function", "function": {"name": name, "arguments": json.loads(arguments)}}
            message = {"role": "assistant", "content": None, "tool_calls": [call]}
            reason = "tool_calls"
        else:
            message = {"role": "assistant", "content": self.after_tools_text(model, last, req)}
            reason = "stop"
        self.send_json(200, {"id": "chatcmpl-mock", "object": "chat.completion", "created": int(time.time()), "model": model,
                             "choices": [{"index": 0, "message": message, "finish_reason": reason}],
                             "usage": {"prompt_tokens": 50, "completion_tokens": 12, "total_tokens": 62}})

    # ---- ReAct text mode --------------------------------------------------

    @staticmethod
    def react_request_problem(req):
        """Why a server with no tools and a strict template would refuse this request, or None."""
        if "tools" in req:
            return "%s does not support tools" % req.get("model")
        for key in ("tool_choice", "stop"):
            if key in req:
                return "%s is not expected in a ReAct request" % key
        expected = "user"
        for message in req.get("messages") or []:
            role = message.get("role")
            if role == "system":
                continue
            if role == "tool" or "tool_calls" in message:
                return "tool messages are not supported"
            if role != expected:
                return "Conversation roles must alternate user/assistant/user/assistant/..."
            expected = "assistant" if role == "user" else "user"
            content = message.get("content")
            if role == "user" and isinstance(content, str) and content.startswith(REACT_OBSERVATION):
                if Handler.react_observation(content) is None:
                    return "an Observation must sit in one fence, closed once"
        return None

    @staticmethod
    def react_observation(content):
        """The text of a fenced Observation, or None when the fence is not whole."""
        lines = content.split("\n")
        if len(lines) < 4 or not lines[1].startswith("<<<") or len(lines[1]) < 4:
            return None
        marker = lines[1][3:] + ">>>"
        if lines[-1] != marker or content.count(marker) != 1:
            return None
        return "\n".join(lines[2:-1])

    @staticmethod
    def react_plan(req):
        """The tool and arguments the last user text asks for."""
        text, _ = last_user_message(req.get("messages"))
        system = next((m.get("content") or "" for m in req.get("messages") or [] if m.get("role") == "system"), "")
        tools = re.findall(r"^Tool: (\S+)$", system, re.M)
        name = tools[0] if tools else "no_tool"
        match = re.search(r"tool=(\S+)", text)
        if match:
            name = match.group(1)
        match = re.search(r"args=(\{.*\})", text)
        return name, match.group(1) if match else "{}"

    def react_reply(self, req, model):
        problem = self.react_request_problem(req)
        if problem:
            self.send_json(400, {"error": {"message": problem}})
            return
        messages = req.get("messages") or []
        last = messages[-1] if messages else {}
        content = last.get("content")
        observation = None
        if last.get("role") == "user" and isinstance(content, str) and content.startswith(REACT_OBSERVATION):
            observation = self.react_observation(content)
        system = next((m.get("content") or "" for m in messages if m.get("role") == "system"), "")
        options = req.get("stream_options")
        include_usage = isinstance(options, dict) and options.get("include_usage") is True
        try:
            self.start_stream()
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            if "<<<tools_" not in system:
                self.react_text(model, "Answering without tools.\nAction: not_a_call\nAction Input: {}\n")
                self.finish_tool_stream(model, "stop", include_usage)
            elif observation is not None and model == "mock-react-length-after":
                self.react_text(model, 'Action: mock__echo\nAction Input: {"text":"cut')
                self.finish_tool_stream(model, "length", include_usage)
            elif observation is not None and model == "mock-react-echo":
                self.react_text(model, observation)
                self.finish_tool_stream(model, "stop", include_usage)
            elif observation is not None and model != "mock-react-loop":
                self.react_text(model, "Thought: I have what I need.\nFinal Answer: tool said: " + observation[:200])
                self.finish_tool_stream(model, "stop", include_usage)
            else:
                self.react_turn(req, model, include_usage)
            self.end_stream()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    def react_text(self, model, text):
        for piece in split_tokens(text):
            self.sse(self.chunk(model, {"content": piece}))

    def react_turn(self, req, model, include_usage):
        name, arguments = self.react_plan(req)
        native = [{"index": 0, "id": "call_native", "type": "function",
                   "function": {"name": name, "arguments": arguments}}]
        head = "Thought: I should call a tool.\nAction: %s\nAction Input: " % name
        reason = "stop"
        if model == "mock-react-fence":
            self.react_text(model, "Thought：I should call a tool.\nAction：%s\nAction Input：\n```json\n%s\n```\n" % (name, arguments))
        elif model == "mock-react-noinput":
            self.react_text(model, "Thought: No arguments.\nAction: %s\n" % name)
        elif model == "mock-react-raw":
            self.react_text(model, head + "not json\nObservation: %s\nFinal Answer: %s\n" % (REACT_MADE_UP, REACT_MADE_UP))
        elif model == "mock-react-case":
            self.react_text(model, "Action: %s\nAction Input: %s\n" % (name.upper(), arguments))
        elif model == "mock-react-unknown":
            self.react_text(model, "Action: no_such_tool\nAction Input: {}\n")
        elif model == "mock-react-length":
            self.react_text(model, head + '{"text":"cut')
            reason = "length"
        elif model == "mock-react-native":
            self.sse(self.chunk(model, {"tool_calls": native}))
            self.react_text(model, "Thought: Text wins.\nFinal Answer: answered in text")
        elif model == "mock-react-native-only":
            self.sse(self.chunk(model, {"tool_calls": native}))
        elif model == "mock-react-final":
            self.react_text(model, "Thought: This one is easy.\nFinal Answer: 42")
        elif model == "mock-react-plain":
            self.react_text(model, "Just an answer, with no labels at all.")
        elif model == "mock-react-slow":
            self.react_text(model, head + '{"text":')
            time.sleep(4)
            self.react_text(model, '"late"}')
        elif model == "mock-react-reasoning":
            self.sse(self.chunk(model, {"reasoning_content": "I could write this.\nObservation: %s\nAction: %s\nAction Input: {}\n" % (REACT_MADE_UP, name)}))
            self.react_text(model, "Thought: This one is easy.\nFinal Answer: 42")
        elif model == "mock-react-think":
            self.react_text(model, "<think>Action: %s\nAction Input: {}\n</think>\nThought: This one is easy.\nFinal Answer: 42" % name)
        elif model == "mock-react-orphan-input":
            self.react_text(model, "Let me draft it.\nAction: %s\nAction Input: %s\n" % (name, arguments))
            self.react_text(model, "</think>\nThought: Done.\nFinal Answer: 42")
        elif model == "mock-react-orphan-late":
            self.react_text(model, "Let me draft it.\nAction: %s\nAction Input: %s\n" % (name, arguments))
            self.react_text(model, "That looks right.\n</think>\nThought: Done.\nFinal Answer: 42")
        elif model == "mock-react-oneline-fence":
            self.react_text(model, head + "```json %s```\nObservation: %s\n" % (arguments, REACT_MADE_UP))
        elif model == "mock-react-noname":
            self.react_text(model, "Action:\nAction Input: {}\n")
        elif model == "mock-react-noname-thought":
            self.react_text(model, "Thought: Which one?\nAction:\nAction Input: {}\n")
        elif model == "mock-react-labels":
            self.react_text(model, "Thought:\nFinal Answer:\n")
        elif model == "mock-react-length-bare":
            self.react_text(model, 'Action: %s\nAction Input: {"text":"cut' % name)
            reason = "length"
        elif model == "mock-react-length-whole":
            self.react_text(model, head + arguments)
            reason = "length"
        elif model == "mock-react-native-action":
            self.sse(self.chunk(model, {"tool_calls": native}))
            self.react_text(model, head + arguments)
        elif model == "mock-react-slow-final":
            # Paced: the client only shows what it has on a later delta, 50 ms after the last.
            self.react_text(model, "Thought: Partial thought.\nFinal Answer:")
            time.sleep(0.2)
            self.sse(self.chunk(model, {"content": " Partial"}))
            time.sleep(4)
            self.react_text(model, " and the rest")
        elif model == "mock-react-orphan":
            self.react_text(model, "Maybe\nAction: made_up_in_reasoning\n</think>\nThought: Now for real.\nAction: %s\nAction Input: %s\n" % (name, arguments))
        else:
            # mock-react, mock-react-loop, mock-react-echo
            self.react_stream_past_the_input(model, head + arguments)
            return
        self.finish_tool_stream(model, reason, include_usage)

    def react_stream_past_the_input(self, model, text):
        """The closing } and a made-up Observation share a chunk, and the model keeps going. The
        stream ends only when the client leaves, which a write then notices."""
        for piece in split_tokens(text[:-1]):
            self.sse(self.chunk(model, {"content": piece}))
        try:
            self.sse(self.chunk(model, {"content": text[-1] + "\nObservation: %s in one chunk\n" % REACT_MADE_UP}))
            for i in range(400):
                time.sleep(0.02)
                self.sse(self.chunk(model, {"content": "Final Answer: %s %d\n" % (REACT_MADE_UP, i)}))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            with STATE_LOCK:
                COUNTERS["react_disconnects"] += 1
            raise
        with STATE_LOCK:
            COUNTERS["react_streamed_to_end"] += 1
        self.finish_tool_stream(model, "stop", False)

    def strata_tool_reply(self, req, model):
        """serve/server.py: {role, content:""}, the call, the closing } always sent, usage on the finish chunk."""
        messages = req.get("messages") or []
        last = messages[-1] if messages else {}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.wfile.flush()
        try:
            self.sse(self.chunk(model, {"role": "assistant", "content": ""}))
            if last.get("role") == "tool":
                self.sse(self.chunk(model, {"content": "tool said: " + str(last.get("content"))[:200]}))
                reason = "stop"
            else:
                name, arguments, _ = self.tool_plan(req)
                body = arguments[:-1]
                self.sse(self.chunk(model, {"tool_calls": [{"index": 0, "id": "call_strata", "type": "function",
                                                            "function": {"name": name, "arguments": ""}}]}))
                for piece in split_tokens(body, 3):
                    self.sse(self.chunk(model, {"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}))
                self.sse(self.chunk(model, {"tool_calls": [{"index": 0, "function": {"arguments": "}"}}]}))
                reason = "tool_calls"
            final = self.chunk(model, {}, finish=reason)
            final["usage"] = {"prompt_tokens": 50, "completion_tokens": 12, "total_tokens": 62}
            self.sse(final)
            self.write_chunk("data: [DONE]\n\n")
            self.end_stream()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
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

    @staticmethod
    def thinks(req):
        """False when the request turns thinking off in a way this flavor's server honours."""
        if FLAVOR in ("llamacpp", "vllm"):
            kwargs = req.get("chat_template_kwargs")
            return not (isinstance(kwargs, dict) and kwargs.get("enable_thinking") is False)
        if FLAVOR == "ollama":
            return req.get("reasoning_effort") != "none"
        return True

    def stream(self, model, echo, include_usage=False, thinking=True):
        self.write_chunk(": mock stream start\n\n")  # SSE comment
        self.sse(self.chunk(model, {"role": "assistant", "content": ""}))

        completion_tokens = 0

        def content(piece, space=True):
            self.sse(self.chunk(model, {"content": piece}), space=space)

        if not thinking and model in ("mock-reasoning-content", "mock-reasoning", "mock-think-tags",
                                      "mock-orphan-think", "mock-slow-think"):
            model_mode = "mock-plain"
        else:
            model_mode = model

        if model_mode == "mock-reasoning-content":
            for piece in ["Let me think", " about this", " request."]:
                self.sse(self.chunk(model, {"reasoning_content": piece, "content": None}))
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model_mode == "mock-reasoning":
            for piece in ["Considering", " the user's", " message."]:
                self.sse(self.chunk(model, {"reasoning": piece}))
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece, space=False)  # also exercises "data:" without a space
                completion_tokens += 1

        elif model_mode == "mock-think-tags":
            for piece in ["<thi", "nk>Let me", " think...</th", "ink>\n\n"]:
                content(piece)
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model_mode == "mock-orphan-think":
            for piece in ["The user wants", " an echo.</thi", "nk>\n"]:
                content(piece)
                completion_tokens += 1
            for piece in split_tokens(echo):
                content(piece)
                completion_tokens += 1

        elif model_mode == "mock-stream-error":
            content("Partial answer")
            self.sse({"error": {"message": "mock stream error", "type": "server_error"}})
            self.write_chunk("data: [DONE]\n\n")
            return

        elif model_mode == "mock-sse-error-field":
            # llama.cpp style: an "error:" field line instead of "data:".
            self.write_chunk('error: {"code": 500, "message": "boom", "type": "server_error"}\n\n')
            return

        elif model_mode == "mock-sse-error-event":
            self.write_chunk('event: error\ndata: {"message": "context length exceeded"}\n\n')
            return

        elif model_mode == "mock-bare-error":
            self.write_chunk('{"error": {"message": "bare failure"}}\n')
            return

        elif model_mode in ("mock-drop", "mock-cut"):
            for piece in split_tokens("Partial answer, then the connection breaks"):
                content(piece)
            time.sleep(0.05)
            return "drop" if model == "mock-drop" else None

        elif model_mode == "mock-empty":
            self.sse(self.chunk(model, {}, finish="stop"))
            self.write_chunk("data: [DONE]\n\n")
            return

        elif model_mode == "mock-slow":
            content(echo + "\n")
            for i in range(1, SLOW_TOKENS + 1):
                time.sleep(SLOW_INTERVAL)
                content("token%d " % i)
                completion_tokens += 1

        elif model_mode == "mock-slow-think":
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
        if FLAVOR not in ("lmstudio", "lmstudio-v0", "llamacpp", "vllm", "ollama", "plain", "openai-strict",
                          "strata-share", "strata-engine", "strata-runtime"):
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
