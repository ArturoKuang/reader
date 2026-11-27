/** Local reading progress, kept next to the book shelf and used by the library. */

export interface BookProgress {
  page?: number;
  pageCount?: number;
  progression?: number;
  chapterKey?: string;
  updatedAt: number;
}

export function progressKey(fingerprint: string): string {
  return `reader.progress.${fingerprint}`;
}

export function parseProgress(raw: string | null): BookProgress | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as Partial<BookProgress>;
    const updatedAt = typeof value.updatedAt === "number" ? value.updatedAt : 0;
    const progress: BookProgress = { updatedAt };
    if (typeof value.page === "number") progress.page = value.page;
    if (typeof value.pageCount === "number") progress.pageCount = value.pageCount;
    if (typeof value.progression === "number") progress.progression = value.progression;
    if (typeof value.chapterKey === "string") progress.chapterKey = value.chapterKey;
    return progress;
  } catch {
    return null;
  }
}

export function serializeProgress(progress: BookProgress): string {
  return JSON.stringify(progress);
}

export function progressRatio(progress: BookProgress | null): number | null {
  if (!progress) return null;
  if (typeof progress.progression === "number" && Number.isFinite(progress.progression)) {
    return clamp01(progress.progression);
  }
  if (
    typeof progress.page === "number" &&
    typeof progress.pageCount === "number" &&
    progress.pageCount > 0
  ) {
    return clamp01(progress.page / progress.pageCount);
  }
  return null;
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}
