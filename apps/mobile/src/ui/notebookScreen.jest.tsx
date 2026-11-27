import { describe, expect, it, jest } from "@jest/globals";
import { fireEvent, render, screen, waitFor } from "@testing-library/react-native";
import type { ReactElement } from "react";
import { SafeAreaProvider } from "react-native-safe-area-context";
import type { LibraryBook } from "../library/catalog";
import { NotebookScreen } from "./NotebookScreen";

jest.mock("@react-native-async-storage/async-storage", () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () =>
      JSON.stringify({
        lastColor: 1,
        highlights: [
          {
            id: "h1",
            color: 1,
            quote: "Call me Ishmael.",
            prefix: "",
            suffix: "",
            page: 12,
            rects: [],
            extras: {},
          },
        ],
        notes: [
          {
            id: "h1",
            quote: "Call me Ishmael.",
            prefix: "",
            suffix: "",
            page: 12,
            ai: false,
            scope: "passage",
            body: "The narrator.",
            extras: {},
          },
        ],
      }),
    ),
    setItem: jest.fn(async () => undefined),
  },
}));

jest.mock("../sync/SyncProvider", () => ({
  useSync: () => null,
}));

const book: LibraryBook = {
  id: "fp",
  title: "Book A",
  format: "pdf",
  fingerprint: "fp",
  sha256: "aa",
  size: 1,
  filename: "a.pdf",
  source: "sample",
  cached: true,
  waitingForSpace: false,
  highlightCount: 1,
  noteCount: 1,
  progress: null,
  lastReadAt: 0,
};

function wrap(node: ReactElement) {
  return (
    <SafeAreaProvider
      initialMetrics={{
        frame: { x: 0, y: 0, width: 390, height: 844 },
        insets: { top: 47, left: 0, right: 0, bottom: 34 },
      }}
    >
      {node}
    </SafeAreaProvider>
  );
}

describe("notebook rows", () => {
  it("renders the note body without a Note: prefix", async () => {
    await render(wrap(<NotebookScreen book={book} onBack={() => undefined} onJump={() => undefined} />));
    await waitFor(() => expect(screen.getByText("The narrator.")).toBeTruthy());
    expect(screen.queryByText("Note: The narrator.")).toBeNull();
    await fireEvent.press(screen.getByTestId("notebook-tab-notes"));
    expect(screen.getByText("The narrator.")).toBeTruthy();
    expect(screen.queryByText(/Note: /)).toBeNull();
  });
});
