import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import type { HighlightRecord, JsonValue, NoteRecord, WordRecord } from "../contract/types";
import { codePointsOf, normalizeWord, wordId } from "../contract/wordId";
import { canonicalJson, payloadsEqual, sameRecord, sortJson } from "../sync/canonical";
import { FakeClock } from "../sync/clock";
import { MemoryCredentialStore } from "../sync/credentials";
import { SyncEngine } from "../sync/engine";
import { MockSyncServer } from "../sync/mock/server";
import { MemorySyncStorage, type LocalRecord, type PersistedSync } from "../sync/storage";
import { HttpTransport } from "../sync/transport";
import type { ChangeInput, JsonObject, Locator } from "../sync/wire";

// ---------------------------------------------------------------------------
// Deterministic Seeded PRNG (SplitMix64) & Formal Config
// ---------------------------------------------------------------------------

const MASK64 = 0xffff_ffff_ffff_ffffn;

class SplitMix64 {
  private state: bigint;

  constructor(seed: bigint) {
    this.state = seed & MASK64;
  }

  nextU64(): bigint {
    this.state = (this.state + 0x9e37_79b9_7f4a_7c15n) & MASK64;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & MASK64;
    return (z ^ (z >> 31n)) & MASK64;
  }

  nextInt(min: number, max: number): number {
    const span = BigInt(max - min + 1);
    return min + Number(this.nextU64() % span);
  }

  nextBool(probabilityTrue = 0.5): boolean {
    const unit = Number(this.nextU64() >> 11n) / 2 ** 53;
    return unit < probabilityTrue;
  }

  pick<T>(items: readonly T[]): T {
    return items[this.nextInt(0, items.length - 1)]!;
  }

  shuffle<T>(items: readonly T[]): T[] {
    const copy = [...items];
    for (let i = copy.length - 1; i > 0; i -= 1) {
      const j = this.nextInt(0, i);
      const tmp = copy[i]!;
      copy[i] = copy[j]!;
      copy[j] = tmp;
    }
    return copy;
  }
}

const DEFAULT_SEED = 0x5245_4144_4552_0003n;
const DEFAULT_CASES = 200;

function readFormalSeed(): bigint {
  const raw = process.env.FORMAL_SEED?.trim();
  if (!raw) return DEFAULT_SEED;
  try {
    return BigInt(raw) & MASK64;
  } catch {
    return DEFAULT_SEED;
  }
}

function readFormalCases(): number {
  const raw = process.env.FORMAL_CASES?.trim();
  if (!raw) return DEFAULT_CASES;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_CASES;
}

function seedTag(seed: bigint, caseIndex?: number): string {
  const hex = `0x${seed.toString(16).padStart(16, "0")}`;
  return caseIndex === undefined ? `[FORMAL_SEED=${hex}]` : `[FORMAL_SEED=${hex} case=${caseIndex}]`;
}

// ---------------------------------------------------------------------------
// Fixture & JSON Generators
// ---------------------------------------------------------------------------

interface WordFixtureCase {
  name: string;
  inputCodepoints: string[];
  expectedCodepoints: string[];
  hasWordId: boolean;
}

function loadWordIdFixture(): WordFixtureCase[] {
  const here = dirname(fileURLToPath(import.meta.url));
  const fixturePath = join(here, "..", "contract", "fixtures", "word-id-normalize.json");
  const raw = JSON.parse(readFileSync(fixturePath, "utf8")) as { cases: WordFixtureCase[] };
  return raw.cases;
}

function parseCodepointLabels(labels: string[]): number[] {
  return labels.map((label) => Number.parseInt(label.slice(2), 16));
}

function stringFromCodepoints(points: number[]): string {
  return points.length === 0 ? "" : String.fromCodePoint(...points);
}

function randomJsonValue(rng: SplitMix64, depth = 0): JsonValue {
  if (depth >= 3) {
    const leaf = rng.nextInt(0, 4);
    if (leaf === 0) return null;
    if (leaf === 1) return rng.nextBool();
    if (leaf === 2) return rng.nextInt(-1000, 1000);
    if (leaf === 3) return rng.nextInt(-100, 100) / 4;
    return rng.pick(["", "alpha", "beta", "café", "λόγος", "漢字", "quote\nline"]);
  }
  const kind = rng.nextInt(0, 5);
  if (kind <= 2) return randomJsonValue(rng, 3);
  if (kind === 3) {
    const len = rng.nextInt(0, 4);
    return Array.from({ length: len }, () => randomJsonValue(rng, depth + 1));
  }
  const keys = rng.shuffle(["z", "a", "m", "b", "k1", "k2", "extras", "quote"]).slice(0, rng.nextInt(0, 5));
  const obj: { [key: string]: JsonValue } = {};
  for (const key of keys) {
    obj[key] = randomJsonValue(rng, depth + 1);
  }
  return obj;
}

function permuteKeysAndInjectUndefined(rng: SplitMix64, value: JsonValue): unknown {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map((item) => permuteKeysAndInjectUndefined(rng, item));
  const entries = rng.shuffle(Object.entries(value));
  const out: Record<string, unknown> = {};
  if (rng.nextBool(0.35)) out.__dropped_a = undefined;
  for (const [k, v] of entries) {
    out[k] = permuteKeysAndInjectUndefined(rng, v);
  }
  if (rng.nextBool(0.35)) out.__dropped_z = undefined;
  return out;
}

// ---------------------------------------------------------------------------
// Mobile SyncEngine Harness & Invariant Checker
// ---------------------------------------------------------------------------

const BASE_URL = "http://sync.formal.test/v1/reader";
const SHA_A = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"; // sha256("abc")
const BOOK_A = `sha256:${SHA_A}`;
const BYTES_A = new TextEncoder().encode("abc");

function makeQr(baseUrl: string, token: string, serverId: string): string {
  return `readersync://pair?v=2&url=${encodeURIComponent(baseUrl)}&token=${encodeURIComponent(token)}&server=${encodeURIComponent(serverId)}`;
}

