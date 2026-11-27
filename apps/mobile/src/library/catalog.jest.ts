import { describe, expect, it } from "@jest/globals";
import { buildLibrary, formatSize, librarySubtitle } from "./catalog";
import type { BookListItem } from "../sync/wire";

const PDF = "f4e07738d0e88e10d71d2ea7cadf2ffdca9165c02b117a35fc60bcd4b76ec055";
const OTHER = "ab".repeat(32);

const samples = [
  {
    title: "Moby-Dick, opening",
    format: "pdf" as const,
    fingerprint: `sha256:${PDF}`,
    sha256: PDF,
    size: 1397,
    filename: "ishmael.pdf",
    testID: "library-pdf",
  },
  {
    title: "Moby-Dick, opening",
    format: "epub" as const,
    fingerprint: "sha256:" + "cd".repeat(32),
    sha256: "cd".repeat(32),
    size: 2284,
    filename: "ishmael.epub",
    testID: "library-epub",
  },
];

function remote(partial: Partial<BookListItem> & Pick<BookListItem, "bookId" | "sha256">): BookListItem {
  return {
    title: "Book C",
    filename: "c.pdf",
    format: "pdf",
    size: 48 * 1024 * 1024,
    hasBlob: true,
    files: [],
    version: 1,
    seq: 1,
    ...partial,
  };
}

describe("buildLibrary", () => {
  it("keeps sample testIDs and merges a synced copy of the same SHA", () => {
    const books = buildLibrary({
      samples,
      remote: [remote({ bookId: `sha256:${PDF}`, sha256: PDF, title: "Moby-Dick, opening", size: 1397 })],
      pausedBookIds: [],
      counts: { [`sha256:${PDF}`]: { highlights: 2, notes: 1 } },
      progress: { [`sha256:${PDF}`]: { page: 1, pageCount: 2, updatedAt: 50 } },
      cachedSha: new Set(),
    });
    expect(books).toHaveLength(2);
    expect(books[0]?.testID).toBe("library-pdf");
    expect(books[0]?.source).toBe("both");
    expect(books[0]?.cached).toBe(true);
    expect(books[0]?.highlightCount).toBe(2);
    expect(books[0]?.noteCount).toBe(1);
    expect(books[0]?.progress).toBe(0.5);
    expect(librarySubtitle(books[0]!)).toBe("50% · 2 highlights · 1 note · PDF");
  });

  it("sorts by most recently read and badges storage-full plus on-demand download", () => {
    const books = buildLibrary({
      samples,
      remote: [
        remote({ bookId: `sha256:${OTHER}`, sha256: OTHER, title: "Book C", size: 48 * 1024 * 1024, hasBlob: true }),
      ],
      pausedBookIds: [`sha256:${OTHER}`],
      counts: {},
      progress: { [`sha256:${OTHER}`]: { page: 12, pageCount: 100, updatedAt: 200 } },
      cachedSha: new Set(),
    });
    expect(books[0]?.id).toBe(`sha256:${OTHER}`);
    expect(books[0]?.waitingForSpace).toBe(true);
    expect(books[0]?.cached).toBe(false);
    expect(librarySubtitle(books[0]!)).toBe("PDF · Waiting for space");
    const downloaded = { ...books[0]!, waitingForSpace: false };
    expect(librarySubtitle(downloaded)).toBe("On Mac mini · PDF · 48 MB · Tap to download");
  });
});

describe("formatSize", () => {
  it("uses MB for large files", () => {
    expect(formatSize(48 * 1024 * 1024)).toBe("48 MB");
    expect(formatSize(1536)).toBe("2 KB");
  });
});
