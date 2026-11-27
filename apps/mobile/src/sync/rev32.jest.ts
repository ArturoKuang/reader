import { describe, expect, it } from "@jest/globals";
import { joinBase, parsePairingUrl, PRODUCTION_BASE_URL } from "./pairing";
import { MockSyncServer } from "./mock/server";
import { HttpTransport } from "./transport";
import { MemoryCredentialStore } from "./credentials";
import { MemorySyncStorage } from "./storage";
import { FakeClock } from "./clock";
import { SyncEngine } from "./engine";
import type { HighlightRecord } from "../contract/types";

const BASE = "http://sync.test/v1/reader/";
const SHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const BOOK = `sha256:${SHA}`;

describe("rev 3.2 pairing and paths", () => {
  it("parses a v2 QR and rejects v1", () => {
    const parsed = parsePairingUrl(
      `readersync://pair?v=2&url=${encodeURIComponent(PRODUCTION_BASE_URL + "/")}&token=tok&server=srv_a`,
    );
    expect(parsed).toEqual({ v: "2", url: PRODUCTION_BASE_URL, token: "tok", serverId: "srv_a" });
    expect(joinBase(parsed.url, "/v1/changes")).toBe(`${PRODUCTION_BASE_URL}/v1/changes`);
    expect(joinBase("http://10.0.2.2:8789/v1/reader/", "/v1/health")).toBe(
      "http://10.0.2.2:8789/v1/reader/v1/health",
    );
    expect(() => parsePairingUrl("readersync://pair?v=1&url=http://10.0.2.2:8789/v1/reader&token=t&server=s")).toThrow(
      /v=1/,
    );
    expect(() => parsePairingUrl("readersync://pair?token=t&server=s")).toThrow(/missing or unsupported/);
    expect(() => parsePairingUrl("readersync://pair?v=2&token=t&server=s")).toThrow(/missing url/);
    expect(() => parsePairingUrl("readersync://pair?v=2&url=ftp://files.example/v1/reader&token=t&server=s")).toThrow(
      /http or https/,
    );
  });
});

describe("disk full pauses book uploads only", () => {
  it("keeps record pushes running and clears storageFull after a successful recheck", async () => {
    const server = new MockSyncServer({ serverId: "srv_a" });
    server.diskFull = true;
    const session = { baseUrl: null as string | null, credential: null as string | null };
    const transport = new HttpTransport({
      fetchImpl: (input, init) => server.fetch(input, init),
      baseUrl: () => session.baseUrl,
      credential: () => session.credential,
    });
    const engine = new SyncEngine({
      transport,
      storage: new MemorySyncStorage(),
      credentials: new MemoryCredentialStore(),
      clock: new FakeClock(),
      session,
      device: { deviceId: "phone-1", name: "your phone", platform: "ios", appVersion: "0.0.0" },
    });
    server.issueToken("tok");
    await engine.pair(
      `readersync://pair?v=2&url=${encodeURIComponent(BASE)}&token=tok&server=${encodeURIComponent(server.serverId)}`,
    );
    await engine.trackBook({ sha256: SHA, size: 3, format: "pdf", title: "Book A", filename: "a.pdf" });
    const highlight: HighlightRecord = {
      id: `h_${"ab".repeat(16)}`,
      color: 1,
      quote: "still syncs",
      prefix: "",
      suffix: "",
      rects: [],
      extras: {},
    };
    await engine.putHighlight(BOOK, highlight);
    await engine.flush();
    expect(server.record(BOOK, "highlight", highlight.id)?.payload.quote).toBe("still syncs");
    expect(engine.status().state).not.toBe("storageFull");

    const paused = await engine.uploadBook(BOOK, new TextEncoder().encode("abc"));
    expect(paused).toBe("paused");
    expect(engine.status().state).toBe("storageFull");
    expect(engine.status().pausedBookIds).toEqual([BOOK]);

    await engine.putHighlight(BOOK, { ...highlight, quote: "after pause" });
    await engine.flush();
    expect(server.record(BOOK, "highlight", highlight.id)?.payload.quote).toBe("after pause");
    expect(engine.status().state).toBe("storageFull");

    server.diskFull = false;
    await engine.recheckStorage();
    expect(engine.status().state).not.toBe("storageFull");
    expect(engine.status().pausedBookIds).toEqual([]);
    expect(server.seenRequests.some((request) => request.method === "PUT" && request.path.includes(`/v1/blobs/${SHA}`))).toBe(
      true,
    );
  });
});
