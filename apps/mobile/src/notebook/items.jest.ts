import { describe, expect, it } from "@jest/globals";
import { buildNotebookItems, filterNotebook, notebookCounts } from "./items";
import type { OpenConflict } from "../sync/wire";

const conflict: OpenConflict = {
  conflictId: "c_1",
  bookId: "sha256:aa",
  kind: "note",
  id: "h1",
  baseVersion: 1,
  base: null,
  openedSeq: 4,
  sides: [],
};

describe("notebook items", () => {
  it("groups highlights, notes, and words and attaches a read-only conflict", () => {
    const items = buildNotebookItems({
      bookId: "sha256:aa",
      bookTitle: "Book A",
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
        {
          id: "h2",
          color: 3,
          quote: "driving off the spleen",
          prefix: "",
          suffix: "",
          section: "Chapter 1. Loomings",
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
      words: [
        {
          id: "w_ishmael",
          word: "Ishmael",
          definition: "the narrator",
          learned: false,
          lookups: [],
          extras: {},
        },
      ],
      conflicts: [conflict],
    });
    const highlights = filterNotebook(items, "highlights");
    const notes = filterNotebook(items, "notes");
    const words = filterNotebook(items, "words");
    expect(notebookCounts(items)).toEqual({ highlights: 2, notes: 1, words: 1 });
    expect(highlights[0]?.note).toBe("The narrator.");
    expect(highlights[0]?.locationLabel).toBe("p. 12");
    expect(highlights[0]?.conflict?.conflictId).toBe("c_1");
    expect(highlights[1]?.locationLabel).toBe("Chapter 1. Loomings");
    expect(notes[0]?.id).toBe("h1");
    expect(words[0]?.quote).toBe("Ishmael");
  });

  it("omits empty notes from the notes tab", () => {
    const items = buildNotebookItems({
      bookId: "sha256:aa",
      bookTitle: "Book A",
      highlights: [
        { id: "h1", color: 1, quote: "Hello", prefix: "", suffix: "", page: 1, rects: [], extras: {} },
      ],
      notes: [
        { id: "h1", quote: "Hello", prefix: "", suffix: "", ai: false, scope: "passage", body: "   ", extras: {} },
      ],
      words: [],
      conflicts: [],
    });
    expect(filterNotebook(items, "notes")).toEqual([]);
    expect(filterNotebook(items, "highlights")[0]?.note).toBeUndefined();
  });
});
