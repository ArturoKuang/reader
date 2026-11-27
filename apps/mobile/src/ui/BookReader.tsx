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
import { useSafeAreaInsets } from "react-native-safe-area-context";
import WebView, { type WebViewMessageEvent, type WebViewProps } from "react-native-webview";
import type { HighlightRecord } from "../contract/types";
import { captureAnchor } from "../highlight/selection";
import { normalizeEpubSection } from "../highlight/epubSection";
import { addHighlight, autoReanchorOnOpen, persistReanchoredHighlight, removeHighlight, saveNote } from "../highlight/store";
import { parseViewerMessage } from "../reader/bridge";
import { SHOW_HIGHLIGHT_HARNESS } from "./devFlags";
import type { HostToViewer, ViewerHighlight } from "../reader/bridge";
import { File } from "expo-file-system";
import { viewerRoot } from "../reader/installViewer";
import { emptyShelf, parseShelf, serializeShelf, shelfKey } from "../reader/shelf";
import type { BookShelf } from "../reader/shelf";
import { makeId } from "../reader/ids";
import { parseProgress, progressKey, serializeProgress, type BookProgress } from "../library/progress";
import type { LibraryBook } from "../library/catalog";
import { epubChapterKey } from "../sync/engine";
import { useSync } from "../sync/SyncProvider";
import { SyncStatusChip } from "../sync/SyncStatusChip";
import { unpairedStatus } from "../sync/controller";
import type { Locator } from "../sync/wire";
import { tokens } from "./tokens";
import type { JumpTo } from "./navigation";
import { PositionToast } from "./ResumeToast";
import { resumeLocator, toastFromOffer, type PositionToastView } from "./resumeOffer";

function byteLengthFromBase64(base64: string): number {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}

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

function nowMs(): number {
  return Date.now();
}

function fileUri(directoryUri: string, name: string): string {
  return directoryUri.endsWith("/") ? directoryUri + name : `${directoryUri}/${name}`;
}

