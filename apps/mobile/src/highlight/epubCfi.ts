/** Spine index encoded in an EPUB CFI as `/6/{2*(index+1)}`. */
export function epubCfiSpineIndex(cfi: string): number | null {
  const match = /epubcfi\(\/6\/(\d+)/.exec(cfi);
  if (!match) return null;
  const step = Number(match[1]);
  if (!Number.isFinite(step) || step < 2 || step % 2 !== 0) return null;
  return step / 2 - 1;
}

/** True when the CFI names a spine item that exists in this book. */
export function epubCfiResolvesOnSpine(cfi: string | undefined, spineCount: number): boolean {
  if (!cfi) return false;
  const index = epubCfiSpineIndex(cfi);
  return index !== null && index >= 0 && index < spineCount;
}

/** The stale CFI from Reader QA's EPUB auto-reanchor repro. */
export const STALE_EPUB_CFI = "epubcfi(/6/98!/4,/1:0,/1:1)";
