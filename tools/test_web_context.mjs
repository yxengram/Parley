// Tests Web/src/context.js against the Swift oracle vectors (Web/tests/vectors/usage.json,
// compaction.json).   node tools/test_web_context.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const context = vm.createContext({ crypto: globalThis.crypto, console });
// A top-level const is not a property of the context, so hand the global out explicitly.
const C = vm.runInContext(readFileSync(join(root, 'Web/src/context.js'), 'utf8') + '\n;ParleyContext;', context);
const vec = name => JSON.parse(readFileSync(join(root, 'Web/tests/vectors', name), 'utf8'));
const same = v => JSON.parse(JSON.stringify(v)); // across vm realms

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failed++; console.error('FAIL ' + name + '\n  ' + (e.message || e).split('\n').slice(0, 8).join('\n  ')); }
}
const eq = (a, b) => assert.deepEqual(same(a), same(b));

const usageV = vec('usage.json');
const comp = vec('compaction.json');

usageV.estimates.forEach((e, i) => test('estimate ' + i, () => assert.equal(C.estimateTokens(e.text), e.tokens)));
usageV.messages.forEach((e, i) => test('message ' + i, () => assert.equal(C.estimateMessage(e.message), e.tokens)));
usageV.usage.forEach((e, i) => test('usage ' + i + ' ' + e.history, () => {
  const u = C.usage(e.messages, e.systemPrompt, {
    inFlightID: e.inFlightID, liveCompletionTokens: e.liveCompletionTokens, liveIsEstimated: e.liveIsEstimated, anchorsFrom: e.anchorsFrom,
  });
  assert.equal(u.tokens, e.tokens);
  assert.equal(u.isEstimated, e.isEstimated);
}));
usageV.limits.forEach((e, i) => test('limit ' + i, () => {
  const info = { loadedContextLength: e.loaded, maxContextLength: e.max };
  eq(C.limit({ info, manual: e.manual, learned: e.learned }), e.limit);
}));
test('limit without info', () => eq(C.limit({ manual: 5 }), { tokens: 5, source: 'manual' }));

test('instruction', () => assert.equal(C.INSTRUCTION, comp.instruction));
test('block', () => assert.equal(C.block('  Summary text.  '), comp.block));
test('constants', () => {
  assert.equal(C.DEFAULT_THRESHOLD_PERCENT, comp.constants.defaultThresholdPercent);
  assert.equal(C.THRESHOLD_MIN, comp.constants.thresholdMin);
  assert.equal(C.THRESHOLD_MAX, comp.constants.thresholdMax);
  assert.equal(C.SUMMARY_MAX_TOKENS, comp.constants.summaryMaxTokens);
  assert.equal(C.KEPT_SHARE, comp.constants.keptShare);
});
comp.boundaries.forEach((b, i) => b.cases.forEach((c, j) => test(`boundary ${i}.${j}`, () => {
  assert.equal(C.boundary(b.messages, c.current, c.limitTokens, c.before), c.boundary);
})));
comp.requestMessages.forEach((r, i) => test('requestMessages ' + i, () => {
  const out = C.requestMessages(r.previousSummary, r.messages).map(m => ({ role: m.role, content: m.content, attachments: m.attachments.length }));
  eq(out, r.result);
}));
test('chunks', () => eq(C.chunks(comp.chunks.messages, comp.chunks.budgetTokens).map(c => c.map(m => m.id)), comp.chunks.result));
comp.effective.forEach(e => test('effective through ' + e.truncatedThrough, () => {
  const c = C.truncate(comp.conversation, e.truncatedThrough);
  eq(Object.assign({}, c, { updatedAt: null }), Object.assign({}, e.conversation, { updatedAt: null }));
  const h = C.effectiveHistory(c);
  eq(h.messages.map(m => m.id), e.messageIDs);
  eq(h.summaryBlock, e.summaryBlock);
  assert.equal(h.anchorsFrom, e.anchorsFrom);
  assert.equal(h.coveredCount, e.coveredCount);
  assert.equal(C.systemText(h, 'Sys'), e.systemText);
}));
test('truncate leaves the original alone', () => {
  const before = JSON.stringify(comp.conversation);
  C.truncate(comp.conversation, 1);
  assert.equal(JSON.stringify(comp.conversation), before);
});
comp.forks.forEach(f => test('fork through ' + f.through, () => {
  const out = C.forked(comp.conversation, f.through, 'NEW-ID', '2030-01-01T00:00:00Z');
  eq(out.messages.map(m => m.id), f.messageIDs);
  if (f.compaction === null) assert.equal(out.compaction, undefined); else eq(out.compaction, f.compaction);
  assert.equal(out.id, 'NEW-ID');
  assert.equal(out.title, 'T (fork)');
  eq(out.forkedFrom, { conversationID: comp.conversation.id, messageID: f.messageIDs[f.messageIDs.length - 1] });
  eq(out.settings, comp.conversation.settings);
  assert.equal(out.createdAt, '2030-01-01T00:00:00Z');
}));
comp.due.forEach((d, i) => test('due ' + i, () => {
  const lim = d.limit == null ? null : { tokens: d.limit, source: 'manual' };
  assert.equal(C.isDue({ tokens: d.tokens, isEstimated: true }, lim, d.percent), d.due);
}));

