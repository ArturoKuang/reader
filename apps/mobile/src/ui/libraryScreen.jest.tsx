import { describe, expect, it, jest } from "@jest/globals";
import type { ReactElement } from "react";
import { render, screen, waitFor } from "@testing-library/react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { LibraryScreen } from "./LibraryScreen";

const longTitle =
  "A very long book title that should wrap onto two lines and then ellipsize at the tail when it keeps going";

jest.mock("@react-native-async-storage/async-storage", () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
  },
}));

jest.mock("../sync/SyncProvider", () => ({
  useSync: () => null,
}));

jest.mock("../reader/bookCache", () => ({
  cachedShaSet: () => new Set(),
}));

jest.mock("../library/samples", () => ({
  sampleBooks: [
    {
      title:
        "A very long book title that should wrap onto two lines and then ellipsize at the tail when it keeps going",
      format: "pdf",
      fingerprint: "fp-long",
      sha256: "ab".repeat(32),
      size: 100,
      filename: "long.pdf",
      testID: "library-long-title",
    },
  ],
}));

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

describe("library book titles", () => {
  it("clamps long titles to two lines with a tail ellipsis", async () => {
    await render(wrap(<LibraryScreen onOpenBook={() => undefined} />));
    await waitFor(() => expect(screen.getByTestId("library-long-title")).toBeTruthy());
    const title = screen.getByText(longTitle);
    expect(title.props.numberOfLines).toBe(2);
    expect(title.props.ellipsizeMode).toBe("tail");
  });
});
