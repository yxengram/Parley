// Parley Web context: token estimate, context usage and limit, and compaction.
// Port of Sources/ParleyCore/ContextBudget.swift and Compaction.swift, plus the compaction rules
// of Conversation.truncate / forked. No DOM, no network. Runs in the page and in Node (tests).
// Messages are plain objects in the app's JSON shape (ids are uppercase UUID strings).
const ParleyContext = (() => {
  'use strict';

  const IMAGE_TOKENS = 768;     // rough cost of one image
  const MESSAGE_OVERHEAD = 4;   // chat-template tokens per message

  const DEFAULT_THRESHOLD_PERCENT = 80;
  const THRESHOLD_MIN = 30;
  const THRESHOLD_MAX = 95;
  const SUMMARY_MAX_TOKENS = 2048;
  const KEPT_SHARE = 0.25;

  // Same wording as Compaction.instruction (model-facing).
  const INSTRUCTION =
    'Summarize the conversation above so that it can continue without it. Write in the language ' +
    'the conversation is in. Keep: what the user wants and has decided, facts, names, numbers, ' +
    'file names and addresses that came up, what tools returned that still matters, code that is ' +
    'still being worked on (quote it if it is short), questions still open, and where things were ' +
    'left. Leave out pleasantries and anything already settled and no longer needed. Write the ' +
    'summary only, with no introduction, as compact notes.';

  // Swift's whitespacesAndNewlines: Unicode white space plus NEL; JS \s also has the BOM, which
  // Swift does not trim, and lacks NEL.
  const WS = '(?:(?!\\uFEFF)[\\s\\u0085])';
  const BLANK_RE = new RegExp('^' + WS + '*$');
  // A manual scan: a trailing-whitespace regex is quadratic on long runs of white space.
  const isWS = c => c === 0x85 || (c !== 0xFEFF && /\s/.test(String.fromCharCode(c)));
  function trim(s) {
    s = String(s);
    let a = 0, b = s.length;
    while (a < b && isWS(s.charCodeAt(a))) a++;
    while (b > a && isWS(s.charCodeAt(b - 1))) b--;
    return s.slice(a, b);
  }
  const isBlank = s => BLANK_RE.test(s);

  /** Messages a request leaves out anyway: blank failed replies (not those with tool rounds). */
  const isSkipped = m => m.role === 'assistant' && !(m.toolRounds && m.toolRounds.length) && isBlank(m.content);

  function isCJK(v) {
    return (v >= 0x3000 && v <= 0x303F) || (v >= 0x3040 && v <= 0x30FF) ||
      (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF) ||
      (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0xF900 && v <= 0xFAFF) ||
      (v >= 0xFF00 && v <= 0xFFEF) || (v >= 0x20000 && v <= 0x2FA1F);
  }

  /** CJK characters ~ 1 token each, everything else ~ 4 characters per token. Counts code
   *  points (Swift unicode scalars), not UTF-16 units, so emoji count once. */
  function estimateTokens(text) {
    let cjk = 0, other = 0;
    for (const ch of String(text || '')) {
      if (isCJK(ch.codePointAt(0))) cjk++; else other++;
    }
    return cjk + Math.floor((other + 3) / 4);
  }

  /** What one message costs in a request: text, text attachments, images (never reasoning).
   *  Tool rounds are a later phase. */
  function estimateMessage(message) {
    let tokens = MESSAGE_OVERHEAD + estimateTokens(message.content);
    if (message.role !== 'user') return tokens;
    for (const a of message.attachments || []) {
      if (a.kind === 'text') {
        // Sent wrapped as <file name="...">...</file>.
        tokens += estimateTokens(a.text || '') + estimateTokens(a.filename) + 8;
      } else if (a.kind === 'image') {
        tokens += a.data == null ? 0 : IMAGE_TOKENS;
      }
    }
    return tokens;
  }

  /** Precedence: what the server uses now > the user's value > the value an overflow error
   *  named > the model's maximum. `info` is {loadedContextLength, maxContextLength}. */
  function limit({ info, manual, learned } = {}) {
    const pos = n => typeof n === 'number' && n > 0;
    if (info && pos(info.loadedContextLength)) return { tokens: info.loadedContextLength, source: 'server' };
    if (pos(manual)) return { tokens: manual, source: 'manual' };
    if (pos(learned)) return { tokens: learned, source: 'learned' };
    if (info && pos(info.maxContextLength)) return { tokens: info.maxContextLength, source: 'serverMaximum' };
    return null;
  }

  function countedTotal(usage) {
    if (!usage) return null;
    if (usage.promptTokens != null) return usage.promptTokens + (usage.completionTokens || 0);
    return usage.totalTokens != null ? usage.totalTokens : null;
  }

  function reasoningFor(usage, reasoning) {
    if (usage.reasoningTokens != null) return usage.reasoningTokens;
    if (!reasoning) return 0;
    const estimate = estimateTokens(reasoning);
    return usage.completionTokens != null ? Math.min(estimate, usage.completionTokens) : estimate;
  }

  /** The reply's thinking tokens, which the next request leaves out: the server's count, else
   *  an estimate from the reasoning text, never more than the completion tokens. */
  function reasoningTokens(message) {
    const usage = message.usage;
    if (!usage) return 0;
    const reasoning = reasoningFor(usage, message.reasoning);
    if (!message.reactThought) return reasoning;
    const total = reasoning + estimateTokens(message.reactThought);
    return usage.completionTokens != null ? Math.min(total, usage.completionTokens) : total;
  }

  function counted(message) {
    const total = countedTotal(message.usage);
    return total == null ? null : Math.max(0, total - reasoningTokens(message));
  }

  function hasAnchor(message, inFlightID) {
    return message.role === 'assistant' && message.id !== inFlightID && counted(message) != null;
  }

  /** Tokens the conversation occupies: starts from the newest reply the server counted (minus
   *  its reasoning) and estimates only what came after; without a count, everything is
   *  estimated, system prompt included. `inFlightID` is left out; its tokens so far are
   *  `liveCompletionTokens`. `anchorsFrom`: only messages from this index on may anchor
   *  (after compaction, earlier counts took the whole history). */
  function usage(messages, systemPrompt, opts = {}) {
    const { inFlightID = null, liveCompletionTokens = 0, liveIsEstimated = false, anchorsFrom = 0 } = opts;
    let tokens = 0, estimated = false, start = 0;
    const first = Math.min(Math.max(0, anchorsFrom), messages.length);
    let anchor = -1;
    for (let i = messages.length - 1; i >= first; i--) {
      if (hasAnchor(messages[i], inFlightID)) { anchor = i; break; }
    }
    if (anchor >= 0) {
      tokens = counted(messages[anchor]);
      start = anchor + 1;
    } else {
      const system = trim(systemPrompt || '');
      if (system) { tokens += MESSAGE_OVERHEAD + estimateTokens(system); estimated = true; }
    }
    for (let i = start; i < messages.length; i++) {
      const m = messages[i];
      if (m.id === inFlightID) continue;
      // Empty (failed) replies are not sent; one that ended in a tool round is.
      if (isSkipped(m)) continue;
      tokens += estimateMessage(m);
      estimated = true;
    }
    if (liveCompletionTokens > 0) {
      tokens += liveCompletionTokens;
      estimated = estimated || liveIsEstimated;
    }
    return { tokens, isEstimated: estimated };
  }

  // MARK: Compaction

  /** The summary as the system text carries it. Model-facing, so English, marked as data. */
  function block(summary) {
    return '<conversation_summary>\nThe earlier part of this conversation was summarized to save space. This summary ' +
      'stands for those messages; the messages after it continue from where it ends.\n\n' +
      trim(summary) + '\n</conversation_summary>';
  }

  /** True when the estimate has reached `percent` of a known limit. */
  function isDue(usage, limit, percent) {
    if (!limit || !(limit.tokens > 0)) return false;
    return usage.tokens >= limit.tokens * percent / 100;
  }


  /** The last message a new summary should cover, or null. The kept tail starts at a user
   *  message, holds at least the newest user turn and what follows, and grows backwards by whole
   *  turns while it fits KEPT_SHARE of `limitTokens`. Never goes back past `current`. `before`
   *  leaves out messages from the end (the reply about to be written). */
  function boundary(messages, current, limitTokens, before) {
    const end = Math.min(before == null ? messages.length : before, messages.length);
    const userStarts = [];
    for (let i = 0; i < end; i++) if (messages[i].role === 'user') userStarts.push(i);
    if (!userStarts.length) return null;
    const lastUser = userStarts[userStarts.length - 1];
    const budget = Math.trunc((limitTokens || 0) * KEPT_SHARE);
    const sum = (a, b) => { let t = 0; for (let i = a; i < b; i++) t += estimateMessage(messages[i]); return t; };
    let tailStart = lastUser;
    let tailTokens = sum(lastUser, end);
    for (let k = userStarts.length - 2; k >= 0; k--) {
      const start = userStarts[k];
      const turn = sum(start, tailStart);
      if (!(budget > 0 && tailTokens + turn <= budget)) break;
      tailStart = start;
      tailTokens += turn;
    }
    const through = tailStart - 1;
    const cur = current == null ? -1 : current;
    if (through < 0 || through <= cur) return null;
    // Only blank failed replies would be summarized: not worth a request.
    for (let i = cur + 1; i <= through; i++) if (!isSkipped(messages[i])) return through;
    return null;
  }

  /** Joins neighbours of the same role so roles alternate. */
  function alternating(messages) {
    const out = [];
    for (const m of messages) {
      const last = out[out.length - 1];
      if (last && last.role === m.role) {
        const joined = Object.assign({}, last, {
          content: [last.content, m.content].filter(c => !isBlank(c)).join('\n\n'),
          attachments: (last.attachments || []).concat(m.attachments || []),
        });
        const rounds = (last.toolRounds || []).concat(m.toolRounds || []);
        if (rounds.length) joined.toolRounds = rounds; else delete joined.toolRounds;
        out[out.length - 1] = joined;
      } else {
        out.push(m);
      }
    }
    return out;
  }

  // Request-only messages; real UUIDs so they would still decode if ever stored.
  const synth = (role, content) => ({
    id: newID(), role, content, attachments: [], createdAt: isoNow(), isComplete: true,
  });

  /** The messages of one summary request: the previous summary as a first user turn, the
   *  messages to fold in (images replaced by a note, reasoning dropped), then the instruction.
   *  Roles strictly alternate from a user turn. */
  function requestMessages(previousSummary, messages) {
    const out = [];
    if (previousSummary != null && !isBlank(previousSummary)) {
      out.push(synth('user', 'Summary of the conversation so far:\n\n' + previousSummary));
    }
    for (const message of messages) {
      if (isSkipped(message)) continue;
      const copy = Object.assign({}, message);
      const images = (copy.attachments || []).filter(a => a.kind === 'image').length;
      copy.attachments = (copy.attachments || []).filter(a => a.kind !== 'image');
      if (images > 0) copy.content += '\n\n[' + (images === 1 ? 'An image' : images + ' images') + ' was attached here.]';
      delete copy.reasoning;
      // A reply cannot open the request.
      if (!out.length && copy.role !== 'user') out.push(synth('user', '(The conversation began earlier.)'));
      out.push(copy);
    }
    if (out.length && out[out.length - 1].role === 'user') out.push(synth('assistant', '(No reply yet.)'));
    out.push(synth('user', INSTRUCTION));
    return alternating(out);
  }

  /** The covered messages in pieces that each fit `budget` tokens. A message longer than the
   *  budget goes alone. */
  function chunks(messages, budget) {
    const out = [];
    let current = [], used = 0;
    for (const m of messages) {
      if (isSkipped(m)) continue;
      const cost = estimateMessage(m);
      if (current.length && used + cost > budget) { out.push(current); current = []; used = 0; }
      current.push(m);
      used += cost;
    }
    if (current.length) out.push(current);
    return out;
  }

  /** Where the compaction's summary ends, if it still matches this history. */
  function compactionBoundary(conversation) {
    const c = conversation.compaction;
    if (!c) return null;
    const i = conversation.messages.findIndex(m => m.id === c.throughMessageID);
    return i < 0 ? null : i;
  }

  /** What the next request carries: {messages, summaryBlock, anchorsFrom, coveredCount}. */
  function effectiveHistory(conversation) {
    const b = compactionBoundary(conversation);
    if (!conversation.compaction || b == null) {
      return { messages: conversation.messages, summaryBlock: null, anchorsFrom: 0, coveredCount: 0 };
    }
    const tail = conversation.messages.slice(b + 1);
    // A count from before the summary existed was taken with the whole history in the prompt.
    let anchorsFrom = 0;
    const stale = conversation.compaction.countsStaleThroughID;
    if (stale) {
      const i = tail.findIndex(m => m.id === stale);
      if (i >= 0) anchorsFrom = i + 1;
    }
    return { messages: tail, summaryBlock: block(conversation.compaction.summary), anchorsFrom, coveredCount: b + 1 };
  }

  /** The system text the context estimate counts: the prompt and the summary. */
  function systemText(effective, prompt) {
    if (effective.summaryBlock == null) return prompt;
    return isBlank(prompt) ? effective.summaryBlock : prompt + '\n\n' + effective.summaryBlock;
  }

  /** When the message that marks where stale counts end is gone, every message left predates
   *  the summary, so the mark moves to the last one. */
  function restaled(compaction, messages) {
    if (!compaction || !compaction.countsStaleThroughID) return compaction;
    if (messages.some(m => m.id === compaction.countsStaleThroughID)) return compaction;
    const last = messages[messages.length - 1];
    const copy = Object.assign({}, compaction);
    if (last) copy.countsStaleThroughID = last.id; else delete copy.countsStaleThroughID;
    return copy;
  }

  /** A new conversation keeping messages[0..index] (rollback). A compaction whose summary
   *  covers a message that goes is dropped with it. */
  function truncate(conversation, index) {
    if (!(index >= -1 && index < conversation.messages.length)) return conversation;
    const out = Object.assign({}, conversation, { messages: conversation.messages.slice(0, index + 1), updatedAt: isoNow() });
    if (out.compaction && compactionBoundary(out) == null) delete out.compaction;
    if (out.compaction) out.compaction = restaled(out.compaction, out.messages);
    return out;
  }

  /** A new conversation containing messages[0..index] (fork) with a fresh id. */
  function forked(conversation, index, newIDValue, now) {
    const clamped = Math.min(Math.max(index, -1), conversation.messages.length - 1);
    const prefix = conversation.messages.slice(0, clamped + 1);
    const stamp = now == null ? isoNow() : isoDate(now);
    const out = {
      id: newIDValue || newID(),
      title: conversation.title + ' (fork)',
      createdAt: stamp,
      updatedAt: stamp,
      settings: conversation.settings == null ? conversation.settings : JSON.parse(JSON.stringify(conversation.settings)),
      messages: prefix,
    };
    if (prefix.length) out.forkedFrom = { conversationID: conversation.id, messageID: prefix[prefix.length - 1].id };
    const c = conversation.compaction;
    // Kept when the fork holds every message it covers.
    if (c && prefix.some(m => m.id === c.throughMessageID)) out.compaction = restaled(Object.assign({}, c), prefix);
    return out;
  }

  // MARK: Ids and dates

  /** ISO 8601 without fractional seconds (Swift's .iso8601 rejects fractions). */
  function isoDate(d) {
    return new Date(d).toISOString().replace(/\.\d+Z$/, 'Z');
  }
  function isoNow() { return isoDate(new Date()); }

  function newID() {
    return globalThis.crypto.randomUUID().toUpperCase();
  }

  return {
    IMAGE_TOKENS, MESSAGE_OVERHEAD,
    DEFAULT_THRESHOLD_PERCENT, THRESHOLD_MIN, THRESHOLD_MAX, SUMMARY_MAX_TOKENS, KEPT_SHARE,
    INSTRUCTION,
    estimateTokens, estimateMessage, usage, limit,
    block, isDue, boundary, requestMessages, alternating, chunks,
    compactionBoundary, effectiveHistory, systemText, truncate, forked,
    isBlank, trim, isoNow, isoDate, newID,
  };
})();
