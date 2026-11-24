import { useMemo, useState } from "react";
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import type { HighlightRecord, NoteRecord } from "../contract/types";
import { locate } from "../highlight/locate";
import type { TextSlice } from "../highlight/locate";
import { reprintChapter, sampleBook, sampleHighlight, sampleNote, samplePages } from "../highlight/sample";
import { captureAnchor, wordSpans } from "../highlight/selection";
import { addHighlight, reanchorRecords, removeHighlight, saveNote } from "../highlight/store";
import { makeId } from "../reader/ids";
import { highlightPaint, tokens } from "./tokens";

interface Selection {
  page: number;
  anchor: number;
  focus: number;
}


function colorHex(color: number): string {
  return tokens.highlight.palette.find((swatch) => swatch.id === color)?.hex ?? tokens.highlight.palette[0].hex;
}

export function HighlightSpike() {
  const [pages, setPages] = useState<TextSlice[]>(samplePages);
  const [highlights, setHighlights] = useState<HighlightRecord[]>([sampleHighlight]);
  const [notes, setNotes] = useState<NoteRecord[]>([sampleNote]);
  const [lastColor, setLastColor] = useState(tokens.highlight.default);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [activeId, setActiveId] = useState<string>(sampleHighlight.id);
  const [draft, setDraft] = useState(sampleNote.body);
  const [notice, setNotice] = useState<string | null>(null);

  const active = highlights.find((highlight) => highlight.id === activeId) ?? null;
  const selectedPage = pages.find((page) => page.page === selection?.page);

  const selectedQuote = useMemo(() => {
    if (!selection || !selectedPage) return "";
    const spans = wordSpans(selectedPage.text);
    const start = spans[Math.min(selection.anchor, selection.focus)];
    const end = spans[Math.max(selection.anchor, selection.focus)];
    if (!start || !end) return "";
    return selectedPage.text.slice(start.start, end.end);
  }, [selection, selectedPage]);

  function tapWord(page: TextSlice, index: number) {
    setNotice(null);
    setSelection((current) => {
      if (!current || current.page !== page.page) return { page: page.page ?? 0, anchor: index, focus: index };
      return { ...current, focus: index };
    });
  }

  function applyColor(color: number) {
    if (!selection || !selectedPage) return;
    const spans = wordSpans(selectedPage.text);
    const start = spans[Math.min(selection.anchor, selection.focus)];
    const end = spans[Math.max(selection.anchor, selection.focus)];
    if (!start || !end) return;
    const anchor = captureAnchor(selectedPage.text, start.start, end.end, selectedPage.page, selectedPage.section);
    const added = addHighlight(highlights, anchor, color, makeId("h"));
    setHighlights(added.highlights);
    if (added.entry) {
      const already = highlights.some((item) => item.id === added.entry?.id);
      setActiveId(added.entry.id);
      if (!already) setLastColor(color);
      const linked = notes.find((note) => note.highlightId === added.entry?.id);
      setDraft(linked?.body ?? "");
      setNotice(already ? "Already highlighted" : null);
    }
    setSelection(null);
  }

  function commitNote() {
    if (!active) return;
    const linked = notes.some((note) => note.highlightId === active.id);
    if (draft.trim().length === 0 && !linked) return;
    const saved = saveNote(highlights, notes, active.id, makeId("n"), draft, new Date().toISOString());
    if (!saved) return;
    setHighlights(saved.highlights);
    setNotes(saved.notes);
    setNotice(draft.trim().length === 0 ? "Note removed" : "Note saved as its own record");
  }

  function reprint() {
    const nextPages = reprintChapter(pages);
    const anchored = reanchorRecords(highlights, notes, nextPages);
    setPages(nextPages);
    setHighlights(anchored.highlights);
    setNotes(anchored.notes);
    setSelection(null);
    setNotice(
      anchored.unresolvedIDs.length === 0
        ? "Re-anchored by quote, prefix, and suffix"
        : `Unresolved: ${anchored.unresolvedIDs.join(", ")}`,
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.content} style={styles.scroll}>
      <View style={styles.header}>
        <Text style={styles.title}>Reader</Text>
        <View style={styles.chip}>
          <View style={styles.dot} />
          <Text style={styles.chipLabel}>{tokens.syncStatus.offline.label}</Text>
        </View>
      </View>
      <Text style={styles.heading}>Highlight spike</Text>
      <Text style={styles.caption}>Tap the first word, then the last.</Text>
      <Text style={styles.caption}>
        {sampleBook.fingerprint}
        {sampleBook.pdfId ? ` · pdf ${sampleBook.pdfId}` : ""}
      </Text>

      {pages.map((page) => (
        <View key={`${page.page}-${page.section}`} style={styles.card}>
          <Text style={styles.cardHeading}>{page.section}</Text>
          <Text style={styles.caption}>Page {page.page}</Text>
          <View style={styles.passage}>
            {wordSpans(page.text).map((span, index) => {
              const painted = paintFor(page, span.start, span.end, highlights);
              const selected =
                selection !== null &&
                selection.page === page.page &&
                index >= Math.min(selection.anchor, selection.focus) &&
                index <= Math.max(selection.anchor, selection.focus);
              return (
                <Pressable key={`${span.start}-${span.text}`} hitSlop={6} onPress={() => tapWord(page, index)}>
                  <Text
                    style={[
                      styles.word,
                      painted ? { backgroundColor: highlightPaint(colorHex(painted)) } : null,
                      selected ? styles.selectedWord : null,
                    ]}
                  >
                    {span.text}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      ))}

      {selectedQuote.length > 0 ? (
        <View style={styles.sheet}>
          <Text style={styles.quote}>“{selectedQuote}”</Text>
          <View style={styles.swatches}>
            {tokens.highlight.palette.map((swatch) => (
              <Pressable
                key={swatch.id}
                accessibilityLabel={`Highlight color ${swatch.id}`}
                onPress={() => applyColor(swatch.id)}
                style={[
                  styles.swatch,
                  { backgroundColor: swatch.hex },
                  lastColor === swatch.id ? styles.swatchOn : null,
                ]}
              />
            ))}
          </View>
        </View>
      ) : null}

      <Text style={styles.heading}>Records</Text>
      {highlights.map((highlight) => {
        const note = notes.find((item) => item.highlightId === highlight.id);
        const open = highlight.id === activeId;
        return (
          <Pressable
            key={highlight.id}
            onPress={() => {
              setActiveId(highlight.id);
              setDraft(note?.body ?? "");
            }}
            style={[styles.card, open ? styles.cardOn : null]}
          >
            <View style={styles.recordRow}>
              <View style={[styles.mark, { backgroundColor: colorHex(highlight.color) }]} />
              <Text style={styles.body}>{highlight.quote}</Text>
            </View>
            <Text style={styles.caption}>
              {highlight.id}
              {highlight.page ? ` · p. ${highlight.page}` : ""}
              {` · “${highlight.prefix}” + quote + “${highlight.suffix}”`}
            </Text>
            {note ? (
              <Text style={styles.noteBody}>
                {note.body}
                {"\n"}
                <Text style={styles.caption}>
                  Note {note.id} points at {note.highlightId}
                </Text>
              </Text>
            ) : (
              <Text style={styles.caption}>No note</Text>
            )}
          </Pressable>
        );
      })}

      {active ? (
        <View style={styles.sheet}>
          <Text style={styles.cardHeading}>Note on {active.id}</Text>
          <TextInput
            multiline
            onChangeText={setDraft}
            placeholder="Write a note…"
            style={styles.input}
            value={draft}
          />
          <View style={styles.actions}>
            <Pressable onPress={commitNote} style={styles.button}>
              <Text style={styles.buttonLabel}>
                {draft.trim().length === 0 && notes.some((note) => note.highlightId === active.id)
                  ? "Remove note"
                  : "Save note"}
              </Text>
            </Pressable>
            <Pressable
              onPress={() => {
                const next = removeHighlight(highlights, notes, active.id);
                setHighlights(next.highlights);
                setNotes(next.notes);
                setActiveId(next.highlights[0]?.id ?? "");
                setDraft(notes.find((note) => note.highlightId === next.highlights[0]?.id)?.body ?? "");
              }}
              style={styles.buttonSecondary}
            >
              <Text style={styles.buttonLabelDark}>Delete highlight</Text>
            </Pressable>
          </View>
        </View>
      ) : null}

      <Pressable onPress={reprint} style={styles.buttonSecondary}>
        <Text style={styles.buttonLabelDark}>Move chapter 4 and re-anchor</Text>
      </Pressable>
      {notice ? <Text style={styles.caption}>{notice}</Text> : null}
    </ScrollView>
  );
}

function paintFor(
  page: TextSlice,
  start: number,
  end: number,
  highlights: readonly HighlightRecord[],
): number | null {
  for (const highlight of highlights) {
    if (highlight.page !== page.page) continue;
    const hit = locate(highlight.quote, highlight.prefix, highlight.suffix, [page]);
    if (!hit) continue;
    if (start < hit.end && end > hit.start) return highlight.color;
  }
  return null;
}

const serif = Platform.select({ web: "Georgia, serif", default: "serif" });

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: tokens.canvas },
  content: {
    padding: tokens.space[3],
    gap: tokens.space[3],
    width: "100%",
    maxWidth: 520,
    alignSelf: "center",
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: tokens.space[2],
  },
  title: {
    color: tokens.ink,
    fontSize: tokens.type.title.size,
    fontWeight: tokens.type.title.weight,
    lineHeight: tokens.type.title.lineHeight,
  },
  heading: {
    color: tokens.ink,
    fontSize: tokens.type.heading.size,
    fontWeight: tokens.type.heading.weight,
    lineHeight: tokens.type.heading.lineHeight,
  },
  body: {
    flex: 1,
    color: tokens.ink,
    fontSize: tokens.type.body.size,
    lineHeight: tokens.type.body.lineHeight,
  },
  caption: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
  },
  quote: {
    color: tokens.ink,
    fontFamily: serif,
    fontSize: tokens.type.quote.size,
    lineHeight: tokens.type.quote.lineHeight,
  },
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: tokens.space[1],
    minHeight: tokens.touchTarget,
    paddingHorizontal: tokens.space[2],
    borderRadius: tokens.radius.chip,
    backgroundColor: tokens.paper,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: tokens.syncStatus.offline.dot,
  },
  chipLabel: {
    color: tokens.ink,
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
  },
  card: {
    backgroundColor: tokens.paper,
    borderRadius: tokens.radius.card,
    padding: tokens.space[3],
    gap: tokens.space[1],
  },
  cardOn: { borderWidth: 1, borderColor: tokens.ink },
  cardHeading: {
    color: tokens.ink,
    fontSize: tokens.type.heading.size,
    fontWeight: tokens.type.heading.weight,
    lineHeight: tokens.type.heading.lineHeight,
  },
  passage: { flexDirection: "row", flexWrap: "wrap", gap: tokens.space[1] },
  word: {
    color: tokens.ink,
    fontFamily: serif,
    fontSize: tokens.type.quote.size,
    lineHeight: tokens.type.quote.lineHeight,
    borderRadius: tokens.radius.highlightBar,
    overflow: "hidden",
  },
  selectedWord: { backgroundColor: tokens.selection },
  sheet: {
    backgroundColor: tokens.paper,
    borderRadius: tokens.radius.sheet,
    padding: tokens.space[3],
    gap: tokens.space[2],
  },
  swatches: { flexDirection: "row", flexWrap: "wrap", gap: tokens.space[2] },
  swatch: {
    width: tokens.touchTarget,
    height: tokens.touchTarget,
    borderRadius: tokens.touchTarget / 2,
  },
  swatchOn: { borderWidth: 3, borderColor: tokens.ink },
  recordRow: { flexDirection: "row", alignItems: "flex-start", gap: tokens.space[2] },
  mark: {
    width: 8,
    height: 22,
    borderRadius: tokens.radius.highlightBar,
    marginTop: 2,
  },
  noteBody: {
    color: tokens.ink,
    fontSize: tokens.type.body.size,
    lineHeight: tokens.type.body.lineHeight,
  },
  input: {
    minHeight: 88,
    borderWidth: 1,
    borderColor: tokens.line,
    borderRadius: tokens.radius.card,
    padding: tokens.space[2],
    color: tokens.ink,
    fontSize: tokens.type.body.size,
    lineHeight: tokens.type.body.lineHeight,
    textAlignVertical: "top",
  },
  actions: { flexDirection: "row", flexWrap: "wrap", gap: tokens.space[2] },
  button: {
    minHeight: tokens.touchTarget,
    paddingHorizontal: tokens.space[3],
    borderRadius: tokens.radius.card,
    backgroundColor: tokens.ink,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonSecondary: {
    minHeight: tokens.touchTarget,
    paddingHorizontal: tokens.space[3],
    borderRadius: tokens.radius.card,
    backgroundColor: tokens.paper,
    borderWidth: 1,
    borderColor: tokens.line,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonLabel: { color: tokens.paper, fontSize: tokens.type.body.size, fontWeight: "600" },
  buttonLabelDark: { color: tokens.ink, fontSize: tokens.type.body.size, fontWeight: "600" },
});
