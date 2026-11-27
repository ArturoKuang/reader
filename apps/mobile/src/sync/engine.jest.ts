import { beforeEach, describe, expect, it } from "@jest/globals";
import type { HighlightRecord, NoteRecord, WordRecord } from "../contract/types";
import { wordId } from "../contract/wordId";
import { downloadBookBlob, sha256Hex } from "./blobs";
import { FakeClock } from "./clock";
import { MemoryCredentialStore } from "./credentials";
import { SyncEngine, epubChapterKey } from "./engine";
import { MockSyncServer } from "./mock/server";
import { EMULATOR_BASE_URL, parsePairingUrl } from "./pairing";
import { MemorySyncStorage } from "./storage";
import { deriveSyncStatus, ERROR_AFTER_MS, POSITION_TOAST_MS, SYNC_STATES } from "./status";
import { HttpTransport } from "./transport";
import type { ChangeInput } from "./wire";

const SHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const BOOK = `sha256:${SHA}`;

const BASE = "http://sync.test/v1/reader";

function qr(base: string, token: string, serverId: string): string {
  return `readersync://pair?v=2&url=${encodeURIComponent(base)}&token=${encodeURIComponent(token)}&server=${encodeURIComponent(serverId)}`;
}

function highlight(id: string, quote: string): HighlightRecord {
  return {
    id,
    color: 1,
    quote,
    prefix: "pre",
    suffix: "suf",
    rects: [],
    extras: { source: "phone" },
  };
}

function harness(pullLimit = 1000) {
  const server = new MockSyncServer({ serverId: "srv_a", now: () => "2026-01-01T00:00:00.000Z" });
  const session = { baseUrl: null as string | null, credential: null as string | null };
  const transport = new HttpTransport({
    fetchImpl: (input, init) => server.fetch(input, init),
    baseUrl: () => session.baseUrl,
    credential: () => session.credential,
  });
  const storage = new MemorySyncStorage();
  const credentials = new MemoryCredentialStore();
  const clock = new FakeClock();
  const engine = new SyncEngine({
    transport,
    storage,
    credentials,
    clock,
    session,
    pullLimit,
    device: { deviceId: "phone-1", name: "your phone", platform: "ios", appVersion: "0.0.0" },
  });
  return { server, transport, storage, credentials, clock, engine, session };
}

async function pair(env: ReturnType<typeof harness>, base = BASE): Promise<void> {
  env.server.issueToken("tok");
  await env.engine.pair(qr(base, "tok", env.server.serverId));
}

async function track(env: ReturnType<typeof harness>): Promise<void> {
  await env.engine.trackBook({
    sha256: SHA,
    size: 3,
    format: "pdf",
    title: "Book A",
    filename: "a.pdf",
    docId: "doc-a",
  });
}

const HID = `h_${"ab".repeat(16)}`;

async function pushRaw(
  server: MockSyncServer,
  credential: string,
  change: ChangeInput,
): Promise<{ results: { status: string; error?: { code: string } }[] }> {
  const response = await server.fetch("http://sync.test/v1/changes", {
    method: "POST",
    headers: { authorization: `Bearer ${credential}`, "content-type": "application/json" },
    body: JSON.stringify({ batchId: crypto.randomUUID(), changes: [change] }),
  });
  return (await response.json()) as { results: { status: string; error?: { code: string } }[] };
}

