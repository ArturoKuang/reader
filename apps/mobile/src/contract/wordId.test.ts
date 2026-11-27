import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeWord, wordId } from "./wordId";

function codes(text: string): number[] {
  return [...text].map((char) => char.codePointAt(0) ?? 0);
}

test("word ids are w_ plus the normalized word", () => {
  assert.equal(wordId("Progeny"), "w_progeny");
  assert.equal(wordId("  Economy \n"), "w_economy");
  assert.equal(wordId("  New York  "), "w_new york");
  assert.equal(normalizeWord("Don't"), "don't");
  assert.equal(wordId("well-known"), "w_well-known");
  assert.equal(wordId(" \n "), null);
  assert.equal(wordId("\t \n"), null);
});

test("U+0085 is trimmed and U+FEFF is not", () => {
  assert.equal(normalizeWord("\u0085Progeny\u0085"), "progeny");
  assert.equal(wordId("\u0085word\u0085"), "w_word");
  assert.equal(normalizeWord("\uFEFFword"), "\uFEFFword");
  assert.equal(wordId("\uFEFFword"), "w_\uFEFFword");
  assert.equal("\uFEFFword".trim(), "word");
  assert.notEqual(normalizeWord("\uFEFFword"), "\uFEFFword".trim());
});

test("the trim set is Unicode Z* plus U+0009–U+000D and U+0085", () => {
  assert.equal(normalizeWord("\u00A0Progeny\u00A0"), "progeny");
  assert.equal(normalizeWord("\u2028word\u2029"), "word");
  assert.equal(normalizeWord("\nword\n"), "word");
  assert.equal(normalizeWord("\r\nword\r\n"), "word");
  assert.equal(normalizeWord("\u3000word\u3000"), "word");
  assert.equal(normalizeWord("\u000Bword\u000C"), "word");
  assert.equal(normalizeWord("\u0009word\u0009"), "word");
  assert.equal(normalizeWord("ice\u0009cream"), "ice\u0009cream");
  assert.equal(normalizeWord("\u200Bword"), "\u200Bword");
});

test("lowercase is per code point, so a word-final sigma stays σ", () => {
  assert.equal(normalizeWord("ΟΔΟΣ"), "\u03BF\u03B4\u03BF\u03C3");
  assert.deepEqual(codes(normalizeWord("ΟΔΟΣ")), [0x03bf, 0x03b4, 0x03bf, 0x03c3]);
  assert.notEqual(normalizeWord("ΟΔΟΣ"), "ΟΔΟΣ".toLowerCase());
  assert.equal(wordId("ΟΔΟΣ"), "w_\u03BF\u03B4\u03BF\u03C3");
});

test("İ, ß, and café keep Swift's per-code-point mapping without normalization", () => {
  assert.equal(normalizeWord("İ"), "i\u0307");
  assert.deepEqual(codes(normalizeWord("İ")), [0x0069, 0x0307]);
  assert.equal(wordId("İ"), "w_i\u0307");
  assert.equal(normalizeWord("ß"), "ß");
  assert.equal(wordId("Straße"), "w_straße");
  assert.equal(normalizeWord("ẞ"), "ß");

  const nfc = "caf\u00E9";
  const nfd = "cafe\u0301";
  assert.notEqual(nfc, nfd);
  assert.equal(wordId(nfc), "w_caf\u00E9");
  assert.equal(wordId(nfd), "w_cafe\u0301");
  assert.notEqual(wordId(nfc), wordId(nfd));
  assert.equal(wordId("CAF\u00C9"), wordId(nfc));
  assert.notEqual(wordId("CAFE\u0301"), wordId("CAF\u00C9"));
});
