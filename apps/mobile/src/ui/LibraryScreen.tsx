import { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { buildLibrary, librarySubtitle, type LibraryBook, type LibraryCounts } from "../library/catalog";
import { parseProgress, progressKey, type BookProgress } from "../library/progress";
import { sampleBooks } from "../library/samples";
import { cachedShaSet } from "../reader/bookCache";
import { parseShelf, shelfKey } from "../reader/shelf";
import { useSync } from "../sync/SyncProvider";
import { SyncChrome } from "../sync/SyncStatusChip";
import { highlightFromPayload, noteFromPayload, unpairedStatus } from "../sync";
import type { OpenConflict } from "../sync/wire";
import { tokens } from "./tokens";

export function LibraryScreen({
  onOpenBook,
  onOpenConflict,
  downloadingId,
}: {
  onOpenBook: (book: LibraryBook) => void;
  onOpenConflict?: (conflict: OpenConflict, book: LibraryBook) => void;
  downloadingId?: string | null;
}) {
  const sync = useSync();
  const insets = useSafeAreaInsets();
  const status = sync?.status ?? unpairedStatus;
  const [books, setBooks] = useState<LibraryBook[]>([]);
  const [refreshing, setRefreshing] = useState(false);

  const rebuild = useCallback(async () => {
    const remote = sync?.books ?? [];
    const fingerprints = new Set<string>([
      ...sampleBooks.map((sample) => sample.fingerprint),
      ...remote.map((item) => item.bookId),
    ]);
    const counts: Record<string, LibraryCounts> = {};
    const progress: Record<string, BookProgress | null> = {};
    for (const id of fingerprints) {
      const shelf = parseShelf(await AsyncStorage.getItem(shelfKey(id)));
      const merged = sync?.mergeShelf(shelf, id) ?? shelf;
      const records = sync?.recordsFor(id) ?? [];
      const highlightIds = new Set(merged.highlights.map((highlight) => highlight.id));
      const noteIds = new Set(merged.notes.map((note) => note.id));
      for (const record of records) {
        if (record.deleted) continue;
        if (record.kind === "highlight" && highlightFromPayload(record.id, record.payload)) highlightIds.add(record.id);
        if (record.kind === "note" && noteFromPayload(record.id, record.payload)?.body.trim()) noteIds.add(record.id);
      }
      counts[id] = { highlights: highlightIds.size, notes: noteIds.size };
      progress[id] = parseProgress(await AsyncStorage.getItem(progressKey(id)));
    }
    const cached = cachedShaSet([
      ...sampleBooks.map((sample) => ({ sha256: sample.sha256, format: sample.format })),
      ...remote.map((item) => ({
        sha256: item.sha256,
        format: item.format.toLowerCase() === "epub" ? ("epub" as const) : ("pdf" as const),
      })),
    ]);
    for (const sample of sampleBooks) cached.add(sample.sha256);
    setBooks(
      buildLibrary({
        samples: sampleBooks,
        remote,
        pausedBookIds: status.pausedBookIds,
        counts,
        progress,
        cachedSha: cached,
      }),
    );
  }, [status.pausedBookIds, sync]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      await rebuild();
      void cancelled;
    })();
    return () => {
      cancelled = true;
    };
  }, [rebuild]);

  async function onRefresh() {
    setRefreshing(true);
    try {
      await sync?.syncNow();
      await sync?.refreshLibrary();
      await rebuild();
    } finally {
      setRefreshing(false);
    }
  }

  const emptyCaption =
    (sync?.isPaired ? books.every((book) => book.source === "sample") : true)
      ? "Your books will appear here after the first sync."
      : null;

  return (
    <View style={styles.screen} testID="library-screen">
      <View style={styles.header}>
        <Text style={styles.title}>Library</Text>
        <SyncChrome
          status={status}
          conflicts={sync?.conflicts ?? []}
          pairingError={sync?.pairingError}
          onCheckAgain={() => {
            void sync?.recheckStorage();
          }}
          onRetry={() => {
            void sync?.retryNow();
          }}
          onSyncNow={() => {
            void sync?.syncNow();
          }}
          onPair={(url) => {
            void sync?.pair(url);
          }}
          onUnpair={() => {
            void sync?.unpair();
          }}
          onOpenConflict={(conflict) => {
            const book = books.find((item) => item.id === conflict.bookId || item.fingerprint === conflict.bookId);
            if (book) onOpenConflict?.(conflict, book);
          }}
        />
      </View>
      <ScrollView
        testID="library-list"
        contentContainerStyle={[styles.list, { paddingBottom: Math.max(insets.bottom, 16) }]}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void onRefresh()} />}
      >
        {emptyCaption ? <Text style={styles.empty}>{emptyCaption}</Text> : null}
        {books.map((book) => {
          const downloading = downloadingId === book.id;
          const ratio = book.progress ?? 0;
          return (
            <Pressable
              key={book.id}
              testID={book.testID ?? `library-book-${book.id}`}
              onPress={() => onOpenBook(book)}
              style={styles.row}
            >
              <View style={styles.cover} />
              <View style={styles.meta}>
                <Text style={styles.heading}>{book.title}</Text>
                <Text style={styles.caption}>{librarySubtitle(book)}</Text>
                {book.waitingForSpace ? (
                  <Text style={styles.badge}>{tokens.syncStatus.storageFull.badge}</Text>
                ) : null}
                {book.cached && book.progress !== null ? (
                  <View style={styles.track}>
                    <View style={[styles.fill, { width: `${Math.round(ratio * 100)}%` }]} />
                  </View>
                ) : null}
                {downloading ? <ActivityIndicator style={styles.spinner} /> : null}
              </View>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.canvas },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: tokens.space[2],
    paddingHorizontal: 14,
    paddingTop: tokens.space[2],
    paddingBottom: tokens.space[2],
    borderBottomWidth: 1,
    borderBottomColor: tokens.line,
  },
  title: {
    color: tokens.ink,
    fontSize: tokens.type.title.size,
    fontWeight: tokens.type.title.weight,
    lineHeight: tokens.type.title.lineHeight,
    flex: 1,
  },
  list: { paddingBottom: tokens.space[4] },
  empty: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
    paddingHorizontal: 14,
    paddingTop: tokens.space[3],
  },
  row: {
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: tokens.line,
    minHeight: tokens.touchTarget,
  },
  cover: {
    width: 44,
    height: 60,
    borderRadius: 4,
    backgroundColor: tokens.line,
  },
  meta: { flex: 1, minWidth: 0 },
  heading: {
    color: tokens.ink,
    fontSize: 15,
    fontWeight: "600",
  },
  caption: {
    color: "#636366",
    fontSize: 12,
    marginTop: 4,
  },
  badge: { color: tokens.syncStatus.storageFull.dot, fontSize: 12, marginTop: 4, fontWeight: "600" },
  track: { height: 3, borderRadius: 2, backgroundColor: tokens.line, marginTop: 6, overflow: "hidden" },
  fill: { height: 3, borderRadius: 2, backgroundColor: tokens.accent },
  spinner: { marginTop: 8, alignSelf: "flex-start" },
});
