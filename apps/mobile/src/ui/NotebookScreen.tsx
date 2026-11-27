import { useEffect, useMemo, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import type { LibraryBook } from "../library/catalog";
import { buildNotebookItems, filterNotebook, notebookCounts, type NotebookItem, type NotebookTab } from "../notebook/items";
import { parseShelf, shelfKey } from "../reader/shelf";
import { ConflictCard } from "../sync/ConflictCard";
import { useSync } from "../sync/SyncProvider";
import { wordFromPayload } from "../sync/payload";
import type { WordRecord } from "../contract/types";
import { tokens } from "./tokens";
import type { JumpTo } from "./navigation";

const TABS: { id: NotebookTab; label: string }[] = [
  { id: "highlights", label: "Highlights" },
  { id: "notes", label: "Notes" },
  { id: "words", label: "Words" },
];

function wordsFromRecords(bookId: string, syncRecords: { kind: string; id: string; deleted: boolean; payload: import("../sync/wire").JsonObject }[]): WordRecord[] {
  const words = new Map<string, WordRecord>();
  for (const record of syncRecords) {
    if (record.kind !== "word" || record.deleted) continue;
    const word = wordFromPayload(record.id, record.payload);
    if (word) words.set(word.id, word);
  }
  void bookId;
  return [...words.values()];
}

export function NotebookScreen({
  book,
  onBack,
  onJump,
}: {
  book: LibraryBook;
  onBack: () => void;
  onJump: (jumpTo: JumpTo) => void;
}) {
  const sync = useSync();
  const insets = useSafeAreaInsets();
  const [items, setItems] = useState<NotebookItem[]>([]);
  const [tab, setTab] = useState<NotebookTab>("highlights");

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const loaded = parseShelf(await AsyncStorage.getItem(shelfKey(book.fingerprint)));
      const shelf = sync?.mergeShelf(loaded, book.fingerprint) ?? loaded;
      const records = sync?.recordsFor(book.fingerprint) ?? [];
      const conflicts = (sync?.conflicts ?? []).filter((conflict) => conflict.bookId === book.fingerprint || conflict.bookId === book.id);
      const built = buildNotebookItems({
        bookId: book.fingerprint,
        bookTitle: book.title,
        highlights: shelf.highlights,
        notes: shelf.notes,
        words: wordsFromRecords(book.fingerprint, records),
        conflicts,
      });
      if (!cancelled) setItems(built);
    })();
    return () => {
      cancelled = true;
    };
  }, [book.fingerprint, book.id, book.title, sync, sync?.isPaired, sync?.status.lastSyncedAt]);

  const counts = useMemo(() => notebookCounts(items), [items]);
  const visible = filterNotebook(items, tab);

  return (
    <View style={styles.screen} testID="notebook-screen">
      <View style={styles.header}>
        <Pressable testID="notebook-back" onPress={onBack} style={styles.back} accessibilityLabel="Back">
          <Text style={styles.backLabel}>‹</Text>
        </Pressable>
        <Text style={styles.title} numberOfLines={1}>
          {book.title}
        </Text>
      </View>
      <View style={styles.tabs}>
        {TABS.map((entry) => {
          const on = tab === entry.id;
          return (
            <Pressable
              key={entry.id}
              testID={`notebook-tab-${entry.id}`}
              onPress={() => setTab(entry.id)}
              style={[styles.tab, on ? styles.tabOn : null]}
            >
              <Text style={[styles.tabLabel, on ? styles.tabLabelOn : null]}>
                {entry.label} {counts[entry.id]}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <ScrollView contentContainerStyle={{ paddingBottom: Math.max(insets.bottom, 16) }}>
        {visible.length === 0 ? (
          <Text style={styles.empty}>Long-press text to highlight it.</Text>
        ) : (
          visible.map((item) => (
            <Pressable
              key={`${item.tab}-${item.id}`}
              testID={`notebook-item-${item.id}`}
              onPress={() =>
                onJump({
                  highlightId: item.tab === "words" ? undefined : item.id,
                  locator:
                    book.format === "pdf" && item.locationLabel.startsWith("p. ")
                      ? { format: "pdf", page: Number(item.locationLabel.slice(3)) }
                      : undefined,
                })
              }
              style={styles.row}
            >
              <View
                style={[
                  styles.bar,
                  { backgroundColor: tokens.highlight.palette.find((swatch) => swatch.id === item.color)?.hex ?? tokens.line },
                ]}
              />
              <View style={styles.body}>
                {item.conflict ? <ConflictCard conflict={item.conflict} /> : null}
                <Text style={styles.quote} numberOfLines={2}>
                  {item.quote}
                </Text>
                {item.note ? <Text style={styles.note}>{item.note}</Text> : null}
                {item.locationLabel ? <Text style={styles.caption}>{item.locationLabel}</Text> : null}
              </View>
            </Pressable>
          ))
        )}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.canvas },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: tokens.line,
  },
  back: { minWidth: tokens.touchTarget, minHeight: tokens.touchTarget, justifyContent: "center" },
  backLabel: { fontSize: 18, color: "#636366" },
  title: { flex: 1, fontSize: 15, fontWeight: "600", color: tokens.ink },
  tabs: { flexDirection: "row", gap: 6, paddingHorizontal: 14, paddingVertical: 10 },
  tab: { flex: 1, paddingVertical: 7, borderRadius: 8, alignItems: "center" },
  tabOn: { backgroundColor: tokens.line },
  tabLabel: { fontSize: 13, color: tokens.ink },
  tabLabelOn: { fontWeight: "600" },
  empty: {
    color: "#636366",
    fontSize: tokens.type.caption.size,
    lineHeight: tokens.type.caption.lineHeight,
    paddingHorizontal: 14,
    paddingTop: tokens.space[4],
  },
  row: {
    flexDirection: "row",
    gap: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: tokens.line,
  },
  bar: { width: 3, borderRadius: tokens.radius.highlightBar },
  body: { flex: 1, gap: 4 },
  quote: {
    fontFamily: "serif",
    fontSize: tokens.type.quote.size,
    lineHeight: tokens.type.quote.lineHeight,
    color: tokens.ink,
  },
  note: { fontSize: 13, color: "#636366", marginTop: 4 },
  caption: { fontSize: 12, color: "#8E8E93", marginTop: 4 },
});