describe("sync engine", () => {
  let env: ReturnType<typeof harness>;

  beforeEach(async () => {
    env = harness();
    await pair(env);
    await track(env);
  });

  it("uses the documented port only as an example and dials the QR host and port", async () => {
    expect(env.engine.origin()).toBe(BASE);
    expect(env.server.seenRequests.some((request) => request.path.startsWith("/v1/reader/v1/"))).toBe(true);
    const other = harness();
    await pair(other, EMULATOR_BASE_URL);
    expect(other.engine.origin()).toBe(EMULATOR_BASE_URL);
    expect(other.server.seenRequests[0]?.host).toBe("10.0.2.2:8789");
    expect(() => parsePairingUrl("readersync://pair?v=1&host=10.0.0.1&port=8788&token=t&server=s")).toThrow(
      /v=1/,
    );
  });

  it("creates, fast-forwards, and noops", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "one"));
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(1);
    expect(env.server.pushes[0]?.changes[0]?.baseVersion).toBe(0);

    await env.engine.putHighlight(BOOK, highlight(HID, "two"));
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(2);
    expect(env.server.pushes.at(-1)?.changes[0]?.baseVersion).toBe(1);

    await env.engine.putHighlight(BOOK, highlight(HID, "two"));
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(2);
    expect(env.engine.exportState().records.find((record) => record.id === HID)?.dirty).toBe(false);
  });

  it("keeps a dirty local edit when both sides changed", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "local-1"));
    await env.engine.flush();
    const mac = env.server.pairDevice({ deviceId: "mac-1", name: "your Mac", platform: "mac", kind: "mac" });
    const theirs = await pushRaw(env.server, mac, {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "highlight",
      id: HID,
      baseVersion: 1,
      deleted: false,
      clientTime: "2026-01-01T00:00:01.000Z",
      payload: { color: 2, quote: "theirs", prefix: "pre", suffix: "suf", extras: {} },
    });
    expect(theirs.results[0]?.status).toBe("applied");

    await env.engine.putHighlight(BOOK, highlight(HID, "local-2"));
    await env.engine.pull();
    expect(env.engine.exportState().records.find((record) => record.id === HID)?.payload.quote).toBe("local-2");

    await env.engine.flush();
    const local = env.engine.exportState().records.find((record) => record.id === HID);
    expect(local?.payload.quote).toBe("local-2");
    expect(local?.dirty).toBe(true);
    expect(env.engine.conflictsFor(BOOK, "highlight", HID)).not.toBeNull();
    expect(env.engine.status().state).toBe("conflict");
    expect(env.engine.status().conflictCount).toBe(1);
    expect(env.server.record(BOOK, "highlight", HID)?.payload.quote).toBe("theirs");
  });

  it("coalesces offline edits into one change and flushes that body", async () => {
    env.server.offline = true;
    await env.engine.putHighlight(BOOK, highlight(HID, "a"));
    await env.engine.putHighlight(BOOK, highlight(HID, "b"));
    await env.engine.putHighlight(BOOK, highlight(HID, "c"));
    expect(env.engine.status().pendingCount).toBe(1);
    await env.engine.flush();
    expect(env.server.pushes).toHaveLength(0);
    expect(env.engine.status().state).toBe("offline");

    env.server.offline = false;
    await env.engine.flush();
    expect(env.server.pushes).toHaveLength(1);
    expect(env.server.pushes[0]?.changes).toHaveLength(1);
    expect(env.server.record(BOOK, "highlight", HID)?.payload.quote).toBe("c");
  });

  it("replays a lost response with the same ids", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "once"));
    await env.engine.flush();
    await env.engine.putHighlight(BOOK, highlight(HID, "twice"));
    env.server.loseResponses = 1;
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(2);
    const lost = env.server.pushes[1];

    env.server.loseResponses = 0;
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(2);
    expect(env.server.pushes[2]?.changes[0]?.changeId).toBe(lost?.changes[0]?.changeId);
    expect(env.server.pushes[2]?.batchId).toBe(lost?.batchId);
    expect(env.server.appliedChanges.filter((change) => change.id === HID)).toHaveLength(2);
  });

  it("resumes an outbox that was saved and never sent", async () => {
    let killed = true;
    const transport = new HttpTransport({
      fetchImpl: (input, init) => {
        const url = String(input);
        if (killed && url.includes("/v1/changes") && init?.method === "POST") {
          throw new TypeError("killed before send");
        }
        return env.server.fetch(input, init);
      },
      baseUrl: () => env.session.baseUrl,
      credential: () => env.session.credential,
    });
    const engine = new SyncEngine({
      transport,
      storage: env.storage,
      credentials: env.credentials,
      clock: env.clock,
      session: env.session,
      device: { deviceId: "phone-1", name: "your phone", platform: "ios", appVersion: "0.0.0" },
    });
    await engine.start();
    await engine.putHighlight(BOOK, highlight(HID, "saved"));
    await engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)).toBeUndefined();
    expect(env.storage.snapshot?.inflight?.changes[0]?.payload.quote).toBe("saved");

    killed = false;
    const restarted = new SyncEngine({
      transport,
      storage: env.storage,
      credentials: env.credentials,
      clock: env.clock,
      session: env.session,
      device: { deviceId: "phone-1", name: "your phone", platform: "ios", appVersion: "0.0.0" },
    });
    await restarted.start();
    expect(env.server.record(BOOK, "highlight", HID)?.version).toBe(1);
    expect(env.server.record(BOOK, "highlight", HID)?.payload.quote).toBe("saved");
  });

  it("applies the same pull page twice without changing local records", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "page"));
    await env.engine.flush();
    const page = await env.transport.pull(0, 100);
    const before = env.engine.exportState().records;
    env.engine.applyPulledPage(page);
    env.engine.applyPulledPage(page);
    expect(env.engine.exportState().records).toEqual(before);
  });

  it("re-pushes with baseVersion 0 after the server id changes", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "kept"));
    await env.engine.flush();
    const marker = env.server.pushes.length;
    env.server.serverId = "srv_b";
    await env.engine.pull();
    const again = env.server.pushes.slice(marker);
    expect(again.some((batch) => batch.changes.some((change) => change.id === HID && change.baseVersion === 0))).toBe(true);
    expect(env.engine.exportState().serverId).toBe("srv_b");
    expect(env.engine.exportState().cursor).toBeGreaterThanOrEqual(0);
  });

  it("registers a forgotten book and retries the record", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "first"));
    await env.engine.flush();
    env.server.forgetBook(BOOK);
    const next = `h_${"cd".repeat(16)}`;
    await env.engine.putHighlight(BOOK, highlight(next, "second"));
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", next)?.payload.quote).toBe("second");
    expect(env.server.seenRequests.filter((request) => request.path.includes("/v1/books/register")).length).toBeGreaterThan(1);
  });

  it("pages until hasMore is false", async () => {
    const paged = harness(2);
    await pair(paged);
    await paged.engine.trackBook({ sha256: SHA, size: 3, format: "pdf", title: "Book A", filename: "a.pdf" });
    for (let index = 0; index < 5; index += 1) {
      await paged.engine.putHighlight(BOOK, highlight(`h_${index.toString(16).padStart(32, "0")}`, `q${index}`));
    }
    await paged.engine.flush();
    const pulls = paged.server.seenRequests.filter((request) => request.path.includes("/v1/changes?"));
    expect(pulls.length).toBeGreaterThan(1);
    expect(pulls.some((request) => request.path.includes("limit=2"))).toBe(true);
    const highlights = paged.engine.exportState().records.filter((record) => record.kind === "highlight");
    expect(highlights).toHaveLength(5);
  });

  it("deletes a highlight and its note in one batch", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "quoted"));
    const noteRecord: NoteRecord = {
      id: HID,
      quote: "quoted",
      prefix: "pre",
      suffix: "suf",
      ai: false,
      scope: "passage",
      body: "hello",
      extras: {},
    };
    await env.engine.putNote(BOOK, noteRecord);
    await env.engine.flush();
    expect(env.server.record(BOOK, "highlight", HID)?.payload.noteId).toBeUndefined();
    expect(env.server.record(BOOK, "note", HID)?.payload.body).toBe("hello");
    const rejected = await pushRaw(env.server, env.session.credential ?? "", {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "highlight",
      id: HID,
      baseVersion: 1,
      deleted: false,
      clientTime: "2026-01-01T00:00:00.000Z",
      payload: { color: 1, quote: "quoted", prefix: "pre", suffix: "suf", noteId: HID, extras: {} },
    });
    expect(rejected.results[0]?.status).toBe("rejected");
    expect(rejected.results[0]?.error?.code).toBe("bad_request");
    const before = env.server.pushes.length;
    await env.engine.deleteHighlight(BOOK, HID);
    await env.engine.flush();
    const batch = env.server.pushes[before];
    expect(batch?.changes).toHaveLength(2);
    expect(batch?.changes.map((change) => change.id)).toEqual([HID, HID]);
    expect(batch?.changes.map((change) => change.kind)).toEqual(["note", "highlight"]);
    expect(batch?.changes.map((change) => change.deleted)).toEqual([true, true]);
  });

  it("rejects a position the device does not own, and debounces its own", async () => {
    await env.transport.registerBook({ sha256: SHA, size: 3, format: "pdf", title: "Book A", filename: "a.pdf", docId: "doc-a" });
    const foreign = await pushRaw(env.server, env.session.credential ?? "", {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "position",
      id: `p_${BOOK}_someone-else`,
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-01-01T00:00:00.000Z",
      payload: {
        bookId: BOOK,
        deviceId: "someone-else",
        locator: { format: "pdf", page: 3 },
        extras: {},
      },
    });
    expect(foreign.results[0]?.status).toBe("rejected");
    expect(foreign.results[0]?.error?.code).toBe("not_owner");

    env.engine.updatePosition(BOOK, { format: "pdf", page: 4, point: { x: 1, y: 2 } });
    await env.clock.advance(1_999);
    expect(env.server.record(BOOK, "position", `p_${BOOK}_phone-1`)).toBeUndefined();
    await env.clock.advance(1);
    const stored = env.server.record(BOOK, "position", `p_${BOOK}_phone-1`);
    expect(stored?.payload.locator).toEqual({ format: "pdf", page: 4, point: { x: 1, y: 2 } });
  });

  it("flushes a position when the app backgrounds", async () => {
    env.engine.updatePosition(BOOK, { format: "epub", cfi: "epubcfi(/6/4!/4/2/1:0)", progression: 0.25 });
    await env.engine.onBackground();
    const stored = env.server.record(BOOK, "position", `p_${BOOK}_phone-1`);
    expect(stored?.payload.locator).toEqual({
      format: "epub",
      cfi: "epubcfi(/6/4!/4/2/1:0)",
      progression: 0.25,
    });
  });

  it("applies the highest-seq position only when the book is opened", async () => {
    env.engine.updatePosition(BOOK, { format: "pdf", page: 2 });
    await env.engine.onBackground();
    const mac = env.server.pairDevice({ deviceId: "mac-1", name: "your Mac", platform: "mac", kind: "mac" });
    const remote = await pushRaw(env.server, mac, {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "position",
      id: `p_${BOOK}_mac-1`,
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-01-01T00:00:02.000Z",
      payload: {
        bookId: BOOK,
        deviceId: "mac-1",
        locator: { format: "pdf", page: 40 },
        extras: {},
      },
    });
    expect(remote.results[0]?.status).toBe("applied");

    await env.engine.pull();
    expect(env.engine.sessionResume(BOOK)).toBeNull();
    const opened = await env.engine.openBook(BOOK, { page: 10 });
    expect(opened?.locator).toEqual({ format: "pdf", page: 40 });
    expect(opened?.deviceName).toBe("your Mac");
    expect(opened?.toast).toBe("Opened where you left off on your Mac · Back to p. 40");
    expect(opened?.toastDurationMs).toBe(POSITION_TOAST_MS);
    expect((await env.engine.openBook(BOOK, { page: 40 }))?.toast).toBeNull();
    expect((await env.engine.openBook(BOOK, { page: 41 }))?.toast).toBeNull();
    expect(env.server.seenRequests.some((request) => request.path.includes("/v1/devices"))).toBe(true);

    const later = await pushRaw(env.server, mac, {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "position",
      id: `p_${BOOK}_mac-1`,
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-01-01T00:00:03.000Z",
      payload: {
        bookId: BOOK,
        deviceId: "mac-1",
        locator: { format: "pdf", page: 80 },
        extras: {},
      },
    });
    expect(later.results[0]?.status).toBe("applied");
    await env.engine.pull();
    expect(env.engine.sessionResume(BOOK)?.locator).toEqual({ format: "pdf", page: 40 });
  });

  it("suppresses an EPUB toast in the same chapter and keeps the full locator", async () => {
    await env.transport.registerBook({ sha256: SHA, size: 3, format: "pdf", title: "Book A", filename: "a.pdf", docId: "doc-a" });
    const mac = env.server.pairDevice({ deviceId: "mac-1", name: "your Mac", platform: "mac", kind: "mac" });
    const cfi = "epubcfi(/6/4!/4/2/1:0)";
    await pushRaw(env.server, mac, {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "position",
      id: `p_${BOOK}_mac-1`,
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-01-01T00:00:02.000Z",
      payload: {
        bookId: BOOK,
        deviceId: "mac-1",
        locator: { format: "epub", cfi, progression: 0.5 },
        extras: {},
      },
    });
    await env.engine.pull();
    const chapter = epubChapterKey(cfi);
    expect((await env.engine.openBook(BOOK, { chapterKey: chapter }))?.toast).toBeNull();
    const other = await env.engine.openBook(BOOK, { chapterKey: "/6/8" });
    expect(other?.toast).toContain("your Mac");
    expect(other?.locator).toEqual({ format: "epub", cfi, progression: 0.5 });
  });

  it("shows offline until retries have failed for 30s, then error", async () => {
    env.server.offline = true;
    await env.engine.pull();
    expect(env.engine.status().state).toBe("offline");
    await env.clock.advance(ERROR_AFTER_MS - 1);
    expect(env.engine.status().state).toBe("offline");
    await env.clock.advance(1);
    expect(env.engine.status().state).toBe("error");

    env.server.offline = false;
    await env.engine.pull();
    expect(env.engine.status().state).not.toBe("error");
    env.server.offline = true;
    await env.engine.pull();
    await env.clock.advance(20_000);
    expect(env.engine.status().state).toBe("offline");
  });

  it("pulls on foreground and again after 30s", async () => {
    const before = env.server.seenRequests.filter((request) => request.path.includes("/v1/changes?")).length;
    await env.engine.onForeground();
    await env.clock.advance(30_000);
    const pulls = env.server.seenRequests.filter((request) => request.path.includes("/v1/changes?")).length;
    expect(pulls - before).toBeGreaterThanOrEqual(2);
  });

  it("rejects a word id that is not normalizeWord", async () => {
    const id = wordId("  Progeny ");
    if (!id) throw new Error("expected a word id");
    const word: WordRecord = {
      id,
      word: "  Progeny ",
      definition: "offspring",
      learned: false,
      lookups: [],
      extras: { keep: true },
    };
    await env.engine.putWord(BOOK, word);
    await env.engine.flush();
    expect(env.server.record(BOOK, "word", "w_progeny")?.payload.word).toBe("  Progeny ");
    expect(env.server.record(BOOK, "word", "w_progeny")?.payload.lookups).toBeUndefined();

    const rejected = await pushRaw(env.server, env.session.credential ?? "", {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "word",
      id: "w_Progeny",
      baseVersion: 0,
      deleted: false,
      clientTime: "2026-01-01T00:00:00.000Z",
      payload: { word: "Progeny", definition: "x", learned: false, extras: {} },
    });
    expect(rejected.results[0]?.error?.code).toBe("bad_request");
  });

  it("forbids the phone from resolving a conflict", async () => {
    await env.engine.putHighlight(BOOK, highlight(HID, "local-1"));
    await env.engine.flush();
    const mac = env.server.pairDevice({ deviceId: "mac-1", name: "your Mac", platform: "mac", kind: "mac" });
    await pushRaw(env.server, mac, {
      changeId: crypto.randomUUID(),
      bookId: BOOK,
      kind: "highlight",
      id: HID,
      baseVersion: 1,
      deleted: false,
      clientTime: "2026-01-01T00:00:01.000Z",
      payload: { color: 2, quote: "theirs", prefix: "pre", suffix: "suf", extras: {} },
    });
    await env.engine.putHighlight(BOOK, highlight(HID, "local-2"));
    await env.engine.flush();
    const conflict = env.engine.conflictsFor(BOOK, "highlight", HID);
    expect(conflict).not.toBeNull();
    const response = await env.server.fetch(`http://sync.test/v1/conflicts/${conflict?.conflictId}/resolve`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.session.credential}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(response.status).toBe(403);
  });
});

