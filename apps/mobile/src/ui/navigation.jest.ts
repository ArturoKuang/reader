import { describe, expect, it } from "@jest/globals";
import { backFrom, libraryRoute, notebookRoute, readerRoute } from "./navigation";
import type { LibraryBook } from "../library/catalog";

const book: LibraryBook = {
  id: "sha256:aa",
  title: "Book A",
  format: "pdf",
  fingerprint: "sha256:aa",
  sha256: "aa",
  size: 10,
  filename: "a.pdf",
  source: "sample",
  cached: true,
  waitingForSpace: false,
  highlightCount: 0,
  noteCount: 0,
  progress: null,
  lastReadAt: 0,
  testID: "library-pdf",
};

describe("v1 navigation", () => {
  it("goes Library → Reader → Notebook and back, and can jump to a passage", () => {
    const reader = readerRoute(book, { highlightId: "h1", locator: { format: "pdf", page: 12 } });
    expect(reader).toEqual({
      name: "reader",
      book,
      jumpTo: { highlightId: "h1", locator: { format: "pdf", page: 12 } },
    });
    const notes = notebookRoute(book);
    expect(notes.name).toBe("notebook");
    expect(backFrom(notes)).toEqual({ name: "reader", book });
    expect(backFrom(reader)).toEqual(libraryRoute);
    expect(backFrom(libraryRoute)).toEqual(libraryRoute);
  });
});