interface HarnessEnv {
  server: MockSyncServer;
  macCredential: string;
  storage: MemorySyncStorage;
  credentials: MemoryCredentialStore;
  clock: FakeClock;
  session: { baseUrl: string | null; credential: string | null };
  transport: HttpTransport;
  engine: SyncEngine;
  lastServerId: string | null;
  lastCursor: number;
}

async function createMobileHarness(options?: {
  server?: MockSyncServer;
  pullLimit?: number;
  serverId?: string;
}): Promise<HarnessEnv> {
  const server = options?.server ?? new MockSyncServer({ serverId: options?.serverId ?? "srv_a", now: () => "2026-11-28T00:00:00.000Z" });
  const macCredential = server.pairDevice({ deviceId: "mac-1", name: "Arturo's Mac", platform: "mac", kind: "mac" });
  const storage = new MemorySyncStorage();
  const credentials = new MemoryCredentialStore();
  const clock = new FakeClock();
  const session = { baseUrl: null as string | null, credential: null as string | null };
  const transport = new HttpTransport({
    fetchImpl: (input, init) => server.fetch(input, init),
    baseUrl: () => session.baseUrl,
    credential: () => session.credential,
  });
  const engine = new SyncEngine({
    transport,
    storage,
    credentials,
    clock,
    session,
    pullLimit: options?.pullLimit ?? 2,
    device: { deviceId: "phone-1", name: "Arturo's Phone", platform: "ios", appVersion: "1.0.0-formal" },
  });
  server.issueToken("tok_phone");
  await engine.pair(makeQr(BASE_URL, "tok_phone", server.serverId));
  await engine.trackBook({
    sha256: SHA_A,
    size: BYTES_A.byteLength,
    format: "pdf",
    title: "Formal Book",
    filename: "formal.pdf",
    docId: "doc-formal-1",
  });
  return {
    server,
    macCredential,
    storage,
    credentials,
    clock,
    session,
    transport,
    engine,
    lastServerId: engine.exportState().serverId,
    lastCursor: engine.exportState().cursor,
  };
}

function recreateEngineAfterRestart(env: HarnessEnv, pullLimit = 2): SyncEngine {
  env.engine.stop();
  const freshSession = { baseUrl: null as string | null, credential: null as string | null };
  env.session = freshSession;
  env.transport = new HttpTransport({
    fetchImpl: (input, init) => env.server.fetch(input, init),
    baseUrl: () => env.session.baseUrl,
    credential: () => env.session.credential,
  });
  env.engine = new SyncEngine({
    transport: env.transport,
    storage: env.storage,
    credentials: env.credentials,
    clock: env.clock,
    session: env.session,
    pullLimit,
    device: { deviceId: "phone-1", name: "Arturo's Phone", platform: "ios", appVersion: "1.0.0-formal" },
  });
  return env.engine;
}

async function macPushRaw(
  server: MockSyncServer,
  credential: string,
  change: ChangeInput,
): Promise<{ results: { status: string; version?: number; seq?: number; error?: { code: string } }[] }> {
  const response = await server.fetch(`${BASE_URL}/v1/changes`, {
    method: "POST",
    headers: { authorization: `Bearer ${credential}`, "content-type": "application/json" },
    body: JSON.stringify({ batchId: globalThis.crypto.randomUUID(), changes: [change] }),
  });
  return (await response.json()) as { results: { status: string; version?: number; seq?: number; error?: { code: string } }[] };
}

async function macRegisterBookA(server: MockSyncServer, credential: string): Promise<void> {
  await server.fetch(`${BASE_URL}/v1/books`, {
    method: "POST",
    headers: { authorization: `Bearer ${credential}`, "content-type": "application/json" },
    body: JSON.stringify({
      sha256: SHA_A,
      size: BYTES_A.byteLength,
      format: "pdf",
      title: "Formal Book",
      filename: "formal.pdf",
      docId: "doc-formal-1",
    }),
  });
}

function checkPersistedInvariants(state: PersistedSync, prev: { serverId: string | null; cursor: number }, context: string): string | null {
  // 1. Unique record keys in state.records
  const recordKeys = new Set<string>();
  for (const r of state.records) {
    const k = `${r.bookId}\0${r.kind}\0${r.id}`;
    if (recordKeys.has(k)) return `${context}: duplicate LocalRecord key ${k}`;
    recordKeys.add(k);
  }
  // 2. Unique record keys within pending batch and within inflight batch
  for (const [label, batch] of [
    ["pending", state.pending],
    ["inflight", state.inflight],
  ] as const) {
    if (!batch) continue;
    const seen = new Set<string>();
    for (const c of batch.changes) {
      const k = `${c.bookId}\0${c.kind}\0${c.id}`;
      if (seen.has(k)) return `${context}: duplicate ${label} outbox change for ${k}`;
      seen.add(k);
    }
  }
  // 3. Monotonic cursor while serverId is unchanged
  if (prev.serverId !== null && state.serverId === prev.serverId && state.cursor < prev.cursor) {
    return `${context}: cursor regressed from ${prev.cursor} to ${state.cursor} under unchanged serverId=${prev.serverId}`;
  }
  return null;
}

function assertMobileInvariants(env: HarnessEnv, context: string): void {
  const state = env.engine.exportState();
  const violation = checkPersistedInvariants(state, { serverId: env.lastServerId, cursor: env.lastCursor }, context);
  assert.equal(violation, null, violation ?? undefined);
  env.lastServerId = state.serverId;
  env.lastCursor = state.cursor;
}

function makeHighlight(id: string, quote: string, color: 1 | 2 | 3 | 4 | 5 | 6 = 1): HighlightRecord {
  return {
    id,
    color,
    quote,
    prefix: "pre ",
    suffix: " suf",
    rects: [],
    extras: { origin: "phone" },
  };
}

function makeNote(id: string, body: string): NoteRecord {
  return {
    id,
    quote: "anchored quote",
    prefix: "pre ",
    suffix: " suf",
    ai: false,
    scope: "passage",
    body,
    extras: { origin: "phone" },
  };
}