export function BookReader({
  book,
  loadBase64,
  onBack,
  onOpenNotebook,
  jumpTo,
}: {
  book: LibraryBook;
  loadBase64: () => Promise<string>;
  onBack: () => void;
  onOpenNotebook: () => void;
  jumpTo?: JumpTo;
}) {
  const sync = useSync();
  const syncRef = useRef(sync);
  const insets = useSafeAreaInsets();
  const webRef = useRef<ReaderWebHandle>(null);
  const shelfRef = useRef<BookShelf>(emptyShelf());
  const bookBytesRef = useRef(book.size);
  const jumpRef = useRef(jumpTo);
  const progressRef = useRef<BookProgress | null>(null);
  const openedRef = useRef(false);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [shelf, setShelf] = useState<BookShelf>(emptyShelf());
  const [uri, setUri] = useState<string | null>(null);
  const [base64, setBase64] = useState<string | null>(null);
  const [workerSource, setWorkerSource] = useState<string | null>(null);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<PositionToastView | null>(null);
  const [location, setLocation] = useState<{ page?: number; pageCount?: number; section?: string; cfi?: string }>({});

  const active = shelf.highlights.find((highlight) => highlight.id === activeId) ?? null;
  const activeNote = shelf.notes.find((note) => note.id === active?.id);
  const status = sync?.status ?? unpairedStatus;

  function send(message: HostToViewer) {
    const payload = JSON.stringify(message);
    webRef.current?.injectJavaScript(`window.__hostMessage(${JSON.stringify(payload)}); true;`);
  }

  function gotoLocator(locator: Locator) {
    if (locator.format === "pdf") send({ type: "goto", page: locator.page });
    else send({ type: "goto", cfi: locator.cfi });
  }

  async function publishShelf(previous: BookShelf, next: BookShelf) {
    if (!sync) return;
    const bookId = book.fingerprint;
    await sync.ensureBook({
      sha256: book.sha256,
      size: bookBytesRef.current || book.size,
      format: book.format,
      docId: book.docId,
      title: book.title,
      filename: book.filename,
    });
    const previousIds = new Set(previous.highlights.map((highlight) => highlight.id));
    const nextIds = new Set(next.highlights.map((highlight) => highlight.id));
    for (const id of previousIds) {
      if (!nextIds.has(id)) await sync.deleteHighlight(bookId, id);
    }
    const previousNotes = new Set(previous.notes.map((note) => note.id));
    const nextNotes = new Set(next.notes.map((note) => note.id));
    for (const id of previousNotes) {
      if (!nextNotes.has(id) && nextIds.has(id)) await sync.deleteNote(bookId, id);
    }
    for (const highlight of next.highlights) await sync.putHighlight(bookId, highlight);
    for (const note of next.notes) await sync.putNote(bookId, note);
  }

  async function commit(next: BookShelf, options?: { skipSync?: boolean }) {
    const previous = shelfRef.current;
    shelfRef.current = next;
    setShelf(next);
    await AsyncStorage.setItem(shelfKey(book.fingerprint), serializeShelf(next));
    if (!options?.skipSync) await publishShelf(previous, next);
  }

  async function persistProgress(update: Omit<BookProgress, "updatedAt">, locator?: Locator) {
    const next = { ...progressRef.current, ...update, updatedAt: nowMs() };
    progressRef.current = next;
    await AsyncStorage.setItem(progressKey(book.fingerprint), serializeProgress(next));
    if (locator) syncRef.current?.updatePosition(book.fingerprint, locator);
  }

  useEffect(() => {
    syncRef.current = sync;
  }, [sync]);

  useEffect(() => {
    jumpRef.current = jumpTo;
  }, [jumpTo]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const loaded = parseShelf(await AsyncStorage.getItem(shelfKey(book.fingerprint)));
        const saved = syncRef.current?.mergeShelf(loaded, book.fingerprint) ?? loaded;
        const progress = parseProgress(await AsyncStorage.getItem(progressKey(book.fingerprint)));
        const root = await viewerRoot();
        const encoded = await loadBase64();
        const worker = book.format === "pdf" ? await new File(root, "pdfjs", "pdf.worker.min.mjs").text() : null;
        if (cancelled) return;
        bookBytesRef.current = byteLengthFromBase64(encoded);
        shelfRef.current = saved;
        progressRef.current = progress;
        setShelf(saved);
        setBase64(encoded);
        setWorkerSource(worker);
        setUri(fileUri(root.uri, book.format === "pdf" ? "pdf.html" : "epub.html"));
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [book.fingerprint, book.format, loadBase64]);

  useEffect(() => {
    const controller = syncRef.current;
    if (!controller) return;
    const merged = controller.mergeShelf(shelfRef.current, book.fingerprint);
    if (serializeShelf(merged) === serializeShelf(shelfRef.current)) return;
    void (async () => {
      shelfRef.current = merged;
      setShelf(merged);
      await AsyncStorage.setItem(shelfKey(book.fingerprint), serializeShelf(merged));
      const payload = JSON.stringify({ type: "restore", highlights: merged.highlights.map(toViewer) });
      webRef.current?.injectJavaScript(`window.__hostMessage(${JSON.stringify(payload)}); true;`);
    })();
  }, [book.fingerprint, sync, sync?.isPaired, sync?.status.lastSyncedAt]);

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

  useEffect(() => {
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, []);

  function showToast(view: PositionToastView) {
    setToast(view);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), view.durationMs);
  }

  function applyJump(target: JumpTo | undefined) {
    if (!target) return;
    const highlight = target.highlightId
      ? shelfRef.current.highlights.find((item) => item.id === target.highlightId)
      : undefined;
    if (highlight?.page) send({ type: "goto", page: highlight.page });
    else if (highlight?.cfi) send({ type: "goto", cfi: highlight.cfi });
    else if (target.locator) gotoLocator(target.locator);
    if (highlight) openSheet(highlight.id);
  }

  async function applyResume() {
    if (openedRef.current) return;
    openedRef.current = true;
    const target = jumpRef.current;
    if (target?.highlightId || target?.locator) {
      applyJump(target);
      return;
    }
    const controller = syncRef.current;
    const saved = progressRef.current;
    const here =
      book.format === "pdf"
        ? { page: saved?.page }
        : { chapterKey: saved?.chapterKey };
    const offer = controller ? await controller.openBook(book.fingerprint, here) : null;
    const locator = resumeLocator(offer);
    if (locator) {
      gotoLocator(locator);
      if (locator.format === "pdf") {
        void persistProgress({ page: locator.page });
      } else {
        void persistProgress({ chapterKey: epubChapterKey(locator.cfi), progression: locator.progression });
      }
    }
    const view = toastFromOffer(offer);
    if (view) showToast(view);
  }

  function onViewerMessage(raw: string) {
    const message = parseViewerMessage(raw);
    if (!message) return;
    if (message.type === "ready") {
      if (!base64) return;
      if (book.format === "pdf") {
        if (!workerSource) return;
        send({ type: "open-pdf", base64, workerSource });
      } else {
        send({ type: "open-epub", base64 });
      }
      return;
    }
    if (message.type === "corpus") {
      const current = shelfRef.current;
      const restored = autoReanchorOnOpen(current.highlights, current.notes, message.slices);
      const next =
        restored.reanchoredIds.length > 0
          ? { ...current, highlights: restored.highlights, notes: restored.notes }
          : current;
      if (restored.reanchoredIds.length > 0) void commit(next);
      send({ type: "restore", highlights: next.highlights.map(toViewer) });
      void applyResume();
      return;
    }
    if (message.type === "location") {
      setLocation({
        page: message.page,
        pageCount: message.pageCount,
        section: message.section,
        cfi: message.cfi,
      });
      if (message.format === "pdf" && typeof message.page === "number") {
        void persistProgress(
          { page: message.page, pageCount: message.pageCount },
          { format: "pdf", page: message.page },
        );
      } else if (message.format === "epub" && typeof message.cfi === "string") {
        void persistProgress(
          { chapterKey: epubChapterKey(message.cfi), progression: message.progression },
          { format: "epub", cfi: message.cfi, progression: message.progression },
        );
      }
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
        book.format === "epub" ? normalizeEpubSection(message.section, sectionIndex(message.section)) : message.section,
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
        setNotice(book.format === "pdf" ? `Re-anchored on page ${updated?.page ?? "?"}` : "Re-anchored by quote");
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
            page: book.format === "pdf" ? 99 : highlight.page,
            cfi: book.format === "epub" ? "epubcfi(/6/98!/4,/1:0,/1:1)" : highlight.cfi,
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

  const pageLabel =
    book.format === "pdf" && location.page
      ? location.pageCount
        ? `p. ${location.page} of ${location.pageCount}`
        : `p. ${location.page}`
      : location.section || (book.format === "epub" ? "EPUB" : book.format.toUpperCase());

  return (
    <View style={styles.reader}>
      <View style={styles.header}>
        <Pressable testID="reader-library" accessibilityLabel="Library" onPress={onBack} style={styles.back}>
          <Text style={styles.buttonLabelDark}>‹</Text>
        </Pressable>
        <Text style={styles.readerTitle} numberOfLines={1}>
          {book.title}
        </Text>
        <Pressable testID="reader-notebook" accessibilityLabel="Notebook" onPress={onOpenNotebook} style={styles.back}>
          <Text style={styles.notebookLabel}>Notebook</Text>
        </Pressable>
        <SyncStatusChip status={status} />
      </View>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <View style={styles.surface}>
        {uri && base64 && (book.format === "epub" || workerSource) ? (
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
        <Text style={[styles.pageLabel, { bottom: insets.bottom + 8 }]} testID="reader-position">
          {pageLabel}
        </Text>
        {toast ? (
          <PositionToast
            toast={toast}
            onAction={() => {
              gotoLocator(toast.locator);
              setToast(null);
            }}
            onDismiss={() => setToast(null)}
          />
        ) : null}
        {active ? (
          <View style={styles.sheetOverlay} pointerEvents="box-none">
            <Pressable
              testID="highlight-sheet-backdrop"
              accessibilityLabel="Dismiss highlight sheet"
              onPress={dismissSheet}
              style={styles.backdrop}
            />
            <View testID="highlight-sheet" style={[styles.sheet, { paddingBottom: insets.bottom + 12 }]}>
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
                    accessibilityLabel={swatch.name}
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

const styles = StyleSheet.create({
  reader: { flex: 1, backgroundColor: tokens.canvas },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: tokens.line,
  },
  readerTitle: {
    flex: 1,
    minWidth: 0,
    color: tokens.ink,
    fontSize: 15,
    fontWeight: "600",
  },
  notebookLabel: { color: tokens.ink, fontSize: 13, fontWeight: "600" },
  cardHeading: {
    color: tokens.ink,
    fontSize: tokens.type.heading.size,
    fontWeight: tokens.type.heading.weight,
    lineHeight: tokens.type.heading.lineHeight,
  },
  quote: { color: tokens.ink, fontSize: tokens.type.quote.size, lineHeight: tokens.type.quote.lineHeight },
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
  pageLabel: {
    position: "absolute",
    left: 0,
    right: 0,
    textAlign: "center",
    fontSize: 12,
    color: "#8E8E93",
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
  buttonLabelDark: { color: tokens.ink, fontSize: 18, fontWeight: "600" },
  back: {
    minHeight: tokens.touchTarget,
    minWidth: tokens.touchTarget,
    justifyContent: "center",
    alignItems: "center",
  },
});
