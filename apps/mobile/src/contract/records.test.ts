import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { isSha256Fingerprint } from "./book";
import { highlightSidecarObject, noteSidecarObject, readerComment } from "./sidecar";
import { HIGHLIGHT_OPACITY, HIGHLIGHT_PALETTE, type HighlightRecord, type NoteRecord, type WordRecord } from "./types";
import { wordId } from "./wordId";

const records = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "fixtures", "records.json"), "utf8"),
) as {
  book: { fingerprint: string; pdfId: string };
  highlight: HighlightRecord;
  note: NoteRecord;
  word: WordRecord;
};

test("the sample book is a sha256 fingerprint plus a pdf id", () => {
  assert.equal(isSha256Fingerprint(records.book.fingerprint), true);
  assert.equal(records.book.pdfId, "4b1e77c0");
  assert.equal(records.book.fingerprint.startsWith("sha256:"), true);
});

test("a highlight and its note are separate records that share one id", () => {
  assert.equal(records.note.id, records.highlight.id);
  assert.equal("noteId" in records.highlight, false);
  assert.equal("highlightId" in records.note, false);
  assert.equal("body" in records.highlight, false);
  assert.equal("color" in records.note, false);
  assert.equal(records.note.body.length > 0, true);
  assert.deepEqual(records.highlight.rects[0], [72, 188.3, 540.2, 230.9]);

  const highlightComment = highlightSidecarObject(records.highlight);
  assert.equal("note" in highlightComment, false);
  assert.equal("noteId" in highlightComment, false);
  const rendered = readerComment(highlightComment);
  assert.equal(rendered.endsWith("-->"), true);
  assert.equal(rendered.slice(0, -3).includes("-->"), false);

  const noteComment = noteSidecarObject(records.note);
  assert.equal(noteComment.id, records.note.id);
  assert.equal("body" in noteComment, false);
  assert.equal("highlightId" in noteComment, false);
  assert.equal("ai" in noteComment, false);
  assert.equal("scope" in noteComment, false);
});

test("word ids in the record fixture match normalization", () => {
  assert.equal(records.word.id, wordId("Progeny"));
  assert.equal(records.word.id, wordId(records.word.word));
  assert.equal(records.word.lookups[0]?.quote, "progeny");
});

test("highlight colors match the palette order and opacity", () => {
  assert.deepEqual(HIGHLIGHT_PALETTE, [
    "F2C94C",
    "6FCF97",
    "56CCF2",
    "F28FB1",
    "BB6BD9",
    "F2994A",
  ]);
  assert.equal(HIGHLIGHT_OPACITY, 0.38);
  assert.equal(records.highlight.color, 1);
});

test("a comment escapes double dashes inside a quote", () => {
  const highlight: HighlightRecord = {
    ...records.highlight,
    quote: "a --> b",
    extras: {},
  };
  const line = readerComment(highlightSidecarObject(highlight));
  assert.equal(line.slice(0, -3).includes("-->"), false);
  assert.match(line, /\\u002d\\u002d/);
});