// ---------------------------------------------------------------------------
// 0. Oracle / Invariant Checker Self-Test
// ---------------------------------------------------------------------------

test("formal invariant checker self-test detects regressions and duplicate outbox keys", () => {
  const clean: PersistedSync = {
    serverId: "srv_a",
    cursor: 5,
    baseUrl: BASE_URL,
    storageFull: false,
    pausedBookIds: [],
    books: [],
    records: [],
    positions: [],
    conflicts: [],
    devices: [],
    inflight: null,
    pending: null,
    lastSyncedAt: null,
    failureStartedAt: null,
  };
  assert.equal(checkPersistedInvariants(clean, { serverId: "srv_a", cursor: 5 }, "clean"), null);

  // Detect cursor regression
  const regressed = { ...clean, cursor: 3 };
  assert.notEqual(checkPersistedInvariants(regressed, { serverId: "srv_a", cursor: 5 }, "regressed"), null);

  // Detect duplicate outbox key
  const dupChange = {
    changeId: "c1",
    bookId: BOOK_A,
    kind: "highlight" as const,
    id: "h_1",
    baseVersion: 0,
    deleted: false,
    clientTime: "2026-11-28T00:00:00.000Z",
    payload: { extras: {} },
    generation: 1,
  };
  const duplicated = { ...clean, pending: { batchId: "b1", changes: [dupChange, { ...dupChange, changeId: "c2" }] } };
  assert.notEqual(checkPersistedInvariants(duplicated, { serverId: "srv_a", cursor: 5 }, "dup"), null);
});

// ---------------------------------------------------------------------------
// 1. wordId / normalizeWord Formal Properties + 30-Case Cross-Platform Fixture
// ---------------------------------------------------------------------------

test("wordId matches all 30 Swift golden fixture cases by exact codepoint arrays", () => {
  const cases = loadWordIdFixture();
  assert.equal(cases.length, 30, "expected exactly 30 upstream Swift word-id normalization fixture cases");

  for (const item of cases) {
    const input = stringFromCodepoints(parseCodepointLabels(item.inputCodepoints));
    const expected = parseCodepointLabels(item.expectedCodepoints);
    const actual = normalizeWord(input);
    assert.deepEqual(codePointsOf(actual), expected, `fixture case '${item.name}' codepoints mismatch`);

    const id = wordId(input);
    if (item.hasWordId) {
      assert.notEqual(id, null, `fixture case '${item.name}' expected non-null wordId`);
      assert.equal(id!.startsWith("w_"), true, `fixture case '${item.name}' wordId missing w_ prefix`);
      assert.deepEqual(codePointsOf(id!.slice(2)), expected, `fixture case '${item.name}' wordId body mismatch`);
    } else {
      assert.equal(id, null, `fixture case '${item.name}' expected null wordId`);
    }
  }
});

test("wordId/normalizeWord satisfies idempotency, Greek sigma/U+FEFF/U+0085 rules, and no NFC folding", () => {
  const seed = readFormalSeed() ^ 0x01n;
  const rng = new SplitMix64(seed);
  const cases = readFormalCases();

  const atoms = [
    "Hello",
    "PROGENY",
    "ΟΔΟΣ",
    "λόγος",
    "\u039B\u038C\u0393\u039F\u03C2",
    "ς",
    "Σ",
    "σ",
    "\u0130STANBUL",
    "Straße",
    "STRA\u1E9EE",
    "caf\u00E9",
    "cafe\u0301",
    "漢字",
    "読書",
    "Don't",
    "Don\u2019t",
    "well-known",
    "\u{1F600}",
    "Family\u{1F468}\u200D\u{1F469}\u200D\u{1F467}",
    " ",
    "\t",
    "\n",
    "\r\n",
    "\u0085",
    "\u00A0",
    "\u2028",
    "\u2029",
    "\u3000",
    "\uFEFF",
    "\u200B",
  ];

  for (let i = 0; i < cases; i += 1) {
    const count = rng.nextInt(0, 6);
    const word = Array.from({ length: count }, () => rng.pick(atoms)).join("");
    const once = normalizeWord(word);
    const twice = normalizeWord(once);
    assert.deepEqual(
      codePointsOf(twice),
      codePointsOf(once),
      `${seedTag(seed, i)} normalizeWord not idempotent for ${JSON.stringify(word)}`,
    );

    const id = wordId(word);
    if (once.length === 0) {
      assert.equal(id, null, `${seedTag(seed, i)} empty normalized word must yield null wordId`);
    } else {
      assert.equal(id, `w_${once}`, `${seedTag(seed, i)} wordId must equal w_ + normalizeWord`);
    }
  }

  // Explicit no NFC folding check
  const nfc = "caf\u00E9";
  const nfd = "cafe\u0301";
  assert.notEqual(normalizeWord(nfc), normalizeWord(nfd), "NFC and NFD must not fold together");
  assert.notEqual(wordId(nfc), wordId(nfd), "wordId(NFC) and wordId(NFD) must stay distinct");
  assert.deepEqual(codePointsOf(normalizeWord("\uFEFFword")), [0xfeff, 0x77, 0x6f, 0x72, 0x64]);
  assert.deepEqual(codePointsOf(normalizeWord("\u0085word\u0085")), [0x77, 0x6f, 0x72, 0x64]);
  assert.deepEqual(codePointsOf(normalizeWord("ΟΔΟΣ")), [0x03bf, 0x03b4, 0x03bf, 0x03c3]);
  assert.deepEqual(codePointsOf(normalizeWord("ς")), [0x03c2]);
});

// ---------------------------------------------------------------------------
// 2. canonical.ts Equivalence Relation Axioms
// ---------------------------------------------------------------------------

