import { useEffect, useRef, useState, type ComponentType, type Ref } from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  ActivityIndicator,
  BackHandler,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import WebView, { type WebViewMessageEvent, type WebViewProps } from "react-native-webview";
import type { HighlightRecord } from "../contract/types";
import { captureAnchor } from "../highlight/selection";
import { normalizeEpubSection } from "../highlight/epubSection";
import { addHighlight, persistReanchoredHighlight, removeHighlight, saveNote } from "../highlight/store";
import { parseViewerMessage } from "../reader/bridge";
import { SHOW_HIGHLIGHT_HARNESS } from "./devFlags";
import type { HostToViewer, ViewerHighlight } from "../reader/bridge";
import { File } from "expo-file-system";
import { readAssetBase64, viewerRoot } from "../reader/installViewer";
import { epubBook, epubModule, pdfBook, pdfModule, sampleTitles } from "../reader/samples";
import { emptyShelf, parseShelf, serializeShelf, shelfKey } from "../reader/shelf";
import type { BookShelf } from "../reader/shelf";
import { makeId } from "../reader/ids";
import { SyncChrome } from "../sync/SyncStatusChip";
import type { SyncStatus } from "../sync/status";
import type { OpenConflict } from "../sync/wire";
import { tokens } from "./tokens";

const idleSync: SyncStatus = {
  state: "synced",
  pendingCount: 0,
  conflictCount: 0,
  pausedBookIds: [],
  lastSyncedAt: null,
};

type Format = "pdf" | "epub";

function sectionIndex(section: string | undefined): number {
  if (!section) return 0;
  const match = /chapter\s+(\d+)/i.exec(section);
  if (match) return Math.max(0, Number(match[1]) - 1);
  return 0;
}

function hexFor(color: number): string {
  return tokens.highlight.palette.find((swatch) => swatch.id === color)?.hex ?? "#F2C94C";
}

function toViewer(highlight: HighlightRecord): ViewerHighlight {
  return {
    id: highlight.id,
    color: highlight.color,
    hex: hexFor(highlight.color),
    opacity: tokens.highlight.opacity,
    quote: highlight.quote,
    prefix: highlight.prefix,
    suffix: highlight.suffix,
    page: highlight.page,
    cfi: highlight.cfi,
    section: highlight.section,
    rects: highlight.rects,
  };
}

export function ReaderHome({
  sync = idleSync,
  conflicts = [],
  onCheckAgain,
  onRetry,
}: {
  sync?: SyncStatus;
  conflicts?: readonly OpenConflict[];
  onCheckAgain?: () => void;
  onRetry?: () => void;
} = {}) {
  const [format, setFormat] = useState<Format | null>(null);
  if (!format) {
    return (
      <View style={styles.home}>
        <View style={styles.header}>
          <Text style={styles.title}>Reader</Text>
          <SyncChrome status={sync} conflicts={conflicts} onCheckAgain={onCheckAgain} onRetry={onRetry} />
        </View>
        <Text style={styles.heading}>Highlight</Text>
        <Text style={styles.caption}>
          Long-press a word. It is highlighted in the last color, then the sheet can change the color, add a note, or remove it.
        </Text>
        <Pressable testID="library-pdf" onPress={() => setFormat("pdf")} style={styles.card}>
          <Text style={styles.cardHeading}>{sampleTitles.pdf}</Text>
          <Text style={styles.caption}>PDF · text layer · {pdfBook.fingerprint}</Text>
          {sync.pausedBookIds.includes(pdfBook.fingerprint) ? (
            <Text>{tokens.syncStatus.storageFull.badge}</Text>
          ) : null}
        </Pressable>
        <Pressable testID="library-epub" onPress={() => setFormat("epub")} style={styles.card}>
          <Text style={styles.cardHeading}>{sampleTitles.epub}</Text>
          <Text style={styles.caption}>EPUB · foliate-js · {epubBook.epubId}</Text>
          {sync.pausedBookIds.includes(epubBook.fingerprint) ? (
            <Text>{tokens.syncStatus.storageFull.badge}</Text>
          ) : null}
        </Pressable>
      </View>
    );
  }
  return <BookReader key={format} format={format} onBack={() => setFormat(null)} />;
}

