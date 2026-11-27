import { describe, expect, test } from "@jest/globals";
import { presentStatus, unpairedStatus } from "./controller";
import { mergeSyncRecords } from "./mergeShelf";
import { highlightFromPayload, highlightToPayload, noteFromPayload, noteToPayload } from "./payload";
import { parsePairingUrl } from "./pairing";
import type { HighlightRecord, NoteRecord } from "../contract/types";
import { MemoryCredentialStore } from "./credentials";
import { FakeClock } from "./clock";
import { SyncEngine } from "./engine";
import { MemorySyncStorage } from "./storage";
import { HttpTransport } from "./transport";

const highlight: HighlightRecord = {
  id: "h_abc",
  color: 2,
  quote: "Ishmael",
  prefix: "Call me ",
  suffix: ".",
  cfi: "epubcfi(/6/2!/4,/1:0,/1:7)",
  section: "Chapter 1",
  rects: [],
  extras: {},
};

const note: NoteRecord = {
  id: "h_abc",
  quote: "Ishmael",
  prefix: "Call me ",
  suffix: ".",
  cfi: "epubcfi(/6/2!/4,/1:0,/1:7)",
  section: "Chapter 1",
  ai: false,
  scope: "passage",
  body: "The opening.",
  extras: {},
};

describe("presentStatus", () => {
  test("an unpaired engine is Not paired, never Synced", () => {
    const session = { baseUrl: null as string | null, credential: null as string | null };
    const engine = new SyncEngine({
      transport: new HttpTransport({ baseUrl: () => session.baseUrl, credential: () => session.credential }),
      storage: new MemorySyncStorage(),
      credentials: new MemoryCredentialStore(),
      clock: new FakeClock(),
      device: { deviceId: "dev_test", name: "test", platform: "android", appVersion: "1.0.0" },
      session,
    });
    const status = presentStatus(engine);
    expect(status.state).toBe("unpaired");
    expect(status).toMatchObject({ pendingCount: 0, conflictCount: 0 });
    expect(unpairedStatus.state).toBe("unpaired");
  });
});

describe("pairing URL", () => {
  test("v=1 is rejected with a clear message", () => {
    expect(() => parsePairingUrl("readersync://pair?v=1&url=http://10.0.2.2:8789/v1/reader&token=t&server=s")).toThrow(
      /v=1 is no longer supported/,
    );
  });
});

describe("payload round trip", () => {
  test("highlight and note survive payload conversion", () => {
    const h = highlightFromPayload(highlight.id, highlightToPayload(highlight));
    const n = noteFromPayload(note.id, noteToPayload(note));
    expect(h).toEqual(highlight);
    expect(n).toEqual(note);
  });
});

describe("mergeSyncRecords", () => {
  test("adds pulled records and honors deletes", () => {
    const merged = mergeSyncRecords(
      { lastColor: 1, highlights: [], notes: [] },
      [
        {
          bookId: "sha256:ab",
          kind: "highlight",
          id: highlight.id,
          serverVersion: 1,
          deleted: false,
          payload: highlightToPayload(highlight),
          dirty: false,
          generation: 0,
          heldGeneration: null,
        },
        {
          bookId: "sha256:ab",
          kind: "note",
          id: note.id,
          serverVersion: 1,
          deleted: false,
          payload: noteToPayload(note),
          dirty: false,
          generation: 0,
          heldGeneration: null,
        },
      ],
    );
    expect(merged.highlights).toHaveLength(1);
    expect(merged.notes).toHaveLength(1);
    expect(merged.highlights[0]?.id).toBe("h_abc");
    expect(merged.notes[0]?.body).toBe("The opening.");

    const afterDelete = mergeSyncRecords(merged, [
      {
        bookId: "sha256:ab",
        kind: "highlight",
        id: highlight.id,
        serverVersion: 2,
        deleted: true,
        payload: highlightToPayload(highlight),
        dirty: false,
        generation: 0,
        heldGeneration: null,
      },
    ]);
    expect(afterDelete.highlights).toHaveLength(0);
    expect(afterDelete.notes).toHaveLength(1);
  });
});
