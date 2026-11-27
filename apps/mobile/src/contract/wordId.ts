/**
 * Word ids match Swift `WordStore.normalize`:
 * `word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`.
 *
 * No Unicode normalization. NFC and NFD spellings stay different ids.
 *
 * `CharacterSet.whitespacesAndNewlines` is Unicode general categories
 * Zs, Zl, and Zp, plus U+0009 through U+000D and U+0085. U+FEFF is not
 * in that set (JavaScript `trim` removes it). Only the ends are trimmed;
 * an internal tab or space stays.
 *
 * Lowercasing calls `String.prototype.toLowerCase` on each code point
 * alone. A whole-string `toLowerCase` maps a word-final Σ to ς; per code
 * point, Σ becomes σ and an input ς stays ς. There is no ς→σ fold.
 * Mappings that expand, such as İ → i + combining dot, are kept.
 */

function isTrimCodePoint(codePoint: number): boolean {
  if (codePoint >= 0x0009 && codePoint <= 0x000d) return true;
  if (codePoint === 0x0085) return true;
  if (codePoint === 0xfeff) return false;
  return /\p{Zs}|\p{Zl}|\p{Zp}/u.test(String.fromCodePoint(codePoint));
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

/**
 * `"w_" + normalize(word)` when anything remains after trimming.
 * Empty and whitespace-only input make no word (ReaderSession's guard).
 */
export function wordId(word: string): string | null {
  const normalized = normalizeWord(word);
  if (normalized.length === 0) return null;
  return `w_${normalized}`;
}

export function codePointsOf(text: string): number[] {
  const points: number[] = [];
  for (let index = 0; index < text.length; ) {
    const codePoint = text.codePointAt(index) ?? 0;
    points.push(codePoint);
    index += codePoint > 0xffff ? 2 : 1;
  }
  return points;
}
