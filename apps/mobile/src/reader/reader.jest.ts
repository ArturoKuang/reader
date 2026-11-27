import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseHostMessage, parseViewerMessage } from "../reader/bridge";
import { viewportRectToPdfRect } from "../reader/pdfRects";
import { applyLocated } from "../reader/applyLocated";
import { epubViewerHtml } from "../reader/viewerHtml";
import { emptyShelf, parseShelf, serializeShelf } from "../reader/shelf";
import { addHighlight, reanchorRecords } from "../highlight/store";
import type { HighlightRecord } from "../contract/types";

describe("viewer bridge", () => {
  test("accepts host and viewer messages and rejects anything else", () => {
    const open = parseHostMessage(JSON.stringify({ type: "open-pdf", base64: "YQ==" }));
    expect(open?.type).toBe("open-pdf");
    const selection = parseViewerMessage(
      JSON.stringify({ type: "selection", quote: "Ishmael", before: "Call me ", after: ".", rects: [] }),
    );
    expect(selection?.type).toBe("selection");
    expect(parseHostMessage("{")).toBeNull();
    expect(parseViewerMessage(JSON.stringify({ type: "open-pdf" }))).toBeNull();
    expect(parseHostMessage(JSON.stringify({ type: "nope" }))).toBeNull();
  });
});

describe("PDF rect conversion", () => {
  test("maps a top-left viewport rect into unrotated bottom-left page space", () => {
    const viewBox: [number, number, number, number] = [0, 0, 612, 792];
    const rect = viewportRectToPdfRect({ left: 144, top: 100, right: 244, bottom: 140 }, 2, viewBox);
    expect(rect[0]).toBeCloseTo(72);
    expect(rect[1]).toBeCloseTo(722);
    expect(rect[2]).toBeCloseTo(122);
    expect(rect[3]).toBeCloseTo(742);
  });
});

describe("re-anchor when the hint is wrong", () => {
  const quote = "driving off the spleen";
  const prefix = "way I have of ";
  const suffix = ".";

  test("a PDF page hint of 99 is replaced by the page that contains the quote", () => {
    const created = addHighlight(
      [],
      { quote, prefix, suffix, page: 99, rects: [[1, 2, 3, 4]] },
      1,
      "h1",
    );
    const moved = reanchorRecords(created.highlights, [], [
      { page: 1, section: "Page 1", text: "Call me Ishmael." },
      { page: 2, section: "Page 2", text: "It is a way I have of driving off the spleen." },
    ]);
    expect(moved.unresolvedIDs).toEqual([]);
    expect(moved.highlights[0]?.page).toBe(2);
    expect(moved.highlights[0]?.section).toBe("Page 2");
  });

  test("a bogus EPUB CFI is replaced from the quote", () => {
    const highlight: HighlightRecord = {
      id: "h-epub",
      color: 1,
      quote,
      prefix,
      suffix,
      cfi: "epubcfi(/6/98!/4,/1:0,/1:1)",
      rects: [],
      extras: {},
    };
    const moved = reanchorRecords([highlight], [], [
      { spineIndex: 0, section: "Chapter 1", text: "Call me Ishmael." },
      { spineIndex: 1, section: "Chapter 2", text: "It is a way I have of driving off the spleen." },
    ]);
    expect(moved.highlights[0]?.cfi?.startsWith("epubcfi(/6/4!")).toBe(true);
    expect(moved.highlights[0]?.cfi).not.toBe(highlight.cfi);
  });
});

describe("local shelf", () => {
  test("round-trips highlights separately from notes and keeps color 1 as the default", () => {
    const fresh = parseShelf(null);
    expect(fresh.lastColor).toBe(1);
    const saved = serializeShelf({
      ...emptyShelf(),
      lastColor: 4,
      highlights: [
        {
          id: "h1",
          color: 4,
          quote: "Ishmael",
          prefix: "Call me ",
          suffix: ".",
          page: 1,
          rects: [[72, 680, 160, 700]],
          extras: {},
        },
      ],
      notes: [
        {
          id: "h1",
          quote: "Ishmael",
          prefix: "Call me ",
          suffix: ".",
          page: 1,
          ai: false,
          scope: "passage",
          body: "The narrator.",
          extras: {},
        },
      ],
    });
    const loaded = parseShelf(saved);
    expect(loaded.highlights[0]?.id).toBe("h1");
    expect(loaded.notes[0]?.id).toBe("h1");
    expect("noteId" in (loaded.highlights[0] ?? {})).toBe(false);
    expect(loaded.notes[0]?.body).toBe("The narrator.");
    expect("body" in (loaded.highlights[0] ?? {})).toBe(false);
  });

  test("applyLocated keeps a highlight when the viewer cannot find the quote", () => {
    const highlight: HighlightRecord = {
      id: "h1",
      color: 1,
      quote: "Ishmael",
      prefix: "",
      suffix: "",
      page: 3,
      rects: [[1, 2, 3, 4]],
      extras: {},
    };
    expect(applyLocated(highlight, { found: false, prefix: "", suffix: "", rects: [] }).page).toBe(3);
  });
});

describe("sample books", () => {
  test("the PDF contains extractable text and the EPUB contains both chapters", () => {
    const dir = join(__dirname, "../../assets/samples");
    const pdf = readFileSync(join(dir, "ishmael.pdf"));
    const epub = readFileSync(join(dir, "ishmael.epub"));
    expect(pdf.subarray(0, 5).toString()).toBe("%PDF-");
    expect(pdf.toString("latin1")).toContain("Call me Ishmael.");
    expect(pdf.toString("latin1")).toContain("/ID [<4B1E77C0>");
    expect(epub.subarray(0, 2).toString()).toBe("PK");
    expect(epub.toString("latin1")).toContain("chapter1.xhtml");
    expect(epub.toString("latin1")).toContain("driving off the spleen");
    const catalog = JSON.parse(readFileSync(join(dir, "catalog.json"), "utf8")) as {
      pdf: { fingerprint: string };
      epub: { fingerprint: string };
    };
    expect(catalog.pdf.fingerprint).toBe(`sha256:${createHash("sha256").update(pdf).digest("hex")}`);
    expect(catalog.epub.fingerprint).toBe(`sha256:${createHash("sha256").update(epub).digest("hex")}`);
  });
});

describe("epub viewer HTML", () => {
  test("the CFI spine regex is valid after template-literal escaping", () => {
    const html = epubViewerHtml();
    expect(html).toContain(String.raw`/epubcfi\(\/6\/(\d+)/`);
    expect(html).not.toContain("/epubcfi(/6/(d+)/");
  });
});