test("canonicalJson and payloadsEqual satisfy reflexivity, symmetry, transitivity, and key-order invariance", () => {
  const seed = readFormalSeed() ^ 0x02n;
  const rng = new SplitMix64(seed);
  const cases = readFormalCases();

  for (let i = 0; i < cases; i += 1) {
    const a = randomJsonValue(rng);
    const b = permuteKeysAndInjectUndefined(rng, a);
    const c = permuteKeysAndInjectUndefined(rng, a);
    const other = randomJsonValue(rng);

    // Reflexivity
    assert.equal(payloadsEqual(a, a), true, `${seedTag(seed, i)} reflexivity failed`);
    assert.equal(canonicalJson(a), canonicalJson(sortJson(a)), `${seedTag(seed, i)} sortJson idempotency failed`);

    // Key-order invariance + undefined dropping
    assert.equal(canonicalJson(a), canonicalJson(b), `${seedTag(seed, i)} key-order invariance failed (a vs b)`);
    assert.equal(payloadsEqual(a, b), true, `${seedTag(seed, i)} payloadsEqual(a, b) failed`);

    // Symmetry (both equal and arbitrary pairs)
    assert.equal(payloadsEqual(a, b), payloadsEqual(b, a), `${seedTag(seed, i)} symmetry failed (a, b)`);
    assert.equal(payloadsEqual(a, other), payloadsEqual(other, a), `${seedTag(seed, i)} symmetry failed (a, other)`);

    // Transitivity
    if (payloadsEqual(a, b) && payloadsEqual(b, c)) {
      assert.equal(payloadsEqual(a, c), true, `${seedTag(seed, i)} transitivity failed`);
    }

    // Parse-reencode idempotency
    const encoded = canonicalJson(a);
    assert.equal(canonicalJson(JSON.parse(encoded)), encoded, `${seedTag(seed, i)} JSON parse/canonicalize idempotency failed`);

    // sameRecord equivalence axioms
    const del = rng.nextBool();
    assert.equal(sameRecord({ deleted: del, payload: a }, { deleted: del, payload: b }), true);
    assert.equal(sameRecord({ deleted: del, payload: a }, { deleted: !del, payload: b }), false);
  }

  // Array order sensitivity
  assert.notEqual(canonicalJson([1, 2]), canonicalJson([2, 1]));
  assert.equal(payloadsEqual({ arr: [1, 2], k: "v" }, { k: "v", arr: [2, 1] }), false);
});

// ---------------------------------------------------------------------------
// 3. Mobile SyncEngine Targeted Formal Invariants
// ---------------------------------------------------------------------------

test("mobile SyncEngine: dirty local record is never overwritten by pull", async () => {
  const seed = readFormalSeed() ^ 0x03n;
  const rng = new SplitMix64(seed);
  const env = await createMobileHarness({ pullLimit: 2 });
  try {
    const ids = [0, 1, 2, 3].map((n) => `h_${n.toString(16).padStart(32, "0")}`);
    for (const id of ids) {
      await env.engine.putHighlight(BOOK_A, makeHighlight(id, `base-${id}`));
    }
    await env.engine.flush();
    assertMobileInvariants(env, `${seedTag(seed)} init`);

    const rounds = Math.min(readFormalCases(), 25);
    for (let round = 0; round < rounds; round += 1) {
      const dirtyId = rng.pick(ids);
      const cleanId = ids[(ids.indexOf(dirtyId) + 1) % ids.length]!;

      // Mac advances both records on the server.
      const dirtyHead = env.server.record(BOOK_A, "highlight", dirtyId);
      const cleanHead = env.server.record(BOOK_A, "highlight", cleanId);
      assert.ok(dirtyHead && cleanHead);

      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "highlight",
        id: dirtyId,
        baseVersion: dirtyHead.version,
        deleted: false,
        clientTime: "2026-11-28T00:01:00.000Z",
        payload: { color: 2, quote: `mac-remote-${round}`, prefix: "pre ", suffix: " suf", extras: {} },
      });
      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "highlight",
        id: cleanId,
        baseVersion: cleanHead.version,
        deleted: false,
        clientTime: "2026-11-28T00:01:00.000Z",
        payload: { color: 3, quote: `mac-clean-${round}`, prefix: "pre ", suffix: " suf", extras: {} },
      });

      // Phone edits dirtyId locally without flushing, then pulls.
      const localQuote = `phone-dirty-${round}`;
      await env.engine.putHighlight(BOOK_A, makeHighlight(dirtyId, localQuote, 4));
      await env.engine.pull();
      assertMobileInvariants(env, `${seedTag(seed, round)} after-pull`);

      const records = env.engine.exportState().records;
      const dirtyLocal = records.find((r) => r.id === dirtyId && r.kind === "highlight");
      const cleanLocal = records.find((r) => r.id === cleanId && r.kind === "highlight");

      assert.equal(dirtyLocal?.dirty, true, `${seedTag(seed, round)} pull cleared dirty flag`);
      assert.equal(dirtyLocal?.payload.quote, localQuote, `${seedTag(seed, round)} pull overwrote dirty local record!`);
      assert.equal(cleanLocal?.dirty, false, `${seedTag(seed, round)} clean record should stay clean`);
      assert.equal(cleanLocal?.payload.quote, `mac-clean-${round}`, `${seedTag(seed, round)} clean record should update from pull`);

      // Flush opens conflict without clobbering local dirty record; Mac resolves so next round starts clean.
      await env.engine.flush();
      assert.equal(env.engine.exportState().records.find((r) => r.id === dirtyId)?.payload.quote, localQuote);
      const conflict = env.engine.conflictsFor(BOOK_A, "highlight", dirtyId);
      assert.notEqual(conflict, null, `${seedTag(seed, round)} expected conflict on concurrent edit`);

      // Mac resolves conflict and advances head; phone edits to match & syncs cleanly.
      const resolveResp = await env.server.fetch(`${BASE_URL}/v1/conflicts/${conflict!.conflictId}/resolve`, {
        method: "POST",
        headers: { authorization: `Bearer ${env.macCredential}` },
      });
      assert.equal(resolveResp.status, 200);
      await env.engine.pull();
      // Sync local dirty back cleanly by updating from server head version via a fresh edit or matching remote
      const resolvedHead = env.server.record(BOOK_A, "highlight", dirtyId)!;
      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "highlight",
        id: dirtyId,
        baseVersion: resolvedHead.version,
        deleted: false,
        clientTime: "2026-11-28T00:02:00.000Z",
        payload: { color: 4, quote: localQuote, prefix: "pre ", suffix: " suf", rects: [], extras: { origin: "phone" } },
      });
      await env.engine.putHighlight(BOOK_A, makeHighlight(dirtyId, localQuote, 4));
      await env.engine.flush();
    }
  } finally {
    env.engine.stop();
  }
});

