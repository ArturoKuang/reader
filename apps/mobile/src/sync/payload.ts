import type { HighlightRecord, JsonValue, LookupRecord, NoteRecord, WordRecord } from "../contract/types";
import { asJsonObject } from "./canonical";
import { wordId } from "./ids";
import type { JsonObject, Locator, PositionPayload } from "./wire";

function copyExtras(extras: { [key: string]: JsonValue } | undefined): { [key: string]: JsonValue } {
  return { ...(extras ?? {}) };
}

function withOptionals(target: Record<string, unknown>, source: object): void {
  for (const [key, value] of Object.entries(source)) {
    if (value !== undefined) target[key] = value;
  }
}

export function highlightToPayload(highlight: HighlightRecord): JsonObject {
  const payload: Record<string, unknown> = {
    color: highlight.color,
    quote: highlight.quote,
    prefix: highlight.prefix,
    suffix: highlight.suffix,
    extras: copyExtras(highlight.extras),
  };
  withOptionals(payload, {
    page: highlight.page,
    cfi: highlight.cfi,
    section: highlight.section,
    rects: highlight.rects,
  });
  return asJsonObject(payload);
}

export function noteToPayload(note: NoteRecord): JsonObject {
  const payload: Record<string, unknown> = {
    quote: note.quote,
    prefix: note.prefix,
    suffix: note.suffix,
    ai: note.ai,
    scope: note.scope,
    body: note.body,
    extras: copyExtras(note.extras),
  };
  withOptionals(payload, {
    page: note.page,
    cfi: note.cfi,
    section: note.section,
    created: note.created,
    updated: note.updated,
    provider: note.provider,
  });
  return asJsonObject(payload);
}

/** Lookups stay separate records. They are not nested in the word payload. */
export function wordToPayload(word: WordRecord): JsonObject {
  const payload: Record<string, unknown> = {
    word: word.word,
    definition: word.definition,
    learned: word.learned,
    extras: copyExtras(word.extras),
  };
  withOptionals(payload, {
    explanation: word.explanation,
    explanationProvider: word.explanationProvider,
    pronunciation: word.pronunciation,
    partOfSpeech: word.partOfSpeech,
  });
  const expectedId = wordId(word.word);
  if (expectedId === null || word.id !== expectedId) {
    throw new Error("word id must be w_ plus normalizeWord(word)");
  }
  return asJsonObject(payload);
}

export function lookupToPayload(wordIdValue: string, lookup: LookupRecord): JsonObject {
  const payload: Record<string, unknown> = {
    wordId: wordIdValue,
    quote: lookup.quote,
    prefix: lookup.prefix,
    suffix: lookup.suffix,
    sentence: lookup.sentence,
    date: lookup.date,
    extras: copyExtras(lookup.extras),
  };
  withOptionals(payload, {
    page: lookup.page,
    cfi: lookup.cfi,
    section: lookup.section,
  });
  return asJsonObject(payload);
}

export function positionToPayload(bookId: string, deviceId: string, locator: Locator): PositionPayload {
  return {
    bookId,
    deviceId,
    locator,
    extras: {},
  };
}
