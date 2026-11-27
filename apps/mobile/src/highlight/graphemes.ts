/**
 * v1 grapheme clusters for Hermes, which has no `Intl.Segmenter`.
 * A cluster is a base code point plus combining marks, variation selectors,
 * emoji modifiers, a ZWJ and the code point after it, or a regional-indicator pair.
 */

const ZWJ = 0x200d;

function codePoints(text: string): number[] {
  const points: number[] = [];
  for (let index = 0; index < text.length; ) {
    const codePoint = text.codePointAt(index) ?? 0;
    points.push(codePoint);
    index += codePoint > 0xffff ? 2 : 1;
  }
  return points;
}

function isRegionalIndicator(codePoint: number): boolean {
  return codePoint >= 0x1f1e6 && codePoint <= 0x1f1ff;
}

function isVariationSelector(codePoint: number): boolean {
  return (codePoint >= 0xfe00 && codePoint <= 0xfe0f) || (codePoint >= 0xe0100 && codePoint <= 0xe01ef);
}

function isEmojiModifier(codePoint: number): boolean {
  return codePoint >= 0x1f3fb && codePoint <= 0x1f3ff;
}

function isCombiningMark(codePoint: number): boolean {
  return /\p{M}/u.test(String.fromCodePoint(codePoint));
}

function extendsCluster(codePoint: number): boolean {
  return isCombiningMark(codePoint) || isVariationSelector(codePoint) || isEmojiModifier(codePoint);
}

export function graphemeClusters(text: string): string[] {
  const points = codePoints(text);
  const clusters: string[] = [];
  let index = 0;
  while (index < points.length) {
    let end = index + 1;
    const first = points[index] ?? 0;
    const second = points[index + 1];
    if (second !== undefined && isRegionalIndicator(first) && isRegionalIndicator(second)) {
      end = index + 2;
    } else {
      while (end < points.length) {
        const current = points[end] ?? 0;
        if (extendsCluster(current)) {
          end += 1;
          continue;
        }
        if (current === ZWJ && end + 1 < points.length) {
          end += 2;
          continue;
        }
        break;
      }
    }
    clusters.push(String.fromCodePoint(...points.slice(index, end)));
    index = end;
  }
  return clusters;
}

export function takeLastGraphemes(text: string, count: number): string {
  const parts = graphemeClusters(text);
  return parts.slice(Math.max(0, parts.length - count)).join("");
}

export function takeFirstGraphemes(text: string, count: number): string {
  return graphemeClusters(text).slice(0, count).join("");
}
