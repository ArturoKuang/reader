/**
 * WordStore.normalize (`Words.swift`): trim Swift
 * `CharacterSet.whitespacesAndNewlines`, then `String.lowercased()`.
 *
 * `lowercased()` is the Unicode default case mapping (not a locale),
 * which is what `String.prototype.toLowerCase` implements. Final sigma
 * and İ → i + combining dot follow from that mapping.
 *
 * Whitespace is the union of Unicode category Zs, tab, and the Foundation
 * newline set (LF, VT, FF, CR, NEL, line separator, paragraph separator).
 * BOM (U+FEFF) and zero-width space are not in that set, so they stay.
 */

const TRIM_CODE_POINTS = new Set<number>([
  0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x0085, 0x00a0, 0x1680, 0x2000, 0x2001, 0x2002,
  0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f,
  0x3000,
]);

export function normalizeWord(word: string): string {
  const chars = [...word];
  let start = 0;
  let end = chars.length;
  const isTrim = (char: string) => TRIM_CODE_POINTS.has(char.codePointAt(0) ?? -1);
  while (start < end && isTrim(chars[start])) start += 1;
  while (end > start && isTrim(chars[end - 1])) end -= 1;
  return chars.slice(start, end).join("").toLowerCase();
}

/** `"w_" + WordStore.normalize(word)`, the id Reader writes for a lookup. */
export function wordId(word: string): string {
  return `w_${normalizeWord(word)}`;
}
