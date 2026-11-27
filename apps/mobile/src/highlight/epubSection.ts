/**
 * EPUB section labels must be the same string on a highlight and its
 * linked note. Prefer a human chapter title; never store a spine path
 * like "OEBPS/chapter1.xhtml" on one record and "Chapter 1" on the other.
 */

export function isFileLikeSection(value: string): boolean {
  return /\/|\.(x?html?|xml)$/i.test(value);
}

/** Shared label for an EPUB spine item. `index` is 0-based. */
export function normalizeEpubSection(raw: string | undefined, index: number): string {
  const trimmed = raw?.trim() ?? "";
  if (trimmed.length > 0 && !isFileLikeSection(trimmed)) return trimmed;
  return `Chapter ${index + 1}`;
}
