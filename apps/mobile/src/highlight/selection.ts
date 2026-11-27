import { ANCHOR_CONTEXT } from "./locate";
import { takeFirstGraphemes, takeLastGraphemes } from "./graphemes";

export interface CapturedAnchor {
  quote: string;
  prefix: string;
  suffix: string;
  page?: number;
  section?: string;
  rects: number[][];
}

/** Prefix and suffix are the same 80-character window reanchor stores. */
export function captureAnchor(
  text: string,
  start: number,
  end: number,
  page?: number,
  section?: string,
): CapturedAnchor {
  return {
    quote: text.slice(start, end),
    prefix: takeLastGraphemes(text.slice(0, start), ANCHOR_CONTEXT),
    suffix: takeFirstGraphemes(text.slice(end), ANCHOR_CONTEXT),
    page,
    section,
    rects: [],
  };
}

export interface WordSpan {
  text: string;
  start: number;
  end: number;
}

export function wordSpans(text: string): WordSpan[] {
  const spans: WordSpan[] = [];
  const pattern = /\S+/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text))) {
    spans.push({ text: match[0], start: match.index, end: match.index + match[0].length });
  }
  return spans;
}