test("mobile SyncEngine: mid-session position pull never mutates sessionResume until next openBook", async () => {
  const seed = readFormalSeed() ^ 0x04n;
  const rng = new SplitMix64(seed);
  const env = await createMobileHarness();
  try {
    await macRegisterBookA(env.server, env.macCredential);
    // Initial remote position on page 12
    await macPushRaw(env.server, env.macCredential, {
      changeId: globalThis.crypto.randomUUID(),
      bookId: BOOK_A,
      kind: "position",
      id: `p_${BOOK_A}_mac-1`,
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-11-28T00:00:01.000Z",
      payload: { bookId: BOOK_A, deviceId: "mac-1", locator: { format: "pdf", page: 12 }, extras: {} },
    });
    await env.engine.pull();
    assert.equal(env.engine.sessionResume(BOOK_A), null, "sessionResume must be null before openBook");

    const initialOffer = await env.engine.openBook(BOOK_A, { page: 1 });
    assert.ok(initialOffer);
    assert.equal(payloadsEqual(initialOffer.locator, { format: "pdf", page: 12 }), true);
    const snapshotOffer = structuredClone(initialOffer);

    // Push randomized mid-session PDF & EPUB position updates and pull after each.
    let lastLocator: Locator = { format: "pdf", page: 12 };
    const updates = Math.min(readFormalCases(), 30);
    for (let i = 0; i < updates; i += 1) {
      const locator: Locator = rng.nextBool()
        ? { format: "pdf", page: 20 + i }
        : { format: "epub", cfi: `epubcfi(/6/${(i + 2) * 2}!/4/2/1:0)`, progression: (i % 10) / 10 };
      lastLocator = locator;
      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "position",
        id: `p_${BOOK_A}_mac-1`,
        baseVersion: 0,
        deleted: false,
        clientTime: `2026-11-28T00:01:${String(i).padStart(2, "0")}.000Z`,
        payload: { bookId: BOOK_A, deviceId: "mac-1", locator, extras: {} } as unknown as JsonObject,
      });
      await env.engine.pull();
      assertMobileInvariants(env, `${seedTag(seed, i)} mid-session-pull`);

      // Mid-session pull MUST NOT mutate sessionResume!
      assert.deepEqual(
        env.engine.sessionResume(BOOK_A),
        snapshotOffer,
        `${seedTag(seed, i)} mid-session pull mutated sessionResume!`,
      );
      // latestPosition in storage DOES track the newest seq.
      assert.deepEqual(env.engine.latestPosition(BOOK_A)?.payload.locator, locator);
    }

    // Only the NEXT openBook adopts the latest pulled position.
    const nextOffer = await env.engine.openBook(BOOK_A, { page: 1 });
    assert.ok(nextOffer);
    assert.equal(payloadsEqual(nextOffer.locator, lastLocator), true);
    assert.deepEqual(env.engine.sessionResume(BOOK_A), nextOffer);
  } finally {
    env.engine.stop();
  }
});

test("mobile SyncEngine: serverId change resets cursor and re-syncs all local records without data loss", async () => {
  const seed = readFormalSeed() ^ 0x05n;
  const rng = new SplitMix64(seed);
  const env = await createMobileHarness({ pullLimit: 2 });
  try {
    const expectedQuotes = new Map<string, string>();
    const count = 8;
    for (let i = 0; i < count; i += 1) {
      const id = `h_${i.toString(16).padStart(32, "0")}`;
      const quote = `survives-reset-${i}-${rng.nextInt(100, 999)}`;
      expectedQuotes.set(id, quote);
      await env.engine.putHighlight(BOOK_A, makeHighlight(id, quote));
    }
    await env.engine.flush();
    assertMobileInvariants(env, `${seedTag(seed)} before-reset`);
    assert.ok(env.engine.exportState().cursor > 0);

    // Swap in a brand-new server with a different serverId (wiped DB, same device credential).
    const freshServer = new MockSyncServer({ serverId: "srv_fresh_b", now: () => "2026-11-28T01:00:00.000Z" });
    freshServer.issueToken("tok_rebind");
    // Re-register the phone's existing credential on the new server so auth succeeds and pull exposes new serverId.
    const existingCred = env.session.credential!;
    const oldFetch = freshServer.fetch.bind(freshServer);
    const pairedCred = freshServer.pairDevice({ deviceId: "phone-1", name: "Arturo's Phone", platform: "ios", kind: "phone" });
    env.server = freshServer;
    env.transport = new HttpTransport({
      fetchImpl: (input, init) => {
        const headers = new Headers(init?.headers);
        if (headers.get("authorization") === `Bearer ${existingCred}`) {
          headers.set("authorization", `Bearer ${pairedCred}`);
        }
        return oldFetch(input, { ...init, headers });
      },
      baseUrl: () => env.session.baseUrl,
      credential: () => env.session.credential,
    });
    // Rebind transport via restart so SyncEngine uses freshServer seamlessly
    const persisted = env.storage.snapshot!;
    env.engine.stop();
    env.engine = new SyncEngine({
      transport: env.transport,
      storage: env.storage,
      credentials: env.credentials,
      clock: env.clock,
      session: env.session,
      pullLimit: 2,
      device: { deviceId: "phone-1", name: "Arturo's Phone", platform: "ios", appVersion: "1.0.0-formal" },
    });
    assert.ok(persisted);
    await env.engine.start();

    assert.equal(env.engine.exportState().serverId, "srv_fresh_b", `${seedTag(seed)} serverId must update to srv_fresh_b`);
    assertMobileInvariants(env, `${seedTag(seed)} after-reset`);

    // Every single local highlight MUST have been re-pushed with baseVersion 0 to the new server (zero data loss)!
    for (const [id, quote] of expectedQuotes.entries()) {
      const remote = freshServer.record(BOOK_A, "highlight", id);
      assert.ok(remote, `${seedTag(seed)} record ${id} lost after serverId reset!`);
      assert.equal(remote.version, 1);
      assert.equal(remote.payload.quote, quote);
      const local = env.engine.exportState().records.find((r) => r.id === id);
      assert.equal(local?.dirty, false);
      assert.equal(local?.serverVersion, 1);
    }
  } finally {
    env.engine.stop();
  }
});

