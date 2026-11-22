import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { isSha256Fingerprint, matchBookIdentity, readEpubIdentifier, scanPdfId } from "./book";

function fingerprint(bytes: string): string {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

test("fingerprints are sha256: plus lowercase hex of the file bytes", () => {
  assert.equal(
    fingerprint(""),
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
  assert.equal(
    fingerprint("abc"),
    "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
  assert.equal(isSha256Fingerprint(fingerprint("abc")), true);
  assert.equal(
    isSha256Fingerprint("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    false,
  );
  assert.equal(
    isSha256Fingerprint("sha256:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"),
    false,
  );
});

test("a book matches on the fingerprint, then on pdf or epub id", () => {
  const pdf = {
    fingerprint: fingerprint("version-one"),
    pdfId: "4b1e77c0",
  };
  assert.equal(matchBookIdentity(pdf, { ...pdf }), "exact");
  assert.equal(
    matchBookIdentity(pdf, {
      fingerprint: fingerprint("version-two-small-edit"),
      pdfId: "4b1e77c0",
    }),
    "stableID",
  );
  assert.equal(
    matchBookIdentity(
      { fingerprint: fingerprint("one"), epubId: "urn:isbn:123" },
      { fingerprint: fingerprint("two"), epubId: "urn:isbn:123" },
    ),
    "stableID",
  );
  assert.equal(
    matchBookIdentity(
      { fingerprint: fingerprint("one"), pdfId: "" },
      { fingerprint: fingerprint("two"), pdfId: "" },
    ),
    "different",
  );
  assert.equal(
    matchBookIdentity(
      { fingerprint: fingerprint("one") },
      { fingerprint: fingerprint("two"), pdfId: "4b1e77c0" },
    ),
    "different",
  );
  const bare = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  assert.equal(
    matchBookIdentity({ fingerprint: `sha256:${bare}` }, { fingerprint: bare }),
    "different",
  );
});

test("pdf and epub ids follow ReaderCore", () => {
  const sample = new TextEncoder().encode("trailer /ID [<4B1E77C0><99AA>] >>");
  assert.equal(scanPdfId(sample), "4b1e77c0");
  assert.equal(scanPdfId(new TextEncoder().encode("no id here")), undefined);
  assert.equal(
    readEpubIdentifier("<metadata><dc:identifier> urn:isbn:123 </dc:identifier></metadata>"),
    "urn:isbn:123",
  );
  assert.equal(readEpubIdentifier("<metadata><dc:identifier>  </dc:identifier></metadata>"), undefined);
});
