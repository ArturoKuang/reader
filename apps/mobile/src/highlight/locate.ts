/**
 * Reanchor.locate (`Reanchor.swift`). The anchor of record is quote +
 * prefix + suffix. A hit refreshes prefix and suffix to at most 80
 * characters of surrounding text. An EPUB slice also builds a CFI hint.
 */

import { graphemeClusters, takeFirstGraphemes, takeLastGraphemes } from "./graphemes";

export const ANCHOR_CONTEXT = 80;

export interface TextSlice {
  page?: number;
  spineIndex?: number;
  section?: string;
  text: string;
}

export interface AnchorHit {
  page?: number;
  spineIndex?: number;
  section?: string;
  prefix: string;
  suffix: string;
  cfi?: string;
  confidence: "exactContext" | "quoteOnly";
  /** UTF-16 index of the quote in the matched slice. For painting. */
  start: number;
  end: number;
}

/** `epubcfi(/6/{(spineIndex+1)*2}!/4,/1:{start},/1:{end})` */
export function epubCfi(spineIndex: number, start: number, end: number): string {
  const step = (spineIndex + 1) * 2;
  return `epubcfi(/6/${step}!/4,/1:${start},/1:${end})`;
}

export function locate(
  quote: string,
  prefix: string,
  suffix: string,
  corpus: readonly TextSlice[],
): AnchorHit | null {
  const needle = quote.trim();
  if (needle.length === 0) return null;
  return (
    search(needle, prefix, suffix, corpus, true) ??
    search(needle, prefix, suffix, corpus, false)
  );
}

/**
 * When a lookup quote is empty, reanchor uses the headword
 * (`Reanchor.swift` word loop).
 */
export function locateLookup(
  word: string,
  quote: string,
  prefix: string,
  suffix: string,
  corpus: readonly TextSlice[],
): AnchorHit | null {
  return locate(quote.length === 0 ? word : quote, prefix, suffix, corpus);
}

function search(
  quote: string,
  prefix: string,
  suffix: string,
  corpus: readonly TextSlice[],
  requireContext: boolean,
): AnchorHit | null {
  for (const slice of corpus) {
    let from = 0;
    while (from <= slice.text.length) {
      const index = slice.text.indexOf(quote, from);
      if (index < 0) break;
      const before = slice.text.slice(0, index);
      const after = slice.text.slice(index + quote.length);
      const prefixOk = prefix.length === 0 || before.endsWith(prefix);
      const suffixOk = suffix.length === 0 || after.startsWith(suffix);
      if (requireContext) {
        if (prefixOk && suffixOk && (prefix.length > 0 || suffix.length > 0)) {
          return hit(slice, quote, before, after, index, "exactContext");
        }
      } else if (
        (prefix.length === 0 && suffix.length === 0) ||
        !prefixOk ||
        !suffixOk
      ) {
        if ((prefix.length === 0 && suffix.length === 0) || !requireContext) {
          return hit(slice, quote, before, after, index, "quoteOnly");
        }
      }
      from = index + quote.length;
    }
  }
  return null;
}

function hit(
  slice: TextSlice,
  quote: string,
  before: string,
  after: string,
  index: number,
  confidence: AnchorHit["confidence"],
): AnchorHit {
  const start = graphemeClusters(before).length;
  const cfi =
    slice.spineIndex === undefined
      ? undefined
      : epubCfi(slice.spineIndex, start, start + graphemeClusters(quote).length);
  return {
    page: slice.page,
    spineIndex: slice.spineIndex,
    section: slice.section,
    prefix: takeLastGraphemes(before, ANCHOR_CONTEXT),
    suffix: takeFirstGraphemes(after, ANCHOR_CONTEXT),
    cfi,
    confidence,
    start: index,
    end: index + quote.length,
  };
}
