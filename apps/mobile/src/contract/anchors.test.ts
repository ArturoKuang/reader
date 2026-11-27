import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { locate } from "../highlight/locate";
import type { TextSlice } from "../highlight/locate";

interface HitFixture {
  quote: string;
  prefix: string;
  suffix: string;
  corpus: TextSlice[];
  hit: {
    page?: number;
    spineIndex?: number;
    section?: string;
    prefix: string;
    suffix: string;
    cfi?: string;
    confidence: "exactContext" | "quoteOnly";
  } | null;
}

function load(name: string): unknown {
  const here = dirname(fileURLToPath(import.meta.url));
  return JSON.parse(readFileSync(join(here, "fixtures", name), "utf8"));
}

function assertHit(fixture: HitFixture) {
  const hit = locate(fixture.quote, fixture.prefix, fixture.suffix, fixture.corpus);
  if (fixture.hit === null) {
    assert.equal(hit, null);
    return;
  }
  assert.ok(hit);
  assert.equal(hit.page, fixture.hit.page);
  assert.equal(hit.spineIndex, fixture.hit.spineIndex);
  assert.equal(hit.section, fixture.hit.section);
  assert.equal(hit.prefix, fixture.hit.prefix);
  assert.equal(hit.suffix, fixture.hit.suffix);
  assert.equal(hit.cfi, fixture.hit.cfi);
  assert.equal(hit.confidence, fixture.hit.confidence);
  assert.ok(hit.prefix.length <= 80);
  assert.ok(hit.suffix.length <= 80);
}

test("exact context skips an earlier quote and crops the window to 80 characters", () => {
  assertHit(load("exact-context.json") as HitFixture);
});

test("quote-only fallback returns the first occurrence when context does not match", () => {
  assertHit(load("quote-only.json") as HitFixture);
});

test("a missing quote is unresolved and a matching note is not", () => {
  const fixture = load("unresolved.json") as {
    corpus: TextSlice[];
    records: { id: string; quote: string; prefix: string; suffix: string }[];
    unresolvedIDs: string[];
    resolved: Record<string, { page?: number; section?: string; prefix: string; suffix: string; confidence: string }>;
  };
  const unresolved: string[] = [];
  for (const record of fixture.records) {
    const hit = locate(record.quote, record.prefix, record.suffix, fixture.corpus);
    if (!hit) {
      unresolved.push(record.id);
      continue;
    }
    const expected = fixture.resolved[record.id];
    assert.ok(expected);
    assert.equal(hit.page, expected.page);
    assert.equal(hit.section, expected.section);
    assert.equal(hit.prefix, expected.prefix);
    assert.equal(hit.suffix, expected.suffix);
    assert.equal(hit.confidence, expected.confidence);
  }
  assert.deepEqual(unresolved, fixture.unresolvedIDs);
});

test("an empty or whitespace quote does not anchor", () => {
  const fixture = load("empty-quote.json") as { cases: HitFixture[] };
  for (const item of fixture.cases) assertHit(item);
});

test("an EPUB slice builds a CFI from the spine index and character offsets", () => {
  assertHit(load("epub-cfi.json") as HitFixture);
});
