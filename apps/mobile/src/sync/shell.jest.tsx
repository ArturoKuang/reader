import { describe, expect, it, jest } from "@jest/globals";
import { fireEvent, render, screen } from "@testing-library/react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { SyncChrome } from "./SyncStatusChip";
import type { OpenConflict } from "./wire";

const conflict: OpenConflict = {
  conflictId: "c_1",
  bookId: "sha256:" + "ab".repeat(32),
  kind: "note",
  id: "h_1",
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

const pausedBook = "sha256:" + "cd".repeat(32);

describe("sync chrome mounted in the library", () => {
  it("opens the storage sheet without a retry spinner", async () => {
    const onCheckAgain = jest.fn();
    await render(
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 390, height: 844 },
          insets: { top: 0, left: 0, right: 0, bottom: 0 },
        }}
      >
        <SyncChrome
          status={{
            state: "storageFull",
            pendingCount: 1,
            conflictCount: 0,
            pausedBookIds: [pausedBook],
            lastSyncedAt: null,
          }}
          conflicts={[]}
          onCheckAgain={onCheckAgain}
        />
      </SafeAreaProvider>,
    );
    await fireEvent.press(screen.getByLabelText("sync storageFull"));
    expect(screen.getByText("Mac mini is full")).toBeTruthy();
    expect(screen.getByText("Books paused. Highlights and notes still sync.")).toBeTruthy();
    expect(screen.getByText("1 books waiting")).toBeTruthy();
    expect(screen.getByText(`${pausedBook} · Waiting for space`)).toBeTruthy();
    await fireEvent.press(screen.getByLabelText("Check again"));
    expect(onCheckAgain).toHaveBeenCalledTimes(1);
    expect(screen.queryByLabelText("retry spinner")).toBeNull();
    await fireEvent.press(screen.getByLabelText("Dismiss sync sheet"));
    expect(screen.queryByLabelText("sync sheet")).toBeNull();
  });

  it("opens the read-only conflict card from the chip", async () => {
    await render(
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 390, height: 844 },
          insets: { top: 0, left: 0, right: 0, bottom: 0 },
        }}
      >
        <SyncChrome
          status={{
            state: "conflict",
            pendingCount: 0,
            conflictCount: 1,
            pausedBookIds: [],
            lastSyncedAt: null,
          }}
          conflicts={[conflict]}
        />
      </SafeAreaProvider>,
    );
    await fireEvent.press(screen.getByLabelText("sync conflict"));
    expect(screen.getByText("Both versions are kept. Pick one in Reader on your Mac.")).toBeTruthy();
    expect(screen.getByText("Resolve on Mac")).toBeTruthy();
    expect(screen.queryByLabelText("Resolve")).toBeNull();
  });
});