function BookReader({ format, onBack }: { format: Format; onBack: () => void }) {
  const book = format === "pdf" ? pdfBook : epubBook;
  const webRef = useRef<ReaderWebHandle>(null);
  const shelfRef = useRef<BookShelf>(emptyShelf());
  const [shelf, setShelf] = useState<BookShelf>(emptyShelf());
  const [uri, setUri] = useState<string | null>(null);
  const [base64, setBase64] = useState<string | null>(null);
  const [workerSource, setWorkerSource] = useState<string | null>(null);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const active = shelf.highlights.find((highlight) => highlight.id === activeId) ?? null;
  const activeNote = shelf.notes.find((note) => note.id === active?.id);

  function send(message: HostToViewer) {
    const payload = JSON.stringify(message);
    webRef.current?.injectJavaScript(`window.__hostMessage(${JSON.stringify(payload)}); true;`);
  }

  async function commit(next: BookShelf) {
    shelfRef.current = next;
    setShelf(next);
    await AsyncStorage.setItem(shelfKey(book.fingerprint), serializeShelf(next));
  }

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const saved = parseShelf(await AsyncStorage.getItem(shelfKey(book.fingerprint)));
        const root = await viewerRoot();
        const encoded = await readAssetBase64(format === "pdf" ? pdfModule : epubModule);
        const worker =
          format === "pdf" ? await new File(root, "pdfjs", "pdf.worker.min.mjs").text() : null;
        if (cancelled) return;
        shelfRef.current = saved;
        setShelf(saved);
        setBase64(encoded);
        setWorkerSource(worker);
        setUri(fileUri(root.uri, format === "pdf" ? "pdf.html" : "epub.html"));
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [book.fingerprint, format]);

  function openSheet(id: string, notes = shelfRef.current.notes) {
    setActiveId(id);
    setDraft(notes.find((note) => note.id === id)?.body ?? "");
  }

  function dismissSheet() {
    setActiveId(null);
    setDraft("");
  }

  useEffect(() => {
    const subscription = BackHandler.addEventListener("hardwareBackPress", () => {
      if (activeId) {
        dismissSheet();
        return true;
      }
      onBack();
      return true;
    });
    return () => subscription.remove();
  }, [activeId, onBack]);

  function onViewerMessage(raw: string) {
    const message = parseViewerMessage(raw);
    if (!message) return;
    if (message.type === "ready") {
      if (!base64) return;
      if (format === "pdf") {
        if (!workerSource) return;
        send({ type: "open-pdf", base64, workerSource });
      } else {
        send({ type: "open-epub", base64 });
      }
      return;
    }
    if (message.type === "corpus") {
      send({ type: "restore", highlights: shelfRef.current.highlights.map(toViewer) });
      return;
    }
    if (message.type === "error") {
      setError(message.message);
      return;
    }
    if (message.type === "selection") {
      const anchor = captureAnchor(
        message.before + message.quote + message.after,
        message.before.length,
        message.before.length + message.quote.length,
        message.page,
        format === "epub" ? normalizeEpubSection(message.section, sectionIndex(message.section)) : message.section,
      );
      if (!anchor.quote.trim()) return;
      const color = shelfRef.current.lastColor;
      const added = addHighlight(
        shelfRef.current.highlights,
        { ...anchor, cfi: message.cfi, rects: message.rects },
        color,
        makeId("h"),
      );
      const next = { ...shelfRef.current, highlights: added.highlights, lastColor: color };
      void commit(next);
      if (added.entry) {
        send({ type: "paint", highlight: toViewer(added.entry) });
        openSheet(added.entry.id, next.notes);
        setNotice(null);
      }
      return;
    }
    if (message.type === "open-highlight") {
      if (shelfRef.current.highlights.some((highlight) => highlight.id === message.id)) {
        openSheet(message.id);
        setNotice(null);
      }
      return;
    }
    if (message.type === "located") {
      const persisted = persistReanchoredHighlight(
        shelfRef.current.highlights,
        shelfRef.current.notes,
        message,
      );
      if (!persisted) return;
      if (!message.found) {
        setNotice("The quote was not found.");
        return;
      }
      const updated = persisted.highlights.find((highlight) => highlight.id === message.id);
      void commit({ ...shelfRef.current, highlights: persisted.highlights, notes: persisted.notes });
      if (updated) send({ type: "paint", highlight: toViewer(updated) });
      if (message.reason !== "restore") {
        setNotice(format === "pdf" ? `Re-anchored on page ${updated?.page ?? "?"}` : "Re-anchored by quote");
      }
    }
  }

  function chooseColor(color: number) {
    if (!active) return;
    const highlights = shelf.highlights.map((highlight) =>
      highlight.id === active.id ? { ...highlight, color } : highlight,
    );
    const next = { ...shelf, highlights, lastColor: color };
    void commit(next);
    const updated = highlights.find((highlight) => highlight.id === active.id);
    if (updated) send({ type: "paint", highlight: toViewer(updated) });
  }

  function saveActiveNote() {
    if (!active) return;
    const saved = saveNote(shelf.highlights, shelf.notes, active.id, draft, new Date().toISOString());
    if (!saved) return;
    void commit({ ...shelf, highlights: saved.highlights, notes: saved.notes });
    setNotice(draft.trim() ? "Note saved as its own record" : "Note removed");
  }

  function removeActive() {
    if (!active) return;
    const removed = removeHighlight(shelf.highlights, shelf.notes, active.id);
    void commit({ ...shelf, highlights: removed.highlights, notes: removed.notes });
    send({ type: "remove", id: active.id });
    setActiveId(null);
    setDraft("");
  }

  function scramble() {
    if (!active) return;
    const highlights = shelf.highlights.map((highlight) =>
      highlight.id === active.id
        ? {
            ...highlight,
            page: format === "pdf" ? 99 : highlight.page,
            cfi: format === "epub" ? "epubcfi(/6/98!/4,/1:0,/1:1)" : highlight.cfi,
          }
        : highlight,
    );
    void commit({ ...shelf, highlights });
    setNotice("Hint scrambled. Re-anchor by quote to find the passage again.");
  }

  function reanchor() {
    if (!active) return;
    send({
      type: "locate",
      id: active.id,
      quote: active.quote,
      prefix: active.prefix,
      suffix: active.suffix,
    });
  }

  return (
    <View style={styles.reader}>
      <View style={styles.header}>
        <Pressable testID="reader-library" onPress={onBack} style={styles.back}>
          <Text style={styles.buttonLabelDark}>Library</Text>
        </Pressable>
        <Text style={styles.cardHeading}>{format === "pdf" ? "PDF" : "EPUB"}</Text>
      </View>
      <Text style={styles.caption}>Long-press a word. Color {shelf.lastColor} is applied at once.</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <View style={styles.surface}>
        {uri && base64 && (format === "epub" || workerSource) ? (
          <ReaderWeb
            testID="reader-surface"
            style={styles.web}
            originWhitelist={["*"]}
            source={{ uri }}
            allowFileAccess
            allowFileAccessFromFileURLs
            allowUniversalAccessFromFileURLs
            allowingReadAccessToURL={uri.slice(0, uri.lastIndexOf("/") + 1)}
            onMessage={(event: WebViewMessageEvent) => onViewerMessage(event.nativeEvent.data)}
            ref={webRef}
          />
        ) : (
          <ActivityIndicator style={styles.spinner} />
        )}
        {notice ? <Text style={styles.notice}>{notice}</Text> : null}
        {active ? (
          <View style={styles.sheetOverlay} pointerEvents="box-none">
            <Pressable
              testID="highlight-sheet-backdrop"
              accessibilityLabel="Dismiss highlight sheet"
              onPress={dismissSheet}
              style={styles.backdrop}
            />
            <View testID="highlight-sheet" style={styles.sheet}>
              <View style={styles.handle} accessibilityLabel="Dismiss handle" />
              <Text style={styles.cardHeading}>Highlight</Text>
              <Text style={styles.quote}>“{active.quote}”</Text>
              <Text style={styles.sheetCaption}>
                {active.page ? `Page ${active.page}` : active.section ? active.section : "No location hint"}
                {activeNote ? " · note attached" : ""}
              </Text>
              <View style={styles.swatches}>
                {tokens.highlight.palette.map((swatch) => (
                  <Pressable
                    key={swatch.id}
                    accessibilityLabel={`Highlight color ${swatch.id}`}
                    testID={`highlight-color-${swatch.id}`}
                    onPress={() => chooseColor(swatch.id)}
                    style={[
                      styles.swatch,
                      { backgroundColor: swatch.hex },
                      active.color === swatch.id ? styles.swatchOn : null,
                    ]}
                  />
                ))}
              </View>
              <TextInput
                multiline
                onChangeText={setDraft}
                placeholder="Write a note…"
                style={styles.input}
                value={draft}
              />
              <View style={styles.actions}>
                <Pressable onPress={saveActiveNote} style={styles.button}>
                  <Text style={styles.buttonLabel}>
                    {draft.trim().length === 0 && activeNote ? "Remove note" : "Save note"}
                  </Text>
                </Pressable>
                <Pressable testID="remove-highlight" onPress={removeActive} style={styles.buttonSecondary}>
                  <Text style={styles.buttonLabelDark}>Remove highlight</Text>
                </Pressable>
                {SHOW_HIGHLIGHT_HARNESS ? (
                  <>
                    <Pressable onPress={scramble} style={styles.buttonSecondary}>
                      <Text style={styles.buttonLabelDark}>Scramble hint</Text>
                    </Pressable>
                    <Pressable onPress={reanchor} style={styles.buttonSecondary}>
                      <Text style={styles.buttonLabelDark}>Re-anchor by quote</Text>
                    </Pressable>
                  </>
                ) : null}
              </View>
            </View>
          </View>
        ) : null}
      </View>
    </View>
  );
}