describe("status model", () => {
  it("is a derived value with five chip states", () => {
    expect(SYNC_STATES).toEqual(["synced", "syncing", "offline", "conflict", "error", "storageFull"]);
    const base = {
      pendingCount: 0,
      conflictCount: 0,
      lastSyncedAt: null,
      inFlight: false,
      failureStartedAt: null,
      storageFull: false,
      pausedBookIds: [] as string[],
      now: 0,
    };
    expect(deriveSyncStatus(base).state).toBe("synced");
    expect(deriveSyncStatus({ ...base, inFlight: true }).state).toBe("syncing");
    expect(deriveSyncStatus({ ...base, pendingCount: 2 }).state).toBe("syncing");
    expect(deriveSyncStatus({ ...base, conflictCount: 1, lastSyncedAt: "2026-01-01T00:00:00.000Z" })).toEqual({
      state: "conflict",
      pendingCount: 0,
      conflictCount: 1,
      pausedBookIds: [],
      lastSyncedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(deriveSyncStatus({ ...base, storageFull: true, conflictCount: 2, pendingCount: 4 }).state).toBe("storageFull");
    expect(
      deriveSyncStatus({ ...base, storageFull: true, failureStartedAt: 0, now: ERROR_AFTER_MS }).state,
    ).toBe("error");
    expect(deriveSyncStatus({ ...base, failureStartedAt: 0, now: ERROR_AFTER_MS - 1 }).state).toBe("offline");
    expect(deriveSyncStatus({ ...base, failureStartedAt: 0, now: ERROR_AFTER_MS, pendingCount: 3, conflictCount: 2 })).toMatchObject({
      state: "error",
      pendingCount: 3,
      conflictCount: 2,
    });
  });
});

describe("blobs", () => {
  it("verifies the sha and falls back to the newest file that has a blob", async () => {
    const server = new MockSyncServer({ serverId: "srv_a" });
    const bytes = new TextEncoder().encode("abc");
    const sha = await sha256Hex(bytes);
    expect(sha).toBe(SHA);
    server.putBlob(sha, bytes);
    const credential = server.pairDevice({ deviceId: "phone-1", name: "your phone", platform: "ios", kind: "phone" });
    const transport = new HttpTransport({
      fetchImpl: (input, init) => server.fetch(input, init),
      baseUrl: () => BASE,
      credential: () => credential,
    });
    await transport.registerBook({ sha256: sha, size: bytes.length, format: "pdf", title: "A", filename: "a.pdf", docId: "doc" });
    const newer = await sha256Hex(new TextEncoder().encode("abcd"));
    await transport.registerBook({ sha256: newer, size: 4, format: "pdf", title: "A", filename: "a.pdf", docId: "doc" });
    const listed = await transport.books();
    const book = listed.books[0];
    if (!book) throw new Error("missing book");
    expect(book.hasBlob).toBe(false);
    const downloaded = await downloadBookBlob(transport, book);
    expect(new TextDecoder().decode(downloaded)).toBe("abc");

    server.putBlob(sha, new TextEncoder().encode("nope"));
    await expect(downloadBookBlob(transport, book)).rejects.toMatchObject({ code: "hash_mismatch" });
  });
});
