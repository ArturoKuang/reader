import type { HighlightRecord } from "../contract/types";

export interface LocatedPassage {
  found: boolean;
  page?: number;
  cfi?: string;
  section?: string;
  prefix: string;
  suffix: string;
  rects: number[][];
}

/** Applies a viewer locate result. A miss leaves the stored hint in place. */
export function applyLocated(highlight: HighlightRecord, located: LocatedPassage): HighlightRecord {
  if (!located.found) return highlight;
  return {
    ...highlight,
    page: located.page ?? highlight.page,
    cfi: located.cfi ?? highlight.cfi,
    section: located.section ?? highlight.section,
    prefix: located.prefix,
    suffix: located.suffix,
    rects: located.rects.length > 0 ? located.rects : highlight.rects,
  };
}
