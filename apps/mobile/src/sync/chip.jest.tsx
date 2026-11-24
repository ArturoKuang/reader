import { describe, expect, it } from "@jest/globals";
import { render, screen } from "@testing-library/react-native";
import { ConflictCard } from "./ConflictCard";
import { SyncStatusChip } from "./SyncStatusChip";
import type { OpenConflict } from "./wire";

describe("sync status chip", () => {
  it("shows the derived state, pending count, conflicts, and last sync time", async () => {
    await render(
      <SyncStatusChip
        status={{ state: "offline", pendingCount: 3, conflictCount: 1, lastSyncedAt: "2026-01-01T00:00:00.000Z" }}
      />,
    );
    expect(screen.getByLabelText("sync offline")).toBeTruthy();
    expect(screen.getByText("3 pending")).toBeTruthy();
    expect(screen.getByText("1 conflicts")).toBeTruthy();
    expect(screen.getByText("2026-01-01T00:00:00.000Z")).toBeTruthy();
  });
});

describe("conflict card", () => {
  it("is read-only and tells the reader to resolve on the Mac", async () => {
    const conflict: OpenConflict = {
      conflictId: "c_1",
      bookId: "sha256:" + "ab".repeat(32),
      kind: "note",
      id: "n_1",
      baseVersion: 1,
      base: null,
      openedSeq: 4,
      sides: [
        {
          changeId: "left",
          deviceId: "phone",
          version: null,
          deleted: false,
          payload: { extras: {} },
          clientTime: "2026-01-01T00:00:00.000Z",
        },
        {
          changeId: "right",
          deviceId: "mac",
          version: 2,
          deleted: false,
          payload: { extras: {} },
          clientTime: "2026-01-01T00:00:01.000Z",
        },
      ],
    };
    await render(<ConflictCard conflict={conflict} />);
    expect(screen.getByText("Both versions are kept. Pick one in Reader on your Mac.")).toBeTruthy();
    expect(screen.getByText("This note changed on 2 devices")).toBeTruthy();
    expect(screen.queryByText(/resolve/i)).toBeNull();
  });
});
