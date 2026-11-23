// Writes files produced by the JS code (Reader/src/core.js) for the Swift cross-check:
//   node tools/web_fixtures.mjs DIR
// DIR/plain.json, DIR/encrypted.json (password PASSWORD, 1000 iterations for speed) and
// DIR/expected.json (the conversation both files must decode to). Swift reads them with
// Parley's own code (Tests/ParleyCoreTests/WebFixtureTests.swift).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PASSWORD = 'correct horse'; // also used by the Swift side
export const ITERATIONS = 1000;

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export function loadCore() {
  if (!globalThis.ParleyCore) (0, eval)(readFileSync(join(root, 'Reader/src/core.js'), 'utf8'));
  return globalThis.ParleyCore;
}

// A 1x1 PNG.
export const PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/** Uppercase UUIDs, ISO dates without fractions, nil fields left out: as the app writes them. */
export function sampleConversation() {
  const id = i => `A0000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
  return {
    id: id(1),
    title: 'Fixture ünïcode 日本語',
    createdAt: '2026-11-23T10:00:00Z',
    updatedAt: '2026-11-23T10:15:30Z',
    settings: {
      providerID: id(99), // a server the Mac app does not know
      model: 'qwen3-32b',
      systemPrompt: 'You are terse.',
      temperature: 0.7,
      maxTokens: 2048,
      reasoningEffort: 'high',
    },
    messages: [
      {
        id: id(10), role: 'user', content: 'What is in the picture and the file?',
        attachments: [
          { id: id(20), kind: 'image', filename: 'dot.png', mimeType: 'image/png', data: PNG_BASE64 },
          { id: id(21), kind: 'text', filename: 'notes "q".txt', mimeType: 'text/plain', text: 'line one\nline two' },
        ],
        createdAt: '2026-11-23T10:00:05Z', isComplete: true,
      },
      {
        id: id(11), role: 'assistant', content: 'A single pixel, and two lines of notes.',
        reasoning: 'The image is 1x1.', reasoningDuration: 1.5, attachments: [],
        createdAt: '2026-11-23T10:00:09Z', model: 'qwen3-32b', isComplete: true,
        usage: { promptTokens: 120, completionTokens: 30, totalTokens: 150, reasoningTokens: 8 },
        stats: { tokensPerSecond: 42.5, completionTokens: 30, timeToFirstToken: 0.5, generationDuration: 0.7, finishReason: 'stop' },
      },
      { id: id(12), role: 'user', content: 'Thanks.', attachments: [], createdAt: '2026-11-23T10:15:00Z', isComplete: true },
      {
        id: id(13), role: 'assistant', content: 'Welcome.', attachments: [],
        createdAt: '2026-11-23T10:15:30Z', model: 'qwen3-32b', isComplete: true,
      },
    ],
    compaction: {
      summary: 'The user shared a 1x1 image and a note; the assistant described them.',
      throughMessageID: id(11),
      countsStaleThroughID: id(13),
      createdAt: '2026-11-23T10:15:20Z',
      model: 'qwen3-32b',
      messageCount: 2,
    },
  };
}

async function main() {
  const dir = process.argv[2];
  if (!dir) { console.error('usage: node tools/web_fixtures.mjs DIR'); process.exit(64); }
  mkdirSync(dir, { recursive: true });
  const core = loadCore();
  const conversation = sampleConversation();
  const key = await core.newKey(PASSWORD, ITERATIONS);
  writeFileSync(join(dir, 'plain.json'), core.encodePlainFile(conversation));
  writeFileSync(join(dir, 'encrypted.json'), await core.encryptFile(conversation, key));
  writeFileSync(join(dir, 'expected.json'), JSON.stringify(conversation, null, 2));
  console.log(`wrote plain.json, encrypted.json, expected.json to ${dir}`);
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) await main();