test("mobile SyncEngine: 507 disk_full and quota_exceeded pause book blobs while record sync continues", async () => {
  for (const fullCode of ["disk_full", "quota_exceeded"] as const) {
    const env = await createMobileHarness({ pullLimit: 2 });
    try {
      env.server.diskFull = true;
      env.server.fullCode = fullCode;

      const paused = await env.engine.uploadBook(BOOK_A, BYTES_A);
      assert.equal(paused, "paused", `expected paused under 507 ${fullCode}`);
      assert.equal(env.engine.status().state, "storageFull");
      assert.deepEqual(env.engine.status().pausedBookIds, [BOOK_A]);

      // Records MUST continue pushing and pulling while storageFull is active.
      const hid = `h_${"11".repeat(16)}`;
      await env.engine.putHighlight(BOOK_A, makeHighlight(hid, `quote-under-${fullCode}`));
      await env.engine.putNote(BOOK_A, makeNote(hid, `note-under-${fullCode}`));
      await env.engine.flush();
      assertMobileInvariants(env, `storageFull-${fullCode}-push`);

      assert.equal(env.server.record(BOOK_A, "highlight", hid)?.payload.quote, `quote-under-${fullCode}`);
      assert.equal(env.server.record(BOOK_A, "note", hid)?.payload.body, `note-under-${fullCode}`);
      assert.equal(env.engine.status().state, "storageFull");

      // Remote Mac record MUST also pull cleanly while storageFull is active.
      const macId = `h_${"22".repeat(16)}`;
      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "note",
        id: macId,
        baseVersion: 0,
        deleted: false,
        clientTime: "2026-11-28T00:05:00.000Z",
        payload: { quote: "from mac", prefix: "", suffix: "", ai: false, scope: "passage", body: "mac-ok", extras: {} },
      });
      await env.engine.pull();
      assert.equal(env.engine.exportState().records.find((r) => r.id === macId && r.kind === "note")?.payload.body, "mac-ok");

      // Freeing space + recheckStorage clears storageFull and finishes upload.
      env.server.diskFull = false;
      await env.engine.recheckStorage();
      assert.notEqual(env.engine.status().state, "storageFull");
      assert.deepEqual(env.engine.status().pausedBookIds, []);
    } finally {
      env.engine.stop();
    }
  }
});

test("mobile SyncEngine: recheckStorage clears persisted storageFull after app restart", async () => {
  // Witness for apps/mobile/src/sync/engine.ts:144,297-318:
  // storageFull and pausedBookIds are persisted to storage, while pausedBytes is an in-memory Map.
  // After an app restart, SyncEngine.start() and SyncProvider.recheckStorage() skip every persisted
  // pausedBookId because pausedBytes is empty, leaving the client stuck in storageFull permanently.
  const env = await createMobileHarness({ pullLimit: 2 });
  try {
    env.server.diskFull = true;
    const paused = await env.engine.uploadBook(BOOK_A, BYTES_A);
    assert.equal(paused, "paused");
    assert.equal(env.engine.status().state, "storageFull");

    // Simulate app restart after space is freed on Mac mini (even when the server already has the blob).
    env.server.diskFull = false;
    env.server.putBlob(SHA_A, BYTES_A);
    const restarted = recreateEngineAfterRestart(env);
    await restarted.start();
    await restarted.recheckStorage();

    assert.equal(
      restarted.exportState().storageFull,
      false,
      "Persisted storageFull remained stuck true after app restart + recheckStorage() because pausedBytes is in-memory only",
    );
    assert.deepEqual(restarted.status().pausedBookIds, []);
  } finally {
    env.engine.stop();
  }
});

test("mobile SyncEngine: pending and inflight outbox edits survive simulated app restart without data loss", async () => {
  const seed = readFormalSeed() ^ 0x06n;
  const rng = new SplitMix64(seed);
  const env = await createMobileHarness({ pullLimit: 2 });
  try {
    // Case A: Offline edits saved in pending outbox survive app kill & relaunch.
    env.server.offline = true;
    const offlineIds = [0, 1, 2].map((n) => `h_${(n + 10).toString(16).padStart(32, "0")}`);
    const expectedOffline = new Map<string, string>();
    for (const id of offlineIds) {
      const q1 = `offline-draft-${id}`;
      const q2 = `offline-final-${id}-${rng.nextInt(10, 99)}`;
      await env.engine.putHighlight(BOOK_A, makeHighlight(id, q1));
      await env.engine.putHighlight(BOOK_A, makeHighlight(id, q2));
      expectedOffline.set(id, q2);
    }
    await env.engine.flush();
    assert.equal(env.server.pushes.length, 0);

    // Simulate kill + restart while coming back online.
    env.server.offline = false;
    const restarted1 = recreateEngineAfterRestart(env);
    await restarted1.start();
    assertMobileInvariants(env, `${seedTag(seed)} restart-offline`);

    for (const [id, quote] of expectedOffline.entries()) {
      assert.equal(env.server.record(BOOK_A, "highlight", id)?.payload.quote, quote);
      assert.equal(env.engine.exportState().records.find((r) => r.id === id)?.dirty, false);
    }

    // Case B: Dropped response (server committed, client saved inflight) replays idempotently across restart.
    const dropId = `h_${"dd".repeat(16)}`;
    await env.engine.putHighlight(BOOK_A, makeHighlight(dropId, "dropped-response-body"));
    env.server.loseResponses = 1;
    await env.engine.flush();
    assert.equal(env.server.record(BOOK_A, "highlight", dropId)?.version, 1);
    const savedInflight = env.storage.snapshot?.inflight;
    assert.ok(savedInflight && savedInflight.changes.length === 1, "inflight batch must be persisted across dropped response");
    const firstBatchId = savedInflight.batchId;
    const firstChangeId = savedInflight.changes[0]!.changeId;

    env.server.loseResponses = 0;
    const pushesBeforeRestart = env.server.pushes.length;
    const restarted2 = recreateEngineAfterRestart(env);
    await restarted2.start();
    assertMobileInvariants(env, `${seedTag(seed)} restart-inflight`);

    const replayedPush = env.server.pushes[pushesBeforeRestart];
    assert.equal(replayedPush?.batchId, firstBatchId, "restart must replay same batchId");
    assert.equal(replayedPush?.changes[0]?.changeId, firstChangeId, "restart must replay same changeId");
    assert.equal(env.server.record(BOOK_A, "highlight", dropId)?.version, 1, "idempotent replay must not double-bump version");
    assert.equal(env.engine.exportState().records.find((r) => r.id === dropId)?.dirty, false);
  } finally {
    env.engine.stop();
  }
});

