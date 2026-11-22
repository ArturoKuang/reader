import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeWord, wordId } from "./wordId";

test("word ids are w_ plus WordStore.normalize", () => {
  assert.equal(wordId("Progeny"), "w_progeny");
  assert.equal(wordId("  Economy \n"), "w_economy");
  assert.equal(wordId("\tCAFÉ\n"), "w_café");
  assert.equal(wordId("  New York \t"), "w_new york");
  assert.equal(normalizeWord("Don't"), "don't");
  assert.equal(wordId("well-known"), "w_well-known");
  assert.equal(wordId(" \n\t "), "w_");
});

test("normalization trims Swift whitespace and newlines only", () => {
  assert.equal(normalizeWord("\u00A0Progeny\u00A0"), "progeny");
  assert.equal(normalizeWord("\u0085Progeny\u0085"), "progeny");
  assert.equal(normalizeWord("\u3000word\u3000"), "word");
  assert.equal(normalizeWord("\uFEFFprogeny"), "\uFEFFprogeny");
  assert.equal(normalizeWord("\u200Bword"), "\u200Bword");
});

test("normalization uses Unicode default case mapping, not a locale", () => {
  assert.equal(normalizeWord("I"), "i");
  assert.equal(normalizeWord("İ"), "i\u0307");
  assert.equal(normalizeWord("ΟΣ"), "ος");
  assert.equal(wordId("İ"), "w_i\u0307");
});
