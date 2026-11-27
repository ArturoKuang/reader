import assert from "node:assert/strict";
import { test } from "node:test";
import { locateLookup } from "./locate";
import { sampleHighlight, sampleNote, samplePages, reprintChapter } from "./sample";
import { captureAnchor } from "./selection";
import { addHighlight, reanchorRecords, saveNote } from "./store";

test("capturing a selection stores at most 80 characters of context", () => {
  const page = samplePages[0];
  assert.ok(page);
  const start = page.text.indexOf("we do not see, or we forget");
  const anchor = captureAnchor(page.text, start, start + "we do not see, or we forget".length, page.page, page.section);
  assert.equal(anchor.quote, sampleHighlight.quote);
  assert.equal(anchor.prefix.length <= 80, true);
  assert.ok(anchor.prefix.endsWith(sampleHighlight.prefix));
  assert.ok(anchor.suffix.startsWith(", that the birds"));
});

test("a second highlight of the same passage returns the existing record", () => {
  const added = addHighlight(
    [sampleHighlight],
    {
      quote: sampleHighlight.quote,
      prefix: "other",
      suffix: "other",
      page: sampleHighlight.page,
      section: sampleHighlight.section,
    },
    5,
    "h2",
  );
  assert.equal(added.entry?.id, "h1");
  assert.equal(added.highlights.length, 1);
  assert.equal(added.entry?.color, 1);
});

test("saving a note keeps it separate and reuses the highlight id", () => {
  const saved = saveNote([sampleHighlight], [], sampleHighlight.id, "A note of mine.", "2026-11-22T00:00:00Z");
  assert.ok(saved);
  assert.equal("noteId" in (saved.highlights[0] ?? {}), false);
  assert.equal(saved.notes.length, 1);
  const note = saved.notes[0];
  assert.ok(note);
  assert.equal(note.id, sampleHighlight.id);
  assert.equal(note.body, "A note of mine.");
  assert.equal(note.quote, sampleHighlight.quote);
  assert.equal("color" in note, false);
  assert.notEqual(note, saved.highlights[0]);
});

test("reanchor moves a passage and leaves a missing quote unresolved", () => {
  const created = addHighlight(
    [],
    {
      quote: "natural selection",
      prefix: "called ",
      suffix: " works slowly",
      page: 9,
      section: "Ch. 4",
    },
    2,
    "h4",
  );
  const moved = reanchorRecords(created.highlights, [], reprintChapter(samplePages));
  assert.deepEqual(moved.unresolvedIDs, []);
  assert.equal(moved.highlights[0]?.page, 14);
  assert.equal(moved.highlights[0]?.section, "Ch. 4 · Natural Selection");
  assert.equal(moved.highlights[0]?.prefix, "Later, this process, called ");
  assert.equal(moved.highlights[0]?.suffix, " works slowly over many generations.");

  const lost = reanchorRecords(
    [{ ...sampleHighlight, quote: "missing sentence", prefix: "", suffix: "" }],
    [sampleNote],
    samplePages,
  );
  assert.deepEqual(lost.unresolvedIDs, ["h1"]);
  assert.equal(lost.notes[0]?.id, sampleHighlight.id);
});

test("an empty lookup quote reanchors on the headword", () => {
  const hit = locateLookup(
    "progeny",
    "",
    "the ",
    " of a pair",
    [{ page: 63, section: "Ch. 3", text: "the progeny of a pair" }],
  );
  assert.equal(hit?.confidence, "exactContext");
  assert.equal(hit?.page, 63);
});
