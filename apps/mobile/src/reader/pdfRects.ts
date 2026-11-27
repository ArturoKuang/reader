/**
 * PDF.js rotation-0 viewport conversion.
 * `getViewport({ rotation: 0 })` uses a top-left origin in CSS pixels.
 * Stored rects are unrotated PDF user space: `[minX, minY, maxX, maxY]`,
 * origin bottom-left, the same convention as ReaderCore.
 */
export type PdfViewBox = [number, number, number, number];

export interface ViewportRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export function viewportPointToPdf(
  x: number,
  y: number,
  scale: number,
  viewBox: PdfViewBox,
): [number, number] {
  const [xMin, , , yMax] = viewBox;
  return [x / scale + xMin, yMax - y / scale];
}

export function viewportRectToPdfRect(
  rect: ViewportRect,
  scale: number,
  viewBox: PdfViewBox,
): [number, number, number, number] {
  const [x1, y1] = viewportPointToPdf(rect.left, rect.top, scale, viewBox);
  const [x2, y2] = viewportPointToPdf(rect.right, rect.bottom, scale, viewBox);
  return [Math.min(x1, x2), Math.min(y1, y2), Math.max(x1, x2), Math.max(y1, y2)];
}
