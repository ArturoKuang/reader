import { addHighlight, autoReanchorOnOpen, persistReanchoredHighlight, saveNote } from "./store";
import { normalizeEpubSection } from "./epubSection";
import { STALE_EPUB_CFI, epubCfiResolvesOnSpine, epubCfiSpineIndex } from "./epubCfi";
import type { HighlightRecord, NoteRecord } from "../contract/types";
import type { TextSlice } from "./locate";

const corpus: TextSlice[] = [
  { page: 1, section: "Page 1", text: "Call me Ishmael." },
  { page: 2, section: "Page 2", text: "It is a way I have of driving off the spleen." },
];

const epubCorpus: TextSlice[] = [
  { spineIndex: 0, section: "Chapter 1. Loomings", text: "Call me Ishmael." },
  { spineIndex: 1, section: "Chapter 1, continued", text: "It is a way I have of driving off the spleen." },
];

function highlightWithNote(): { highlights: HighlightRecord[]; notes: NoteRecord[] } {
  const created = addHighlight(
    [],
    {
      quote: "driving off the spleen",
      prefix: "way I have of ",
      suffix: ".",
      page: 2,
      section: "Page 2",
      rects: [[1, 2, 3, 4]],
    },
    3,
    "h_keep",
  );
  const saved = saveNote(created.highlights, [], "h_keep", "Why he goes to sea.", "2026-11-26T00:00:00Z");
  if (!saved) throw new Error("expected linked note");
  return saved;
}