type ReaderWebHandle = { injectJavaScript: (script: string) => void };

const ReaderWeb = WebView as unknown as ComponentType<WebViewProps & { ref?: Ref<ReaderWebHandle> }>;

function fileUri(directoryUri: string, name: string): string {
  return directoryUri.endsWith("/") ? directoryUri + name : `${directoryUri}/${name}`;
}

const styles = StyleSheet.create({
  home: { flex: 1, padding: tokens.space[3], gap: tokens.space[3], backgroundColor: tokens.canvas },
  reader: { flex: 1, backgroundColor: tokens.canvas },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: tokens.space[2],
    paddingHorizontal: tokens.space[3],
    paddingTop: tokens.space[2],
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
  cardHeading: {
    color: tokens.ink,
    fontSize: tokens.type.heading.size,
    fontWeight: tokens.type.heading.weight,
    lineHeight: tokens.type.heading.lineHeight,
  },
  caption: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
    paddingHorizontal: tokens.space[3],
  },
  quote: { color: tokens.ink, fontSize: tokens.type.quote.size, lineHeight: tokens.type.quote.lineHeight },
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: tokens.space[1],
    minHeight: tokens.touchTarget,
    paddingHorizontal: tokens.space[2],
    borderRadius: tokens.radius.chip,
    backgroundColor: tokens.paper,
  },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: tokens.syncStatus.offline.dot },
  chipLabel: { color: tokens.ink, fontSize: tokens.type.caption.size },
  card: {
    backgroundColor: tokens.paper,
    borderRadius: tokens.radius.card,
    padding: tokens.space[3],
    gap: tokens.space[1],
  },
  web: { flex: 1, backgroundColor: tokens.canvas },
  spinner: { marginTop: tokens.space[5] },
  error: { color: "#EB5757", paddingHorizontal: tokens.space[3] },
  surface: { flex: 1 },
  notice: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
    paddingHorizontal: tokens.space[3],
  },
  sheetOverlay: {
    ...StyleSheet.absoluteFill,
    justifyContent: "flex-end",
  },
  backdrop: { flex: 1, backgroundColor: "rgba(0, 0, 0, 0.2)" },
  sheet: {
    backgroundColor: tokens.paper,
    borderTopLeftRadius: tokens.radius.sheet,
    borderTopRightRadius: tokens.radius.sheet,
    padding: tokens.space[3],
    gap: tokens.space[2],
  },
  handle: {
    alignSelf: "center",
    width: 36,
    height: 5,
    borderRadius: 3,
    backgroundColor: tokens.line,
    marginBottom: tokens.space[1],
  },
  sheetCaption: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
    textAlign: "left",
  },
  swatches: { flexDirection: "row", flexWrap: "wrap", gap: tokens.space[2] },
  swatch: { width: tokens.touchTarget, height: tokens.touchTarget, borderRadius: tokens.touchTarget / 2 },
  swatchOn: { borderWidth: 3, borderColor: tokens.ink },
  input: {
    minHeight: 72,
    borderWidth: 1,
    borderColor: tokens.line,
    borderRadius: tokens.radius.card,
    padding: tokens.space[2],
    color: tokens.ink,
    fontSize: tokens.type.body.size,
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
  back: {
    minHeight: tokens.touchTarget,
    justifyContent: "center",
    paddingRight: tokens.space[2],
  },
});
