import type { BookIdentity, HighlightRecord, NoteRecord } from "../contract/types";
import records from "../contract/fixtures/records.json";
import type { TextSlice } from "./locate";

export const sampleBook: BookIdentity = {
  fingerprint: records.book.fingerprint,
  pdfId: records.book.pdfId,
};

export const sampleHighlight: HighlightRecord = {
  id: records.highlight.id,
  color: records.highlight.color,
  page: records.highlight.page,
  quote: records.highlight.quote,
  prefix: records.highlight.prefix,
  suffix: records.highlight.suffix,
  section: records.highlight.section,
  rects: records.highlight.rects,
  extras: records.highlight.extras,
};

export const sampleNote: NoteRecord = {
  id: records.note.id,
  page: records.note.page,
  quote: records.note.quote,
  prefix: records.note.prefix,
  suffix: records.note.suffix,
  section: records.note.section,
  created: records.note.created,
  ai: records.note.ai,
  scope: records.note.scope,
  body: records.note.body,
  extras: records.note.extras,
};

export const samplePages: TextSlice[] = [
  {
    page: 62,
    section: "Ch. 3 · Struggle for Existence",
    text: "We behold the face of nature bright with gladness, we often see superabundance of food; we do not see, or we forget, that the birds which are idly singing round us mostly live on insects or seeds.",
  },
  {
    page: 9,
    section: "Ch. 4",
    text: "This process, called natural selection works slowly over time.",
  },
];

/** Moves the chapter-4 sentence onto a later page without dropping its anchor. */
export function reprintChapter(pages: readonly TextSlice[]): TextSlice[] {
  return pages.map((page) => {
    if (page.page !== 9) return page;
    return {
      page: 14,
      section: "Ch. 4 · Natural Selection",
      text: "Later, this process, called natural selection works slowly over many generations.",
    };
  });
}