test('isoDate has no fraction', () => {
  assert.equal(C.isoDate(new Date(Date.UTC(2026, 10, 23, 10, 15, 30, 789))), '2026-11-23T10:15:30Z');
  assert.match(C.isoNow(), /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
});
test('newID is an uppercase UUID', () => {
  const a = C.newID(), b = C.newID();
  assert.match(a, /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/);
  assert.notEqual(a, b);
});
test('estimateTokens counts emoji as one scalar', () => assert.equal(C.estimateTokens('\u{1F389}\u{1F389}\u{1F389}\u{1F389}'), 1));

// --- review fixes ---
const U = (id, content, extra) => Object.assign({ id, role: 'user', content, attachments: [] }, extra);
const A = (id, content, extra) => Object.assign({ id, role: 'assistant', content, attachments: [] }, extra);
const rounds = [{ calls: [{ name: 'f', result: 'r' }] }];
test('blank reply with tool rounds is not skipped', () => {
  const ms = [U('1', 'q'), A('2', '  ', { toolRounds: rounds }), U('3', 'q2'), A('4', 'a')];
  const req = C.requestMessages(null, ms.slice(0, 2));
  assert.equal(req.some(m => m.id === '2'), true);
  eq(C.chunks(ms, 1000)[0].map(m => m.id), ['1', '2', '3', '4']);
  assert.equal(C.boundary([U('1', 'q'), A('2', '', { toolRounds: rounds }), U('3', 'q2')], 0, 4), 1);
  assert.equal(C.boundary([U('1', 'q'), A('2', ''), U('3', 'q2')], 0, 4), null);
  const base = C.usage([U('1', 'q')], '').tokens;
  assert.equal(C.usage([U('1', 'q'), A('2', '', { toolRounds: rounds })], '').tokens, base + C.MESSAGE_OVERHEAD);
  assert.equal(C.usage([U('1', 'q'), A('2', '')], '').tokens, base);
});
test('alternating joins tool rounds', () => {
  const out = C.alternating([A('1', 'a', { toolRounds: rounds }), A('2', 'b', { toolRounds: rounds })]);
  assert.equal(out.length, 1);
  assert.equal(out[0].toolRounds.length, 2);
  assert.equal(C.alternating([A('1', 'a'), A('2', 'b')])[0].toolRounds, undefined);
});
test('alternating: assistant first, consecutive same role', () => {
  eq(C.alternating([A('1', 'a'), A('2', ''), U('3', 'u')]).map(m => [m.role, m.content]), [['assistant', 'a'], ['user', 'u']]);
  const r = C.requestMessages(null, [A('1', 'a'), A('2', 'b'), U('3', 'u')]);
  eq(r.map(m => m.role), ['user', 'assistant', 'user', 'assistant', 'user']);
  eq(r[1].content, 'a\n\nb');
});
test('trim and isBlank: NEL, BOM, LS', () => {
  assert.equal(C.isBlank('\u0085'), true);
  assert.equal(C.isBlank('\u2028 \n'), true);
  assert.equal(C.isBlank('\uFEFF'), false);
  assert.equal(C.trim('\u0085 x\u2028'), 'x');
  assert.equal(C.trim('\uFEFFx\uFEFF'), '\uFEFFx\uFEFF');
  assert.equal(C.trim('   '), '');
});
test('long whitespace runs are fast', () => {
  const t0 = Date.now();
  const s = 'a' + ' '.repeat(100000) + 'b';
  assert.equal(C.block(s).includes(s), true);
  C.trim(' '.repeat(100000) + 'x'); C.isBlank(s);
  assert.ok(Date.now() - t0 < 500);
});
test('forked: fractional now string, missing settings', () => {
  const conv = { id: 'C', title: 'T', messages: [U('1', 'q')] };
  const out = C.forked(conv, 0, 'N', '2030-01-01T00:00:00.123Z');
  assert.equal(out.createdAt, '2030-01-01T00:00:00Z');
  assert.equal(out.settings, undefined);
});
test('requestMessages: image-only user message', () => {
  const r = C.requestMessages(null, [U('1', '', { attachments: [{ kind: 'image', data: 'x' }] })]);
  assert.equal(r[0].content, '\n\n[An image was attached here.]');
  assert.equal(r[0].attachments.length, 0);
});
test('synthesized ids are UUIDs', () => {
  const r = C.requestMessages('s', [U('1', 'q')]);
  assert.match(r[0].id, /^[0-9A-F]{8}-/);
});
test('usage: anchorsFrom beyond length, inFlight newest anchor', () => {
  const an = A('2', 'a', { usage: { promptTokens: 100, completionTokens: 10 } });
  const ms = [U('1', 'q'), an];
  const est = C.usage(ms, '', { anchorsFrom: 99 });
  assert.equal(est.tokens, C.estimateMessage(ms[0]) + C.estimateMessage(an));
  const fl = C.usage(ms, '', { inFlightID: '2' });
  assert.equal(fl.tokens, C.estimateMessage(ms[0]));
  const older = [A('0', 'o', { usage: { promptTokens: 50, completionTokens: 5 } }), U('1', 'q'), an];
  assert.equal(C.usage(older, '', { inFlightID: '2' }).tokens, 55 + C.estimateMessage(older[1]));
});
test('truncate out of range returns the input unchanged', () => {
  const conv = { id: 'C', updatedAt: 'X', messages: [U('1', 'q')] };
  assert.equal(C.truncate(conv, 5), conv);
  assert.equal(C.truncate(conv, -2), conv);
  assert.equal(conv.updatedAt, 'X');
});

console.log(failed ? `${failed} failed, ${passed} passed` : `all ${passed} passed`);
process.exit(failed ? 1 : 0);