// ---------------------------------------------------------------------------
// 4. Full Randomized Stateful Model-Based Harness for Mobile SyncEngine
// ---------------------------------------------------------------------------

test("mobile SyncEngine: randomized stateful model-based fault-injection schedule preserves all invariants and converges", async () => {
  const baseSeed = readFormalSeed() ^ 0x07n;
  const schedules = Math.min(readFormalCases(), 20);

  for (let s = 0; s < schedules; s += 1) {
    const scheduleSeed = (baseSeed + BigInt(s) * 0x9e37_79b9n) & MASK64;
    const rng = new SplitMix64(scheduleSeed);
    const env = await createMobileHarness({ pullLimit: 2 });
    const trace: string[] = [];

    try {
      await macRegisterBookA(env.server, env.macCredential);
      // Open book early so we can continuously verify mid-session sessionResume stability across pulls.
      await macPushRaw(env.server, env.macCredential, {
        changeId: globalThis.crypto.randomUUID(),
        bookId: BOOK_A,
        kind: "position",
        id: `p_${BOOK_A}_mac-1`,
        baseVersion: 0,
        deleted: false,
        clientTime: "2026-11-28T00:00:01.000Z",
        payload: { bookId: BOOK_A, deviceId: "mac-1", locator: { format: "pdf", page: 5 }, extras: {} },
      });
      await env.engine.pull();
      let pinnedResume = structuredClone(await env.engine.openBook(BOOK_A, { page: 1 }));
      assert.ok(pinnedResume);

      // Partition keys between phone-owned highlights/words and mac-owned notes so quiescent state is conflict-free
      // and must converge strictly to server head across arbitrary faults and restarts.
      const phoneHighlightIds = [0, 1, 2].map((n) => `h_${(n + 100).toString(16).padStart(32, "0")}`);
      const macNoteIds = [0, 1].map((n) => `h_${(n + 200).toString(16).padStart(32, "0")}`);
      const wordTerms = ["Progeny", "ΟΔΟΣ", "caf\u00E9"];
      const steps = 25;

      for (let step = 0; step < steps; step += 1) {
        const action = rng.nextInt(0, 9);
        switch (action) {
          case 0:
          case 1: {
            // Local highlight edit or delete (when record already exists locally) on phone
            const id = rng.pick(phoneHighlightIds);
            const existsLocally = env.engine.exportState().records.some((r) => r.kind === "highlight" && r.id === id);
            if (existsLocally && rng.nextBool(0.25)) {
              await env.engine.deleteRecord(BOOK_A, "highlight", id);
              trace.push(`step ${step}: phone.deleteHighlight(${id})`);
            } else {
              const color = rng.nextInt(1, 6) as 1 | 2 | 3 | 4 | 5 | 6;
              await env.engine.putHighlight(BOOK_A, makeHighlight(id, `q_s${step}`, color));
              trace.push(`step ${step}: phone.putHighlight(${id}, q_s${step})`);
            }
            break;
          }
          case 2: {
            // Local word upsert on phone
            const rawWord = rng.pick(wordTerms);
            const wid = wordId(rawWord)!;
            const wordRec: WordRecord = {
              id: wid,
              word: rawWord,
              definition: `def_${step}`,
              learned: rng.nextBool(),
              lookups: [],
              extras: { step },
            };
            await env.engine.putWord(BOOK_A, wordRec);
            trace.push(`step ${step}: phone.putWord(${wid})`);
            break;
          }
          case 3: {
            // Remote Mac note edit
            const nid = rng.pick(macNoteIds);
            const head = env.server.record(BOOK_A, "note", nid);
            await macPushRaw(env.server, env.macCredential, {
              changeId: globalThis.crypto.randomUUID(),
              bookId: BOOK_A,
              kind: "note",
              id: nid,
              baseVersion: head?.version ?? 0,
              deleted: rng.nextBool(0.15),
              clientTime: `2026-11-28T00:02:${String(step).padStart(2, "0")}.000Z`,
              payload: { quote: "q", prefix: "", suffix: "", ai: false, scope: "passage", body: `mac_s${step}`, extras: {} },
            });
            trace.push(`step ${step}: mac.putNote(${nid}, mac_s${step})`);
            break;
          }
          case 4: {
            // Remote Mac position update (must NOT alter pinnedResume until next openBook)
            const page = 10 + step;
            await macPushRaw(env.server, env.macCredential, {
              changeId: globalThis.crypto.randomUUID(),
              bookId: BOOK_A,
              kind: "position",
              id: `p_${BOOK_A}_mac-1`,
              baseVersion: 0,
              deleted: false,
              clientTime: `2026-11-28T00:03:${String(step).padStart(2, "0")}.000Z`,
              payload: { bookId: BOOK_A, deviceId: "mac-1", locator: { format: "pdf", page }, extras: {} },
            });
            trace.push(`step ${step}: mac.position(page=${page})`);
            break;
          }
          case 5: {
            // Flush with optional offline or dropped-response fault
            const fault = rng.nextInt(0, 3);
            env.server.offline = fault === 0;
            env.server.loseResponses = fault === 1 ? 1 : 0;
            trace.push(`step ${step}: phone.flush(offline=${env.server.offline}, lose=${env.server.loseResponses})`);
            await env.engine.flush();
            env.server.offline = false;
            env.server.loseResponses = 0;
            break;
          }
          case 6: {
            // Pull while verifying dirty local records and sessionResume stay intact
            const dirtyBefore = new Map<string, LocalRecord>();
            for (const rec of env.engine.exportState().records) {
              if (rec.dirty) dirtyBefore.set(`${rec.kind}:${rec.id}`, structuredClone(rec));
            }
            trace.push(`step ${step}: phone.pull()`);
            await env.engine.pull();

            for (const [k, before] of dirtyBefore.entries()) {
              const after = env.engine.exportState().records.find((r) => `${r.kind}:${r.id}` === k);
              assert.ok(after, `${seedTag(scheduleSeed, s)} step ${step}: dirty record ${k} disappeared on pull`);
              assert.equal(after.dirty, true, `${seedTag(scheduleSeed, s)} step ${step}: pull cleared dirty on ${k}`);
              assert.equal(after.deleted, before.deleted);
              assert.equal(payloadsEqual(after.payload, before.payload), true, `${seedTag(scheduleSeed, s)} step ${step}: pull overwrote dirty ${k}`);
            }
            assert.deepEqual(
              env.engine.sessionResume(BOOK_A),
              pinnedResume,
              `${seedTag(scheduleSeed, s)} step ${step}: mid-session pull mutated sessionResume`,
            );
            break;
          }
          case 7: {
            // Toggle diskFull and upload/recheck book blob
            env.server.diskFull = rng.nextBool(0.6);
            if (env.server.diskFull) {
              const res = await env.engine.uploadBook(BOOK_A, BYTES_A);
              assert.equal(res, "paused");
              trace.push(`step ${step}: phone.uploadBook(diskFull=true)->paused`);
            } else {
              await env.engine.recheckStorage();
              trace.push(`step ${step}: phone.recheckStorage(diskFull=false)`);
            }
            break;
          }
          case 8: {
            // Simulated app kill + restart from MemorySyncStorage
            trace.push(`step ${step}: app.restart()`);
            const restarted = recreateEngineAfterRestart(env);
            await restarted.start();
            // After restart, session map is empty until next openBook; re-open book to re-pin.
            pinnedResume = structuredClone(await env.engine.openBook(BOOK_A, { page: 1 }));
            break;
          }
          default: {
            // Re-open book explicitly and verify resume updates to latest pulled position
            pinnedResume = structuredClone(await env.engine.openBook(BOOK_A, { page: 1 }));
            trace.push(`step ${step}: phone.openBook()`);
            break;
          }
        }

        assertMobileInvariants(env, `${seedTag(scheduleSeed, s)} step=${step}`);
      }

      // Quiescence: clear all faults, recheck storage (re-supplying local file bytes if restarted while paused),
      // then flush & pull until settled.
      env.server.offline = false;
      env.server.loseResponses = 0;
      env.server.diskFull = false;
      await env.engine.recheckStorage();
      for (const pausedId of [...env.engine.status().pausedBookIds]) {
        await env.engine.uploadBook(pausedId, BYTES_A);
      }
      await env.engine.flush();
      await env.engine.pull();
      assertMobileInvariants(env, `${seedTag(scheduleSeed, s)} quiescence`);

      const finalState = env.engine.exportState();
      const ctx = `${seedTag(scheduleSeed, s)} quiescence\nTrace:\n${trace.join("\n")}`;
      assert.equal(finalState.inflight, null, `${ctx}\ninflight not null`);
      assert.equal(finalState.pending, null, `${ctx}\npending not null`);
      assert.equal(finalState.conflicts.length, 0, `${ctx}\nunexpected conflicts`);
      assert.equal(finalState.storageFull, false, `${ctx}\nstorageFull did not clear`);
      assert.equal(finalState.cursor, env.server.seq, `${ctx}\ncursor did not catch up to server.seq`);

      // Verify exact convergence on every highlight, note, and word between phone and server.
      for (const local of finalState.records) {
        if (local.kind === "position") continue;
        const remote = env.server.record(local.bookId, local.kind, local.id);
        assert.ok(remote, `${ctx}\nserver missing ${local.kind}:${local.id}`);
        assert.equal(local.dirty, false, `${ctx}\nlocal ${local.kind}:${local.id} still dirty`);
        assert.equal(local.serverVersion, remote.version, `${ctx}\nversion mismatch on ${local.kind}:${local.id}`);
        assert.equal(local.deleted, remote.deleted, `${ctx}\ndeleted mismatch on ${local.kind}:${local.id}`);
        assert.equal(
          payloadsEqual(local.payload, remote.payload),
          true,
          `${ctx}\npayload mismatch on ${local.kind}:${local.id}`,
        );
      }
      for (const nid of macNoteIds) {
        const remote = env.server.record(BOOK_A, "note", nid);
        if (!remote) continue;
        const local = finalState.records.find((r) => r.kind === "note" && r.id === nid);
        assert.ok(local, `${ctx}\nphone missing remote Mac note ${nid}`);
        assert.equal(local.serverVersion, remote.version);
        assert.equal(local.deleted, remote.deleted);
        assert.equal(payloadsEqual(local.payload, remote.payload), true);
      }
    } finally {
      env.engine.stop();
    }
  }
});