describe("auto re-anchor on book open", () => {
  test("a valid PDF page hint keeps the highlight id and its linked note", () => {
    const shelf = highlightWithNote();
    const restored = autoReanchorOnOpen(shelf.highlights, shelf.notes, corpus);
    expect(restored.reanchoredIds).toEqual([]);
    expect(restored.highlights).toHaveLength(1);
    expect(restored.notes).toHaveLength(1);
    expect(restored.highlights[0]?.id).toBe("h_keep");
    expect(restored.notes[0]?.id).toBe("h_keep");
    expect(restored.notes[0]?.body).toBe("Why he goes to sea.");
    expect(restored.highlights[0]?.page).toBe(2);
    expect(restored.highlights[0]?.color).toBe(3);
  });

  test("a scrambled PDF page hint re-anchors by quote and preserves the id and note", () => {
    const shelf = highlightWithNote();
    const scrambled: HighlightRecord = { ...shelf.highlights[0]!, page: 99, rects: [[9, 9, 9, 9]] };
    const restored = autoReanchorOnOpen([scrambled], shelf.notes, corpus);
    expect(restored.reanchoredIds).toEqual(["h_keep"]);
    expect(restored.highlights).toHaveLength(1);
    expect(restored.notes).toHaveLength(1);
    expect(restored.highlights[0]?.id).toBe("h_keep");
    expect(restored.notes[0]?.id).toBe("h_keep");
    expect(restored.notes[0]?.body).toBe("Why he goes to sea.");
    expect(restored.highlights[0]?.page).toBe(2);
    expect(restored.highlights[0]?.section).toBe("Page 2");
    expect(restored.notes[0]?.page).toBe(2);
    expect(restored.notes[0]?.section).toBe(restored.highlights[0]?.section);
  });

  test("a scrambled EPUB CFI re-anchors by quote and preserves the id and note", () => {
    const created = addHighlight(
      [],
      {
        quote: "Call me Ishmael.",
        prefix: "",
        suffix: "",
        cfi: "epubcfi(/6/98!/4,/1:0,/1:1)",
        section: "OEBPS/chapter1.xhtml",
        rects: [],
      },
      1,
      "h_epub",
    );
    const saved = saveNote(
      created.highlights,
      [],
      "h_epub",
      "The first sentence.",
      "2026-11-26T00:00:00Z",
    );
    if (!saved) throw new Error("expected linked note");
    const restored = autoReanchorOnOpen(saved.highlights, saved.notes, epubCorpus);
    expect(restored.reanchoredIds).toEqual(["h_epub"]);
    expect(restored.highlights[0]?.id).toBe("h_epub");
    expect(restored.notes[0]?.id).toBe("h_epub");
    expect(restored.notes[0]?.body).toBe("The first sentence.");
    expect(restored.highlights[0]?.cfi).toMatch(/^epubcfi\(\/6\/2!/);
    expect(restored.highlights[0]?.cfi).not.toBe("epubcfi(/6/98!/4,/1:0,/1:1)");
    expect(restored.notes[0]?.cfi).toBe(restored.highlights[0]?.cfi);
  });

  test("persistReanchoredHighlight updates the existing record and does not add a note", () => {
    const shelf = highlightWithNote();
    const persisted = persistReanchoredHighlight(shelf.highlights, shelf.notes, {
      id: "h_keep",
      found: true,
      page: 2,
      section: "Page 2",
      prefix: "way I have of ",
      suffix: ".",
      rects: [[10, 20, 30, 40]],
    });
    expect(persisted).not.toBeNull();
    expect(persisted?.highlights).toHaveLength(1);
    expect(persisted?.notes).toHaveLength(1);
    expect(persisted?.highlights[0]?.id).toBe("h_keep");
    expect(persisted?.notes[0]?.id).toBe("h_keep");
    expect(persisted?.highlights[0]?.rects).toEqual([[10, 20, 30, 40]]);
    expect(persisted?.notes[0]?.body).toBe("Why he goes to sea.");
  });
});

describe("EPUB section normalization", () => {
  test("highlight.section === note.section and is a human chapter label", () => {
    const section = normalizeEpubSection("OEBPS/chapter1.xhtml", 0);
    expect(section).toBe("Chapter 1");
    const created = addHighlight(
      [],
      {
        quote: "Call me Ishmael.",
        prefix: "",
        suffix: "",
        cfi: "epubcfi(/6/2!/4,/1:0,/1:16)",
        section,
        rects: [],
      },
      1,
      "h_section",
    );
    const saved = saveNote(
      created.highlights,
      [],
      "h_section",
      "Opening line.",
      "2026-11-26T00:00:00Z",
    );
    expect(saved).not.toBeNull();
    expect(created.entry?.section).toBe("Chapter 1");
    expect(saved?.notes[0]?.section).toBe(created.entry?.section);
    expect(saved?.notes[0]?.id).toBe(created.entry?.id);
    expect(saved?.notes[0]?.section).not.toMatch(/\//);
    expect(saved?.notes[0]?.section).not.toMatch(/\.xhtml$/i);

    const titled = normalizeEpubSection("Chapter 1. Loomings", 0);
    expect(titled).toBe("Chapter 1. Loomings");
    const pathOnNoteOnly = persistReanchoredHighlight(
      [
        {
          id: "h_section",
          color: 1,
          quote: "Call me Ishmael.",
          prefix: "",
          suffix: "",
          cfi: "epubcfi(/6/2!/4,/1:0,/1:16)",
          section: titled,
          rects: [],
          extras: {},
        },
      ],
      [
        {
          id: "h_section",
          quote: "Call me Ishmael.",
          prefix: "",
          suffix: "",
          section: "OEBPS/chapter1.xhtml",
          ai: false,
          scope: "passage",
          body: "Opening line.",
          extras: {},
        },
      ],
      {
        id: "h_section",
        found: true,
        cfi: "epubcfi(/6/2!/4,/1:0,/1:16)",
        section: titled,
        prefix: "",
        suffix: "",
        rects: [],
      },
    );
    expect(pathOnNoteOnly?.highlights[0]?.section).toBe(pathOnNoteOnly?.notes[0]?.section);
    expect(pathOnNoteOnly?.highlights[0]?.section).toBe("Chapter 1. Loomings");
  });
});

describe("stale EPUB CFI auto re-anchor on open", () => {
  test("epubcfi(/6/98!/4,/1:0,/1:1) is out of spine for a short book", () => {
    expect(epubCfiSpineIndex(STALE_EPUB_CFI)).toBe(48);
    expect(epubCfiResolvesOnSpine(STALE_EPUB_CFI, 2)).toBe(false);
    expect(epubCfiResolvesOnSpine("epubcfi(/6/2!/4,/1:0,/1:16)", 2)).toBe(true);
  });

  test("a stale highlight CFI is repaired on open while the note keeps its id and body", () => {
    const created = addHighlight(
      [],
      {
        quote: "Call me Ishmael.",
        prefix: "",
        suffix: "",
        cfi: "epubcfi(/6/2!/4,/1:0,/1:16)",
        section: "Chapter 1. Loomings",
        rects: [],
      },
      1,
      "h_stale",
    );
    const saved = saveNote(
      created.highlights,
      [],
      "h_stale",
      "The first sentence.",
      "2026-11-26T00:00:00Z",
    );
    if (!saved) throw new Error("expected linked note");
    const staleHighlight = { ...saved.highlights[0]!, cfi: STALE_EPUB_CFI };
    const noteWithGoodCfi = { ...saved.notes[0]!, cfi: "epubcfi(/6/2!/4,/1:0,/1:16)" };
    const restored = autoReanchorOnOpen([staleHighlight], [noteWithGoodCfi], epubCorpus);
    expect(restored.reanchoredIds).toEqual(["h_stale"]);
    expect(restored.highlights).toHaveLength(1);
    expect(restored.notes).toHaveLength(1);
    expect(restored.highlights[0]?.id).toBe("h_stale");
    expect(restored.notes[0]?.id).toBe("h_stale");
    expect(restored.notes[0]?.body).toBe("The first sentence.");
    expect(restored.highlights[0]?.cfi).not.toBe(STALE_EPUB_CFI);
    expect(restored.highlights[0]?.cfi).toMatch(/^epubcfi\(\/6\/2!/);
    expect(restored.notes[0]?.cfi).toBe(restored.highlights[0]?.cfi);
  });

  test("persistReanchoredHighlight writes the repaired CFI onto the existing highlight and note", () => {
    const created = addHighlight(
      [],
      {
        quote: "Call me Ishmael.",
        prefix: "",
        suffix: "",
        cfi: STALE_EPUB_CFI,
        section: "Chapter 1. Loomings",
        rects: [],
      },
      2,
      "h_stale",
    );
    const saved = saveNote(
      created.highlights,
      [],
      "h_stale",
      "The first sentence.",
      "2026-11-26T00:00:00Z",
    );
    if (!saved) throw new Error("expected linked note");
    const repaired = "epubcfi(/6/2!/4,/1:0,/1:16)";
    const persisted = persistReanchoredHighlight(saved.highlights, saved.notes, {
      id: "h_stale",
      found: true,
      cfi: repaired,
      section: "Chapter 1. Loomings",
      prefix: "",
      suffix: "",
      rects: [],
    });
    expect(persisted).not.toBeNull();
    expect(persisted?.highlights).toHaveLength(1);
    expect(persisted?.notes).toHaveLength(1);
    expect(persisted?.highlights[0]?.id).toBe("h_stale");
    expect(persisted?.notes[0]?.id).toBe("h_stale");
    expect(persisted?.highlights[0]?.color).toBe(2);
    expect(persisted?.highlights[0]?.cfi).toBe(repaired);
    expect(persisted?.notes[0]?.cfi).toBe(repaired);
    expect(persisted?.notes[0]?.body).toBe("The first sentence.");
  });
});
