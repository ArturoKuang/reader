/**
 * Word ids match Swift `WordStore.normalize` byte for byte:
 * `word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`.
 *
 * No Unicode normalization. NFC and NFD spellings stay different ids.
 *
 * `CharacterSet.whitespacesAndNewlines` is Unicode general categories
 * Zs, Zl, and Zp, plus U+000A through U+000D and U+0085. U+FEFF is not
 * in that set (JavaScript `trim` removes it). U+0009 is not in it either.
 *
 * Lowercasing is per code point. `String.prototype.toLowerCase` on the
 * whole string maps a word-final Σ to ς; Swift `lowercased()` maps each
 * scalar, so Σ becomes σ. Single-code-point mappings that expand, such
 * as İ → i + combining dot, are kept.
 */

function isTrimCodePoint(codePoint: number): boolean {
  if (codePoint >= 0x000a && codePoint <= 0x000d) return true;
  if (codePoint === 0x0085) return true;
  if (codePoint === 0xfeff || codePoint === 0x0009) return false;
  const char = String.fromCodePoint(codePoint);
  return /\p{Zs}|\p{Zl}|\p{Zp}/u.test(char);
}

export function normalizeWord(word: string): string {
  let start = 0;
  let end = word.length;
  while (start < end) {
    const codePoint = word.codePointAt(start) ?? 0;
    if (!isTrimCodePoint(codePoint)) break;
    start += codePoint > 0xffff ? 2 : 1;
  }
  while (end > start) {
    const codePoint = word.codePointAt(end - 1) ?? 0;
    if (!isTrimCodePoint(codePoint)) break;
    end -= 1;
  }
  let lowered = "";
  for (let index = start; index < end; ) {
    const codePoint = word.codePointAt(index) ?? 0;
    lowered += String.fromCodePoint(codePoint).toLowerCase();
    index += codePoint > 0xffff ? 2 : 1;
  }
  return lowered;
}

/** `"w_" + WordStore.normalize(word)`, the id Reader writes for a lookup. */
export function wordId(word: string): string {
  return `w_${normalizeWord(word)}`;
}
