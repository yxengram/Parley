// Parley Web chat: requests, SSE, stream accumulation, errors, model list, speed. No DOM.
// A port of Sources/ParleyCore/ChatClient.swift, Streaming.swift, GenerationStats.swift,
// EdgeErrors.swift and ContextBudget.contextLength(fromError:); where this file and the Swift
// disagree, this file is wrong (Web/tests/vectors are written by the Swift code).
// Runs in the page and, for tests, in Node 18+ (fetch, TextDecoder, TextEncoder, AbortController).
const ParleyChat = (() => {
  'use strict';

  // ---- errors ---------------------------------------------------------------------------------

  /** Stored error texts are fixed English, the same strings the Mac app stores (ParleyError). */
  class ChatError extends Error {
    constructor(kind, message, extra) {
      super(message);
      this.name = 'ChatError';
      this.kind = kind; // 'http' | 'api' | 'network' | 'invalidBaseURL' | 'redirect'
      if (extra) Object.assign(this, extra);
    }
  }
  const httpError = (status, body) => new ChatError('http', `HTTP ${status}: ${body}`, { status, body });
  const apiError = (message) => new ChatError('api', `API error: ${message}`, { detail: message });

  const NETWORK_TEXT = 'Could not connect to the server.';
  const NETWORK_HINT = 'The browser could not reach the server. Common causes: the server is not running; ' +
    'the server does not allow requests from this page (CORS: it must answer the preflight and allow the ' +
    'Authorization and Content-Type headers); or this page is served over https while the server address is ' +
    'http:// (mixed content is blocked: use the downloaded ParleyWeb.html file or an https address).';

  const MISSING_VERSION_PATH_HINT = 'The base URL has no path; OpenAI-compatible servers usually expect one ' +
    'ending in /v1 (for example http://host:1234/v1).';

  const abortError = () => {
    const e = new Error('The request was cancelled.');
    e.name = 'AbortError';
    return e;
  };
  const isAbort = (e, signal) => (e && e.name === 'AbortError') || (signal && signal.aborted === true);

  // ---- small text helpers ---------------------------------------------------------------------

  // Swift's whitespacesAndNewlines does not include U+FEFF (JavaScript's \s does) but does include U+0085.
  const isBlank = (s) => !/[^\s\u0085]|\uFEFF/.test(s);
  function trim(s) {
    let a = 0;
    let b = s.length;
    const ws = (c) => ((c === '\u0085' || /\s/.test(c)) && c !== '\uFEFF');
    while (a < b && ws(s[a])) a++;
    while (b > a && ws(s[b - 1])) b--;
    return s.slice(a, b);
  }

  function parseJSON(text) {
    try { return JSON.parse(text); } catch (e) { return undefined; }
  }
  const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

  /** Swift's NSNumber.intValue / Int(String) for what servers send. */
  function intValue(v) {
    if (typeof v === 'number') return Number.isFinite(v) ? Math.trunc(v) : null;
    if (typeof v === 'boolean') return v ? 1 : 0;
    if (typeof v === 'string') return /^[+-]?\d+$/.test(v) ? parseInt(v, 10) : null;
    return null;
  }
  function doubleValue(v) {
    if (typeof v === 'number') return Number.isFinite(v) ? v : null;
    if (typeof v === 'boolean') return v ? 1 : 0;
    if (typeof v === 'string') {
      const t = v.trim();
      return t !== '' && Number.isFinite(Number(t)) ? Number(t) : null;
    }
    return null;
  }

  // ---- URLs -----------------------------------------------------------------------------------

  function normalizeBase(baseURL) {
    let s = trim(String(baseURL == null ? '' : baseURL));
    while (s.endsWith('/')) s = s.slice(0, -1);
    let url = null;
    try { url = new URL(s); } catch (e) { url = null; }
    // fetch refuses credentials in the URL before any network activity; say so as a bad URL, not a dead server.
    if (!url || (url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname || url.username || url.password) {
      throw new ChatError('invalidBaseURL', `Invalid API base URL: ${baseURL}`);
    }
    return { text: s, url };
  }
  const chatURL = (baseURL) => normalizeBase(baseURL).text + '/chat/completions';
  const modelsURL = (baseURL) => normalizeBase(baseURL).text + '/models';
  const baseURLHasNoPath = (baseURL) => {
    const p = normalizeBase(baseURL).url.pathname;
    return p === '' || p === '/';
  };

  // ---- request body (the no-tools path of ChatClient.buildRequestBody) -------------------------

  /** What turns thinking off ("None") on each kind of server. Same table as the Swift. */
  function thinkingOffFields(kind) {
    switch (kind) {
      case 'llamaCpp':
      case 'vLLM':
        return { chat_template_kwargs: { enable_thinking: false } };
      default: // strata, ollama, lmStudio, hosted, unknown: the one field most servers accept
        return { reasoning_effort: 'none' };
    }
  }
  function sentThinkingOffFields(options) {
    if (!(options.disablesThinking && !options.omitsThinkingOff)) return [];
    return Object.keys(thinkingOffFields(options.serverKind));
  }

  function buildRequestBody(messages, options, includeUsage) {
    const opts = options || {};
    const api = [];
    let systemText = opts.systemPrompt || '';
    // After the prompt, in the system text: some chat templates refuse a system message anywhere but first.
    if (typeof opts.historySummary === 'string' && !isBlank(opts.historySummary)) {
      systemText = isBlank(systemText) ? opts.historySummary : systemText + '\n\n' + opts.historySummary;
    }
    if (trim(systemText) !== '') api.push({ role: 'system', content: systemText });

    for (const message of messages || []) {
      const content = message.content == null ? '' : message.content;
      const attachments = message.attachments || [];
      if (message.role === 'system') {
        if (trim(content) === '') continue;
        api.push({ role: 'system', content });
      } else if (message.role === 'assistant') {
        // Never send reasoning back. Skip empty (e.g. failed) replies; partial content is sent as is.
        if (isBlank(content)) continue;
        api.push({ role: 'assistant', content });
      } else if (message.role === 'user') {
        let text = content;
        for (const a of attachments) {
          if (a.kind !== 'text' || a.text == null) continue;
          const name = String(a.filename).split('"').join('&quot;');
          text += `\n\n<file name="${name}">\n${a.text}\n</file>`;
        }
        const images = attachments.filter((a) => a.kind === 'image' && a.data != null);
        if (images.length === 0) {
          api.push({ role: 'user', content: text });
        } else {
          const parts = [];
          if (text !== '') parts.push({ type: 'text', text });
          for (const image of images) {
            const mime = image.mimeType ? image.mimeType : 'image/jpeg';
            parts.push({ type: 'image_url', image_url: { url: `data:${mime};base64,${image.data}` } });
          }
          api.push({ role: 'user', content: parts });
        }
      }
    }

    const body = { model: opts.model, stream: true, messages: api };
    if (opts.temperature != null) body.temperature = opts.temperature;
    if (opts.maxTokens != null) body.max_tokens = opts.maxTokens;
    if (opts.reasoningEffort != null) body.reasoning_effort = opts.reasoningEffort;
    if (includeUsage) body.stream_options = { include_usage: true };
    if (opts.disablesThinking && !opts.omitsThinkingOff) {
      // "None" replaces an effort (the picker never sets both).
      delete body.reasoning_effort;
      Object.assign(body, thinkingOffFields(opts.serverKind));
    }
    if (opts.serverKind === 'strata') {
      // Prompt-reading progress before the first token (llama.cpp's flag; best effort).
      body.return_progress = true;
      const budget = opts.reasoningBudgetTokens;
      if (budget != null && budget > 0 && !opts.disablesThinking) body.reasoning_budget_tokens = budget;
    }
    return body;
  }

  // ---- SSE ------------------------------------------------------------------------------------

  /** "[DONE]" or a complete top-level JSON object/array. */
  function isCompletePayload(s) {
    const t = trim(s);
    if (t === '[DONE]') return true;
    if (t === '') return false;
    const first = t[0];
    const last = t[t.length - 1];
    if (!(first === '{' || first === '[') || !(last === '}' || last === ']')) return false;
    return parseJSON(t) !== undefined;
  }

  /** Normalizes an error value to {"error": {...}}; an object that already has "error" is kept. */
  function errorPayload(value) {
    const trimmed = trim(value);
    const parsed = trimmed === '' ? undefined : parseJSON(trimmed);
    let error;
    if (isObject(parsed)) {
      if (parsed.error !== undefined && parsed.error !== null) return trimmed;
      error = parsed;
    } else if (typeof parsed === 'string' && parsed !== '') {
      error = { message: parsed };
    } else if (trimmed !== '') {
      error = { message: trimmed };
    } else {
      error = { message: 'The server reported an error.' };
    }
    return JSON.stringify({ error });
  }

  /** Splits a stream's text into lines and applies SSEDecoder's rules to them. */
  class SSEParser {
    constructor() {
      this.dataLines = [];
      this.eventType = null;
      this.carry = '';
    }

    /** Text of any size, cut anywhere: complete lines are decoded, the rest waits for more. */
    feed(text) {
      const s = this.carry + text;
      const out = [];
      let start = 0;
      let i = 0;
      while (i < s.length) {
        const c = s.charCodeAt(i);
        if (c === 10) {
          this._push(out, s.slice(start, i));
          i += 1;
          start = i;
        } else if (c === 13) {
          if (i + 1 >= s.length) break; // a "\r" at the end may be half of "\r\n"
          this._push(out, s.slice(start, i));
          i += s.charCodeAt(i + 1) === 10 ? 2 : 1;
          start = i;
        } else {
          i += 1;
        }
      }
      this.carry = s.slice(start);
      return out;
    }

    _push(out, line) {
      for (const p of this.feedLine(line)) out.push(p);
    }

    /** One line, without its newline (SSEDecoder.feed(line:)). Returns 0..n data payloads. */
    feedLine(rawLine) {
      let line = rawLine;
      while (line.endsWith('\r') || line.endsWith('\n')) line = line.slice(0, -1);

      // Blank line: end of event, dispatch whatever is buffered.
      if (line === '') {
        const out = this._flush();
        this.eventType = null;
        return out;
      }
      if (line[0] === ':') return []; // comment

      // A bare JSON object line is not valid SSE, but some servers send their error body that way.
      if (line[0] === '{' && this.dataLines.length === 0 && isCompletePayload(line)) {
        return [this._dispatch(line)];
      }

      let field;
      let value;
      const colon = line.indexOf(':');
      if (colon >= 0) {
        field = line.slice(0, colon);
        value = line.slice(colon + 1);
        if (value[0] === ' ') value = value.slice(1);
      } else {
        field = line;
        value = '';
      }

      if (field === 'event') {
        this.eventType = value;
        return [];
      }
      if (field === 'error') {
        const out = this._flush();
        out.push(errorPayload(value));
        this.eventType = null;
        return out;
      }
      if (field !== 'data') return []; // id, retry and unknown fields carry nothing we need

      const out = [];
      // Something incomplete is buffered and this line is complete on its own: the blank line
      // that should have separated them was most likely dropped. Emit the stale buffer apart.
      if (this.dataLines.length > 0 && !isCompletePayload(this.dataLines.join('\n')) && isCompletePayload(value)) {
        for (const p of this._flush()) out.push(p);
      }
      this.dataLines.push(value);
      const joined = this.dataLines.join('\n');
      if (isCompletePayload(joined)) {
        this.dataLines = [];
        out.push(this._dispatch(joined));
      }
      return out;
    }

    /** End of the stream: a last unterminated line, then whatever is buffered. */
    finish() {
      const out = [];
      if (this.carry !== '') {
        const rest = this.carry;
        this.carry = '';
        for (const p of this.feedLine(rest)) out.push(p);
      }
      for (const p of this._flush()) out.push(p);
      this.eventType = null;
      return out;
    }

    _flush() {
      if (this.dataLines.length === 0) return [];
      const joined = this.dataLines.join('\n');
      this.dataLines = [];
      return [this._dispatch(joined)];
    }

    // The event type is consumed here (not only at a blank line): blank lines can go missing.
    _dispatch(payload) {
      const type = this.eventType;
      this.eventType = null;
      if (type !== 'error' || trim(payload) === '[DONE]') return payload;
      return errorPayload(payload);
    }
  }

  // ---- chunks ---------------------------------------------------------------------------------

  function errorMessageFrom(error) {
    if (isObject(error)) {
      if (typeof error.message === 'string' && error.message !== '') return error.message;
      if (error.code !== undefined) return `error ${error.code === null ? '<null>' : String(error.code)}`;
      if (typeof error.type === 'string') return error.type;
      return 'Unknown error';
    }
    if (typeof error === 'string' && error !== '') return error;
    return 'Unknown error';
  }

  /** One chat.completion.chunk payload. Null for [DONE], non-JSON and chunks with nothing useful. */
  function parseChunk(payload) {
    const trimmed = trim(payload);
    if (trimmed === '' || trimmed === '[DONE]') return null;
    const root = parseJSON(trimmed);
    if (!isObject(root)) return null;

    if (root.error !== undefined && root.error !== null) throw apiError(errorMessageFrom(root.error));
    // vLLM / FastChat style: {"object":"error","message":...}
    if (root.object === 'error') throw apiError(errorMessageFrom(root));

    const delta = {};
    if (Array.isArray(root.choices) && root.choices.length > 0 && root.choices.every(isObject)) {
      const choice = root.choices[0];
      // Streaming chunks carry "delta"; a non-streaming completion carries "message".
      const body = isObject(choice.delta) ? choice.delta : (isObject(choice.message) ? choice.message : null);
      if (body) {
        if (typeof body.content === 'string') delta.content = body.content;
        const rc = typeof body.reasoning_content === 'string' ? body.reasoning_content : undefined;
        const r = typeof body.reasoning === 'string' ? body.reasoning : undefined;
        // Some servers send both with the same text; take one so nothing is duplicated.
        let reasoning;
        if (rc !== undefined && rc !== '') reasoning = rc;
        else if (r !== undefined && r !== '') reasoning = r;
        else reasoning = rc !== undefined ? rc : r;
        if (reasoning !== undefined) delta.reasoning = reasoning;
      }
      if (typeof choice.finish_reason === 'string') delta.finishReason = choice.finish_reason;
    }

    if (isObject(root.usage)) {
      const u = root.usage;
      const details = isObject(u.completion_tokens_details) ? u.completion_tokens_details : null;
      const parsed = {};
      const set = (key, v) => { if (v !== null) parsed[key] = v; };
      set('promptTokens', intValue(u.prompt_tokens));
      set('completionTokens', intValue(u.completion_tokens));
      set('totalTokens', intValue(u.total_tokens));
      set('reasoningTokens', details ? intValue(details.reasoning_tokens) : null);
      set('cachedPromptTokens', isObject(u.prompt_tokens_details) ? intValue(u.prompt_tokens_details.cached_tokens) : null);
      if (parsed.promptTokens !== undefined || parsed.completionTokens !== undefined || parsed.totalTokens !== undefined) {
        delta.usage = parsed;
      }
    }

    // llama.cpp: {"timings":{"predicted_n":\u2026}} on the last chunk.
    if (isObject(root.timings)) {
      const t = root.timings;
      const parsed = {};
      const put = (key, v) => { if (v !== null) parsed[key] = v; };
      put('promptTokens', intValue(t.prompt_n));
      put('promptMilliseconds', doubleValue(t.prompt_ms));
      put('cachedTokens', intValue(t.cache_n));
      put('predictedTokens', intValue(t.predicted_n));
      put('predictedMilliseconds', doubleValue(t.predicted_ms));
      put('predictedPerSecond', doubleValue(t.predicted_per_second));
      put('promptPerSecond', doubleValue(t.prompt_per_second));
      if (Object.keys(parsed).length > 0) delta.timings = parsed;
    }

    // llama.cpp / Strata (with return_progress): prompt_progress {total, cache, processed, time_ms}.
    if (isObject(root.prompt_progress)) {
      const p = root.prompt_progress;
      const total = intValue(p.total);
      const processed = intValue(p.processed);
      if (total !== null && total > 0 && processed !== null) {
        const progress = { total, cached: Math.max(0, intValue(p.cache) || 0), processed };
        const ms = intValue(p.time_ms);
        if (ms !== null) progress.milliseconds = ms;
        delta.promptProgress = progress;
      }
    }

    return Object.keys(delta).length === 0 ? null : delta;
  }

  // ---- accumulator ----------------------------------------------------------------------------

  const OPEN_TAGS = ['<think>', '<thinking>'];
  const CLOSE_TAGS = ['</think>', '</thinking>'];
  const ALL_TAGS = OPEN_TAGS.concat(CLOSE_TAGS);

  const trimLeadingNewlines = (s) => s.replace(/^[\n\r]+/, '');

  /** The earliest occurrence of any of `tags` in `s`: {index, tag} or null. */
  function earliest(tags, s) {
    let best = null;
    for (const tag of tags) {
      const i = s.indexOf(tag);
      if (i >= 0 && (best === null || i < best.index)) best = { index: i, tag };
    }
    return best;
  }

  /** Length of the longest suffix of `s` that is a proper prefix of one of `tags`. */
  function partialTagSuffixLength(s, tags) {
    const maxLen = Math.max(...tags.map((t) => t.length)) - 1;
    const tail = s.length > maxLen ? s.slice(s.length - maxLen) : s;
    for (let k = tail.length; k > 0; k--) {
      const suffix = tail.slice(tail.length - k);
      if (tags.some((t) => t.length > k && t.startsWith(suffix))) return k;
    }
    return 0;
  }

  /**
   * Folds deltas into displayable content and reasoning. Handles inline <think>...</think> split
   * across chunks, and output with only a closing </think> (the prompt template opened the tag):
   * everything before it is reclassified as reasoning. Times are milliseconds (Date.now()).
   */
  class StreamAccumulator {
    constructor() {
      this.content = '';
      this.reasoning = '';
      this.usage = null;
      this.finishReason = null;
      this.reasoningStartedAt = null;
      this.reasoningEndedAt = null; // set when the first content after reasoning arrives, or at finish
      this.contentGeneration = 0;   // moves when `content` stops being an extension of what it was
      this._inThinkTag = false;
      this._sawOpenTag = false;
      this._pending = '';           // held-back text that may be the start of a tag
      this._trimNextContent = false;
      this._firstContentAt = null;
    }

    get isReasoning() {
      return this._inThinkTag || (this.reasoningStartedAt !== null && this.reasoningEndedAt === null);
    }

    get reasoningDuration() {
      if (this.reasoningStartedAt === null || this.reasoningEndedAt === null) return null;
      return Math.max(0, (this.reasoningEndedAt - this.reasoningStartedAt) / 1000);
    }

    apply(delta, now) {
      const t = now === undefined ? Date.now() : +now;
      if (typeof delta.reasoning === 'string' && delta.reasoning !== '') this._appendReasoning(delta.reasoning, t);
      if (typeof delta.content === 'string' && delta.content !== '') this._processContent(delta.content, t);
      if (delta.usage) this.usage = delta.usage;
      if (delta.finishReason != null) this.finishReason = delta.finishReason;
    }

    /** Flushes any held-back partial tag text. */
    finish(now) {
      const t = now === undefined ? Date.now() : +now;
      if (this._pending !== '') {
        const text = this._pending;
        this._pending = '';
        if (this._inThinkTag) this._appendReasoning(text, t);
        else this._appendContent(text, t);
      }
      this._inThinkTag = false;
      if (this.reasoningStartedAt !== null && this.reasoningEndedAt === null) this.reasoningEndedAt = t;
    }

    _processContent(text, now) {
      let buffer = this._pending + text;
      this._pending = '';
      while (buffer !== '') {
        if (this._inThinkTag) {
          const hit = earliest(CLOSE_TAGS, buffer);
          if (hit) {
            this._appendReasoning(buffer.slice(0, hit.index), now);
            this._inThinkTag = false;
            this._trimNextContent = true;
            buffer = buffer.slice(hit.index + hit.tag.length);
            continue;
          }
          const hold = partialTagSuffixLength(buffer, CLOSE_TAGS);
          const split = buffer.length - hold;
          this._appendReasoning(buffer.slice(0, split), now);
          this._pending = buffer.slice(split);
          return;
        }

        const tags = this._sawOpenTag ? OPEN_TAGS : ALL_TAGS;
        const hit = earliest(tags, buffer);
        if (hit) {
          const before = buffer.slice(0, hit.index);
          buffer = buffer.slice(hit.index + hit.tag.length);
          if (OPEN_TAGS.includes(hit.tag)) {
            this._appendContent(before, now);
            this._inThinkTag = true;
            this._sawOpenTag = true;
            if (this.reasoningStartedAt === null) this.reasoningStartedAt = now;
            this.reasoningEndedAt = null;
          } else {
            // Orphan closing tag: the prompt template opened the block, so everything shown as
            // content so far was really reasoning.
            this._reclassifyContentAsReasoning(before, now);
            this._sawOpenTag = true;
            this._trimNextContent = true;
          }
          continue;
        }

        const hold = partialTagSuffixLength(buffer, tags);
        const split = buffer.length - hold;
        this._appendContent(buffer.slice(0, split), now);
        this._pending = buffer.slice(split);
        return;
      }
    }

    _reclassifyContentAsReasoning(extra, now) {
      const moved = this.content + extra;
      this.content = '';
      this.contentGeneration += 1;
      if (this.reasoningStartedAt === null) {
        this.reasoningStartedAt = this._firstContentAt !== null ? this._firstContentAt : now;
      }
      if (moved !== '') {
        this.reasoning = this.reasoning === '' ? trimLeadingNewlines(moved) : this.reasoning + moved;
      }
      this._firstContentAt = null;
      // Reasoning is over; the end is stamped when the first real content arrives (or at finish).
      this.reasoningEndedAt = null;
    }

    _appendReasoning(text, now) {
      if (text === '') return;
      let piece = text;
      if (this.reasoning === '') {
        piece = trimLeadingNewlines(piece);
        if (piece === '') return;
      }
      if (this.reasoningStartedAt === null) this.reasoningStartedAt = now;
      // Reasoning that resumes after content extends the reasoning phase.
      this.reasoningEndedAt = null;
      this.reasoning += piece;
    }

    _appendContent(text, now) {
      if (text === '') return;
      let piece = text;
      if (this._trimNextContent || (this.content === '' && this.reasoning !== '')) {
        piece = trimLeadingNewlines(piece);
        if (piece === '') return;
      }
      this._trimNextContent = false;
      this.content += piece;
      if (this._firstContentAt === null) this._firstContentAt = now;
      if (this.reasoningStartedAt !== null && this.reasoningEndedAt === null && !this._inThinkTag) {
        this.reasoningEndedAt = now;
      }
    }
  }

  // ---- generation speed -----------------------------------------------------------------------

  const MINIMUM_DURATION = 0.05; // below this, a rate is mostly noise from chunk timing

  /**
   * Measures generation speed on the client: each chunk with reasoning or content counts as one
   * token until the server reports an exact count. Times are milliseconds; results are seconds.
   */
  class GenerationMeter {
    constructor(requestStartedAt) {
      this.requestStartedAt = requestStartedAt === undefined ? null : +requestStartedAt;
      this.firstTokenAt = null;
      this.lastTokenAt = null;
      this.chunkCount = 0;
      this.reasoningChunkCount = 0;
      this.reportedCompletionTokens = null;
      this.reportedReasoningTokens = null;
      this.reportedCachedPromptTokens = null;
      this.timings = null;
      this.finishReason = null;
      this.promptProgress = null; // the latest prompt_progress, until the first token arrives
    }

    record(delta, now) {
      const t = now === undefined ? Date.now() : +now;
      // The opening {"role":"assistant","content":""} chunk is not a token.
      const hasReasoning = typeof delta.reasoning === 'string' && delta.reasoning !== '';
      const hasContent = typeof delta.content === 'string' && delta.content !== '';
      if (hasContent || hasReasoning) {
        this.chunkCount += 1;
        if (hasReasoning) this.reasoningChunkCount += 1;
        if (this.firstTokenAt === null) this.firstTokenAt = t;
        this.lastTokenAt = t;
        this.promptProgress = null;
      }
      const u = delta.usage;
      if (u && u.completionTokens != null) this.reportedCompletionTokens = u.completionTokens;
      if (u && u.reasoningTokens != null) this.reportedReasoningTokens = u.reasoningTokens;
      if (u && u.cachedPromptTokens != null) this.reportedCachedPromptTokens = u.cachedPromptTokens;
      if (delta.timings) this.timings = delta.timings;
      if (delta.finishReason != null) this.finishReason = delta.finishReason;
      if (delta.promptProgress && this.firstTokenAt === null) this.promptProgress = delta.promptProgress;
    }

    get generatedTokens() {
      if (this.timings && this.timings.predictedTokens != null) return this.timings.predictedTokens;
      if (this.reportedCompletionTokens !== null) return this.reportedCompletionTokens;
      return this.chunkCount;
    }

    get isEstimated() {
      return !(this.timings && this.timings.predictedTokens != null) && this.reportedCompletionTokens === null;
    }

    get timeToFirstToken() {
      if (this.requestStartedAt === null || this.firstTokenAt === null) return null;
      return Math.max(0, (this.firstTokenAt - this.requestStartedAt) / 1000);
    }

    /** Tokens within the measured span: the server's count minus reasoning it never streamed. */
    get streamedTokens() {
      const hidden = this.reportedReasoningTokens;
      const reported = this.reportedCompletionTokens;
      if ((this.timings && this.timings.predictedTokens != null) || reported === null
        || this.reasoningChunkCount !== 0 || hidden === null || !(hidden > 0)
        // Reasoning sent inline as <think> content arrives as content chunks: not hidden.
        || !(this.chunkCount <= reported - hidden)) return this.generatedTokens;
      return Math.max(0, reported - hidden);
    }

    /** Tokens after the first one, over the time since the first one. Null until measurable. */
    get tokensPerSecond() {
      const server = this.timings ? this.timings.predictedPerSecond : undefined;
      if (server != null && server > 0 && Number.isFinite(server)) return server;
      if (this.firstTokenAt === null || this.lastTokenAt === null) return null;
      const duration = (this.lastTokenAt - this.firstTokenAt) / 1000;
      const tokens = this.streamedTokens;
      if (tokens < 2 || duration < MINIMUM_DURATION) return null;
      return (tokens - 1) / duration;
    }

    /** What is stored on the finished message (GenerationStats, keys as Swift encodes them). */
    finalStats() {
      if (this.firstTokenAt === null || this.lastTokenAt === null) return null;
      const tm = this.timings;
      let duration;
      if (tm && tm.predictedMilliseconds != null && tm.predictedMilliseconds > 0) duration = tm.predictedMilliseconds / 1000;
      else duration = Math.max(0, (this.lastTokenAt - this.firstTokenAt) / 1000);
      let promptRate = null;
      if (tm) {
        if (tm.promptPerSecond != null && tm.promptPerSecond > 0 && Number.isFinite(tm.promptPerSecond)) promptRate = tm.promptPerSecond;
        else if (tm.promptTokens != null && tm.promptTokens > 0 && tm.promptMilliseconds != null && tm.promptMilliseconds > 0) {
          promptRate = tm.promptTokens / (tm.promptMilliseconds / 1000);
        }
      }
      const stats = {};
      const put = (k, v) => { if (v !== null && v !== undefined) stats[k] = v; };
      put('tokensPerSecond', this.tokensPerSecond);
      put('completionTokens', this.generatedTokens);
      put('timeToFirstToken', this.timeToFirstToken);
      put('generationDuration', duration);
      put('isEstimated', this.isEstimated);
      put('finishReason', this.finishReason);
      put('promptTokensRead', tm ? tm.promptTokens : null);
      put('promptTokensPerSecond', promptRate);
      put('cachedPromptTokens', tm && tm.cachedTokens != null ? tm.cachedTokens : this.reportedCachedPromptTokens);
      return stats;
    }
  }

  // ---- error bodies (EdgeErrors.swift) --------------------------------------------------------

  const MAX_ERROR_CHARS = 2000;
  const MAX_ERROR_BODY_BYTES = 64 * 1024;

  // Swift counts Characters (grapheme clusters); Intl.Segmenter is the closest match, code points the fallback.
  const segmenter = typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter('en', { granularity: 'grapheme' }) : null;
  function prefixChars(text, n) {
    if (text.length <= n) return text; // n UTF-16 units can hold at most n Characters
    const parts = segmenter ? Array.from(segmenter.segment(text), (x) => x.segment) : Array.from(text);
    return parts.length <= n ? text : parts.slice(0, n).join('');
  }
  const truncated = (text) => prefixChars(text, MAX_ERROR_CHARS);
  const isJSONText = (text) => (text[0] === '{' || text[0] === '[') && parseJSON(text) !== undefined;
  function isHTMLText(text) {
    const head = text.slice(0, 512).toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<!' + '--')
      || head.includes('<head') || head.includes('<body') || head.includes('<title');
  }
  function firstMatch(pattern, text) {
    const m = new RegExp(pattern, 'im').exec(text);
    return m ? m[1] : null;
  }
  function wholeMatch(pattern, text) {
    const m = new RegExp('^(?:' + pattern + ')$', 'i').exec(text);
    return m ? m[1] : null;
  }
  const ENTITIES = [['&amp;', '&'], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&#39;', "'"],
    ['&#039;', "'"], ['&apos;', "'"], ['&nbsp;', ' '], ['&middot;', '\u00b7'], ['&hellip;', '\u2026']];
  /** Tags removed, the common entities decoded, whitespace collapsed. */
  function plainText(html) {
    let text = html.replace(/<[^>]*>/g, ' ');
    for (const [entity, value] of ENTITIES) text = text.split(entity).join(value);
    return text.split(/\s+/).filter((w) => w !== '').join(' ');
  }
  function htmlTitle(html) {
    const raw = firstMatch('<title[^>]*>([\\s\\S]*?)</title>', html);
    if (raw === null) return null;
    const text = plainText(raw);
    return text === '' ? null : text;
  }
  /** The page's title (or first heading) as one short line, "HTML page" when it has neither. */
  function htmlSummary(html) {
    const title = htmlTitle(html);
    if (title) return prefixChars(title, 200);
    const h1 = firstMatch('<h1[^>]*>(.*?)</h1>', html.split('\n').join(' '));
    if (h1 !== null) {
      const text = plainText(h1);
      if (text !== '') return prefixChars(text, 200);
    }
    return 'HTML page';
  }

  /** Cloudflare's own error pages and challenges, reduced to one line (see EdgeErrors.swift). */
  function cloudflareSummary(status, headers, text) {
    if (status >= 300 && status < 400 && headers.location) {
      let host = null;
      try { host = new URL(headers.location).hostname.toLowerCase(); } catch (e) { host = null; }
      if (host && (host === 'cloudflareaccess.com' || host.endsWith('.cloudflareaccess.com'))) {
        return `Cloudflare Access sign-in at ${host} (redirect not followed)`;
      }
    }
    const viaCloudflare = (headers.server || '').toLowerCase() === 'cloudflare' || headers['cf-ray'] !== undefined;
    const challengeHeader = (headers['cf-mitigated'] || '').toLowerCase() === 'challenge';
    // The origin's JSON passes through unchanged.
    if (!challengeHeader && isJSONText(text)) return null;
    const lower = text.toLowerCase();
    const html = isHTMLText(text);
    // Cloudflare's whole answer to API clients is the one line "error code: 1033".
    const plainCode = viaCloudflare ? wholeMatch('error code: (\\d{3,4})', text) : null;
    const pageMarkers = html && (lower.includes('cf-error-details') || lower.includes('cf-wrapper')
      || lower.includes('cloudflare ray id') || lower.includes('cf-error-code')
      || lower.includes('cf_styles-css') || lower.includes('/cdn-cgi/styles/')
      || (lower.includes('cloudflare') && lower.includes('ray id')));
    const challengePage = html && (status === 403 || status === 503)
      && (lower.includes('cf_chl_opt') || lower.includes('<title>just a moment'));
    const edgeStatus = status >= 520 && status <= 530;
    const emptyEdgeGateway = viaCloudflare && (status === 502 || status === 504) && text === '';
    if (!(challengeHeader || challengePage || pageMarkers || plainCode !== null
      || (viaCloudflare && edgeStatus) || emptyEdgeGateway)) return null;

    const isChallenge = challengeHeader || challengePage;
    let code = plainCode
      || firstMatch('cf-error-code[^>]*>\\s*(\\d{3,4})\\s*<', text)
      || firstMatch('Error code\\s*(?:<[^>]*>\\s*)*(\\d{3,4})', text)
      || firstMatch('>\\s*Error\\s*(?:<[^>]*>\\s*)*(\\d{4})\\s*<', text);
    code = code ? parseInt(code, 10) : (isChallenge ? null : status);
    let rayID = headers['cf-ray'] || null;
    if (rayID === null) rayID = firstMatch('Ray ID:?\\s*(?:<[^>]*>\\s*)*([0-9a-fA-F]{16})', text);
    let title = null;
    if (html) {
      const raw = htmlTitle(text);
      if (raw !== null) {
        const parts = raw.split(' | ').map((p) => p.trim());
        const useful = parts.filter((p) => p !== '' && p.toLowerCase() !== 'cloudflare' && !(p.includes('.') && !p.includes(' ')));
        let t = useful.length > 0 ? useful[0] : parts[0];
        if (t !== undefined) {
          if (code !== null && t.startsWith(`${code}: `)) t = t.slice(`${code}: `.length);
          title = t === '' ? null : prefixChars(t, 120);
        }
      }
    }
    let line = isChallenge ? 'Cloudflare challenge' : `Cloudflare error ${code === null ? status : code}`;
    if (title) line += ': ' + title;
    if (rayID) line += ' \u00b7 Ray ID ' + rayID;
    return line;
  }

  /** "Redirect to https://host/path (not followed)", without query, fragment and credentials. */
  function redirectLine(location, base) {
    let url;
    try { url = new URL(location, base); } catch (e) { return null; }
    if (!url.hostname) return null;
    url.search = '';
    url.hash = '';
    url.username = '';
    url.password = '';
    return `Redirect to ${url.href} (not followed)`;
  }

  /** What a non-2xx response is stored as (ResponseText.errorBody). */
  function errorBodyText(status, headers, bytes, baseURL) {
    const text = new TextDecoder('utf-8').decode(bytes);
    const cf = cloudflareSummary(status, headers, trim(text.slice(0, 256 * 1024)));
    if (cf !== null) return cf;
    if (status >= 300 && status < 400 && headers.location) {
      return redirectLine(headers.location, baseURL) || truncated(text);
    }
    const trimmed = trim(text);
    // JSON first: a server's JSON message may quote markup ("<title>" in a rejected input).
    if (!isJSONText(trimmed) && (isHTMLText(trimmed) || (headers['content-type'] || '').toLowerCase().includes('text/html'))) {
      return htmlSummary(trimmed);
    }
    return truncated(text);
  }

  // ---- context length, refusals ---------------------------------------------------------------

  function firstNumber(pattern, text) {
    const m = new RegExp(pattern, 'is').exec(text);
    if (!m) return null;
    const n = parseInt(m[1], 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  /** The context size named in an overflow error, if any (ContextBudget.contextLength(fromError:)). */
  function contextLengthFromError(text) {
    const patterns = [
      '"n_ctx"\\s*:\\s*(\\d+)',
      'available context size \\((\\d+) tokens\\)',
      'maximum context length is (\\d+) tokens',
      'exceeds the context window:.*?the context \\((\\d+)\\)',
    ];
    for (const p of patterns) {
      const n = firstNumber(p, String(text));
      if (n !== null) return n;
    }
    return null;
  }

  /** HTTP 400/422 whose body names stream_options (or include_usage). */
  function isStreamOptionsRejection(status, body) {
    if (status !== 400 && status !== 422) return false;
    const lower = body.toLowerCase();
    return lower.includes('stream_options') || lower.includes('include_usage');
  }

  /** HTTP 400/422 refusing a "no thinking" field that was sent. Loose is safe: the retry decides. */
  function isThinkingOffRejection(status, body, sentFields, serverKind) {
    if ((status !== 400 && status !== 422) || sentFields.length === 0 || serverKind === 'strata') return false;
    const lower = body.toLowerCase();
    if (contextLengthFromError(body) !== null || lower.includes('context length') || lower.includes('context window')) return false;
    let names = sentFields.map((f) => f.toLowerCase());
    if (names.includes('reasoning_effort')) names = names.concat(['reasoning', 'thinking']);
    if (names.includes('chat_template_kwargs')) names = names.concat(['enable_thinking', 'chat template kwargs', 'thinking']);
    return names.some((n) => lower.includes(n));
  }

  // ---- transport ------------------------------------------------------------------------------

  const INTERRUPTION_BASE = 'The connection closed before the reply finished';
  function interruptionMessage(underlying, viaCloudflare) {
    return INTERRUPTION_BASE + (viaCloudflare ? ' (through Cloudflare)' : '') + (underlying ? ': ' + underlying : '.');
  }

  /** Adds the missing-/v1 hint to errors that suggest the wrong endpoint, when the base URL has no path. */
  function withPathHint(error, baseURL) {
    if (!(error instanceof ChatError) || !baseURLHasNoPath(baseURL)) return error;
    if (error.kind === 'api' && !error.detail.startsWith(INTERRUPTION_BASE)) {
      return apiError(error.detail + ' ' + MISSING_VERSION_PATH_HINT);
    }
    if (error.kind === 'http' && (error.status === 404 || error.status === 405)) {
      const detail = trim(error.body);
      return apiError(`Endpoint not found (HTTP ${error.status})` + (detail === '' ? '.' : `: ${detail}`) + ' ' + MISSING_VERSION_PATH_HINT);
    }
    return error;
  }

  function headerMap(response) {
    const out = {};
    if (response && response.headers && typeof response.headers.forEach === 'function') {
      response.headers.forEach((value, key) => { out[String(key).toLowerCase()] = value; });
    }
    return out;
  }

  /** The error for a non-2xx answer: reads at most 64 KB of the body. */
  async function readErrorBody(response, baseURL) {
    const chunks = [];
    let total = 0;
    if (response.body && typeof response.body.getReader === 'function') {
      const reader = response.body.getReader();
      try {
        while (total < MAX_ERROR_BODY_BYTES) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
          total += value.length;
        }
      } finally {
        try { await reader.cancel(); } catch (e) { /* already closed */ }
      }
    }
    const bytes = new Uint8Array(Math.min(total, MAX_ERROR_BODY_BYTES));
    let at = 0;
    for (const c of chunks) {
      const room = bytes.length - at;
      if (room <= 0) break;
      bytes.set(c.length > room ? c.subarray(0, room) : c, at);
      at += Math.min(c.length, room);
    }
    return errorBodyText(response.status, headerMap(response), bytes, baseURL);
  }

  async function doFetch(fetchImpl, url, init, signal) {
    const f = fetchImpl || globalThis.fetch;
    if (typeof f !== 'function') throw new ChatError('network', NETWORK_TEXT, { hint: NETWORK_HINT });
    try {
      return await f(url, init);
    } catch (e) {
      if (isAbort(e, signal)) throw abortError();
      throw new ChatError('network', NETWORK_TEXT, { hint: NETWORK_HINT, cause: e });
    }
  }

  /** A browser hides a refused redirect (type "opaqueredirect", status 0); Node shows the 3xx. */
  function redirectRefused(response) {
    return new ChatError('redirect', 'The server answered with a redirect, which is not followed.', { status: response.status });
  }

  const authHeaders = (apiKey) => {
    const key = apiKey == null ? '' : trim(String(apiKey));
    // fetch throws a TypeError for a header value above U+00FF (a pasted curly quote); that is not a network failure.
    if (/[^\u0000-\u00ff]/.test(key)) throw new ChatError('api', 'The API key contains characters that cannot be sent in an HTTP header.');
    return key === '' ? {} : { Authorization: `Bearer ${key}` };
  };

  const requestTooLargeMessage = (bytes, limit) => {
    const mb = (n) => (n / 1048576).toFixed(1) + ' MB';
    return `This request is ${mb(bytes)}, more than the ${mb(limit)} the server accepts. ` +
      'Images are sent again with every message: remove some, or fork from a message before the first image.';
  };

  class StreamOptionsRejected extends Error {}
  class ThinkingOffRejected extends Error {
    constructor(error) { super('thinking off rejected'); this.error = error; }
  }

  /** One attempt. Yields deltas; throws a *Rejected marker for an answer that deserves a retry. */
  async function* runStream(ctx) {
    const { url, init, rejectsStreamOptions, thinkingFields, serverKind, announceThinking, announceStreamOptions, signal, fetchImpl, baseURL } = ctx;
    const response = await doFetch(fetchImpl, url, init, signal);
    if (response.type === 'opaqueredirect') throw redirectRefused(response);
    const status = response.status;
    const headers = headerMap(response);

    if (!(status >= 200 && status < 300)) {
      const body = await readErrorBody(response, baseURL);
      if (rejectsStreamOptions && isStreamOptionsRejection(status, body)) throw new StreamOptionsRejected();
      if (isThinkingOffRejection(status, body, thinkingFields, serverKind)) throw new ThinkingOffRejected(httpError(status, body));
      throw httpError(status, body);
    }
    if (announceStreamOptions) yield { streamOptionsRejected: true };
    if (announceThinking) yield { thinkingOffRejected: true }; // the request without the fields was accepted

    // From here on the server has answered: a transport error is a broken reply, not an unreachable server.
    const viaCloudflare = (headers.server || '').toLowerCase() === 'cloudflare' || headers['cf-ray'] !== undefined;
    try {
      yield* readStream(response, (headers['content-type'] || '').toLowerCase(), viaCloudflare);
    } catch (e) {
      if (e instanceof ChatError || isAbort(e, signal)) throw e;
      // Only what a body reader rejects with (TypeError, DOMException); a bug of ours must stay visible.
      const transport = e instanceof TypeError || (typeof DOMException === 'function' && e instanceof DOMException);
      if (!transport) throw e;
      throw apiError(interruptionMessage('The network connection was lost.', viaCloudflare));
    }
  }

  async function* readStream(response, contentType, viaCloudflare) {
    const progress = { yieldedAny: false, sawFinishReason: false };

    // A server that ignores stream:true answers with one plain JSON completion.
    if (contentType.includes('application/json')) {
      const text = await response.text();
      const lines = text.split('\n');
      if (lines.some((l) => l.startsWith('data:'))) { // actually SSE, just mislabeled
        const parser = new SSEParser();
        for (const line of lines) {
          for (const d of decodePayloads(parser.feedLine(line), progress)) {
            if (d === DONE) return;
            yield d;
          }
        }
        for (const d of decodePayloads(parser.finish(), progress)) {
          if (d === DONE) return;
          yield d;
        }
      } else {
        const delta = parseChunk(text);
        if (delta) yield delta;
      }
      return;
    }

    const parser = new SSEParser();
    const decoder = new TextDecoder('utf-8');
    const reader = response.body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        for (const d of decodePayloads(parser.feed(decoder.decode(value, { stream: true })), progress)) {
          if (d === DONE) return;
          yield d;
        }
      }
    } finally {
      try { await reader.cancel(); } catch (e) { /* already closed */ }
    }
    for (const d of decodePayloads(parser.feed(decoder.decode()), progress)) {
      if (d === DONE) return;
      yield d;
    }
    for (const d of decodePayloads(parser.finish(), progress)) {
      if (d === DONE) return;
      yield d;
    }
    // The body ended cleanly but the reply did not: no finish_reason and no [DONE] after something
    // was sent (a proxy that closed the response, a server that died between chunks).
    if (progress.yieldedAny && !progress.sawFinishReason) throw apiError(interruptionMessage(null, viaCloudflare));
  }

  const DONE = Symbol('done');
  /** Parses payloads into deltas (and DONE at "[DONE]"). */
  // A generator, like Swift's emit: each delta is yielded before the next payload is parsed, so
  // text that arrived before an error payload in the same read is not lost.
  function* decodePayloads(payloads, progress) {
    for (const payload of payloads) {
      if (trim(payload) === '[DONE]') { yield DONE; return; }
      const delta = parseChunk(payload);
      if (delta) {
        progress.yieldedAny = true;
        if (delta.finishReason != null) progress.sawFinishReason = true;
        yield delta;
      }
    }
  }

  /**
   * POST {base}/chat/completions with stream:true, yielding deltas. Like ChatClient.streamChat it
   * retries once without stream_options when the server refuses that field (yielding
   * {streamOptionsRejected: true} first, so the page can remember it) and once without the "no
   * thinking" fields (yielding {thinkingOffRejected: true} first, only when the retry is accepted).
   */
  async function* streamChat({ baseURL, apiKey, messages, options, signal, fetchImpl }) {
    const url = chatURL(baseURL);
    const controller = new AbortController();
    const forward = () => controller.abort();
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener('abort', forward, { once: true });
    }
    const opts = Object.assign({}, options);
    let includeUsage = !opts.omitStreamOptions;
    let thinkingRefusal = null;
    let streamOptionsRefused = false;
    try {
      for (;;) {
        if (controller.signal.aborted) throw abortError();
        const body = buildRequestBody(messages, opts, includeUsage);
        const payload = JSON.stringify(body);
        if (opts.maxRequestBytes != null) {
          const size = new TextEncoder().encode(payload).length;
          if (size > opts.maxRequestBytes) throw apiError(requestTooLargeMessage(size, opts.maxRequestBytes));
        }
        const init = {
          method: 'POST',
          headers: Object.assign({ 'Content-Type': 'application/json', Accept: 'text/event-stream' }, authHeaders(apiKey)),
          body: payload,
          redirect: 'manual', // a redirect would replay the whole conversation to whatever host it names
          credentials: 'omit',
          signal: controller.signal,
        };
        try {
          yield* runStream({
            url, init, baseURL, signal: controller.signal, fetchImpl,
            rejectsStreamOptions: includeUsage,
            thinkingFields: sentThinkingOffFields(opts),
            serverKind: opts.serverKind,
            announceThinking: thinkingRefusal !== null,
            announceStreamOptions: streamOptionsRefused,
          });
          break;
        } catch (e) {
          if (e instanceof StreamOptionsRejected) {
            includeUsage = false;
            streamOptionsRefused = true;
          } else if (e instanceof ThinkingOffRejected) {
            opts.omitsThinkingOff = true;
            thinkingRefusal = e.error;
          } else if (e instanceof ChatError) {
            // The retry without the field was refused as well: the field was not the cause, so the
            // server's first answer is the one to show.
            if (e.kind === 'http' && thinkingRefusal) throw thinkingRefusal;
            throw e;
          } else {
            throw e;
          }
        }
      }
    } catch (e) {
      if (isAbort(e, signal) || isAbort(e, controller.signal)) throw abortError();
      throw withPathHint(e, baseURL);
    } finally {
      if (signal) signal.removeEventListener('abort', forward);
      controller.abort(); // also closes the connection when the consumer stops reading early
    }
  }

  // ---- model list -----------------------------------------------------------------------------

  const positive = (v) => {
    const n = intValue(v);
    return n !== null && n > 0 ? n : null;
  };

  /** What an entry reports, kept apart as ModelInfo does: contextLength is what is loaded/allocated
   *  (loadedContextLength), maxContextLength the most the model supports. */
  function entryContextLengths(entry) {
    const meta = isObject(entry.meta) ? entry.meta : {};
    const top = isObject(entry.top_provider) ? entry.top_provider : {};
    const first = (list) => {
      for (const c of list) { const n = positive(c); if (n !== null) return n; }
      return null;
    };
    return {
      contextLength: first([entry.loaded_context_length, meta.n_ctx, entry.max_model_len, entry.context_length,
        top.context_length, entry.context_window]),
      maxContextLength: first([entry.max_model_len, meta.n_ctx_train, entry.max_context_length]),
    };
  }

  /** GET {base}/models → [{id, contextLength?, maxContextLength?}] sorted, one entry per id. */
  async function listModels({ baseURL, apiKey, signal, fetchImpl }) {
    const url = modelsURL(baseURL);
    try {
      const response = await doFetch(fetchImpl, url, {
        method: 'GET',
        headers: Object.assign({ Accept: 'application/json' }, authHeaders(apiKey)),
        redirect: 'manual',
        credentials: 'omit',
        signal,
      }, signal);
      if (response.type === 'opaqueredirect') throw redirectRefused(response);
      if (!(response.status >= 200 && response.status < 300)) {
        throw httpError(response.status, await readErrorBody(response, baseURL));
      }
      let text;
      try {
        text = new TextDecoder('utf-8').decode(new Uint8Array(await response.arrayBuffer()).subarray(0, 64 * 1024 * 16));
      } catch (e) {
        if (isAbort(e, signal)) throw abortError();
        throw apiError(interruptionMessage('The network connection was lost.', false));
      }
      const object = parseJSON(text);
      if (object === undefined) {
        // A 200 HTML page: a captive portal or a proxy's sign-in page, never a model list.
        const head = trim(text.slice(0, 64 * 1024));
        if (isHTMLText(head)) throw apiError(`The server answered with a web page (${htmlSummary(head)}) instead of a model list.`);
        throw apiError("The server's model list is not valid JSON.");
      }
      let list;
      if (isObject(object)) {
        // Some servers (LM Studio for an unknown endpoint) answer 200 with an error body.
        if (object.error !== undefined && object.error !== null) throw apiError(errorMessageFrom(object.error));
        if (object.object === 'error') throw apiError(errorMessageFrom(object));
        if (Array.isArray(object.data)) list = object.data;
        else if (Array.isArray(object.models)) list = object.models;
        else throw apiError("The server's model list has an unexpected format.");
      } else if (Array.isArray(object)) {
        list = object;
      } else {
        throw apiError("The server's model list has an unexpected format.");
      }
      const found = new Map();
      for (const item of list) {
        let id = null;
        let entry = null;
        if (isObject(item)) {
          if (typeof item.id === 'string') id = item.id;
          else if (typeof item.name === 'string') id = item.name;
          entry = item;
        } else if (typeof item === 'string') {
          id = item;
        }
        if (id === null) continue;
        const lens = entry ? entryContextLengths(entry) : { contextLength: null, maxContextLength: null };
        const known = found.get(id);
        const informative = lens.contextLength !== null || lens.maxContextLength !== null;
        if (!known || (known.contextLength === undefined && known.maxContextLength === undefined && informative)) {
          const out = { id };
          if (lens.contextLength !== null) out.contextLength = lens.contextLength;
          if (lens.maxContextLength !== null) out.maxContextLength = lens.maxContextLength;
          found.set(id, out);
        }
      }
      const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
      return Array.from(found.values()).sort((a, b) => collator.compare(a.id, b.id) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    } catch (e) {
      if (isAbort(e, signal)) throw abortError();
      throw withPathHint(e, baseURL);
    }
  }

  return {
    ChatError, chatURL, modelsURL, buildRequestBody, thinkingOffFields, sentThinkingOffFields,
    SSEParser, parseChunk, StreamAccumulator, GenerationMeter, streamChat, listModels,
    contextLengthFromError, htmlSummary, MISSING_VERSION_PATH_HINT, NETWORK_HINT,
  };
})();
