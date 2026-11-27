import { useCallback, useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { readAssetBase64 } from "../reader/installViewer";
import { epubModule, pdfModule } from "../reader/samples";
import { isBookCached, readCachedBookBase64, writeCachedBook } from "../reader/bookCache";
import { useSync } from "../sync/SyncProvider";
import type { LibraryBook } from "../library/catalog";
import { BookReader } from "./BookReader";
import { LibraryScreen } from "./LibraryScreen";
import { NotebookScreen } from "./NotebookScreen";
import { backFrom, libraryRoute, notebookRoute, readerRoute, type AppRoute, type JumpTo } from "./navigation";
import { tokens } from "./tokens";

export function AppShell() {
  const sync = useSync();
  const [route, setRoute] = useState<AppRoute>(libraryRoute);
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  const [downloadError, setDownloadError] = useState<string | null>(null);

  const loadBase64 = useCallback(async (book: LibraryBook): Promise<string> => {
    if (book.source !== "synced") {
      return readAssetBase64(book.format === "pdf" ? pdfModule : epubModule);
    }
    const cached = await readCachedBookBase64(book.sha256, book.format);
    if (cached) return cached;
    if (!sync) throw new Error("Pair this phone to download books from your Mac mini.");
    const downloaded = await sync.downloadBook(book.id);
    await writeCachedBook(downloaded.sha256, book.format, downloaded.bytes);
    const written = await readCachedBookBase64(downloaded.sha256, book.format);
    if (!written) throw new Error("The downloaded book could not be saved.");
    return written;
  }, [sync]);

  async function openBook(book: LibraryBook, jumpTo?: JumpTo) {
    setDownloadError(null);
    if (book.source === "synced" && !book.cached && !isBookCached(book.sha256, book.format)) {
      setDownloadingId(book.id);
      try {
        if (!sync) throw new Error("Pair this phone to download books from your Mac mini.");
        const downloaded = await sync.downloadBook(book.id);
        await writeCachedBook(downloaded.sha256, book.format, downloaded.bytes);
        setRoute(readerRoute({ ...book, cached: true, size: downloaded.size }, jumpTo));
      } catch (cause) {
        setDownloadError(cause instanceof Error ? cause.message : String(cause));
      } finally {
        setDownloadingId(null);
      }
      return;
    }
    setRoute(readerRoute(book, jumpTo));
  }

  return (
    <View style={styles.root}>
      {downloadError && route.name === "library" ? <Text style={styles.error}>{downloadError}</Text> : null}
      {route.name === "library" ? (
        <LibraryScreen
          downloadingId={downloadingId}
          onOpenBook={(book) => {
            void openBook(book);
          }}
          onOpenConflict={(_conflict, book) => setRoute(notebookRoute(book))}
        />
      ) : null}
      {route.name === "reader" ? (
        <BookReader
          key={route.book.id + (route.jumpTo?.highlightId ?? "")}
          book={route.book}
          jumpTo={route.jumpTo}
          loadBase64={() => loadBase64(route.book)}
          onBack={() => setRoute(libraryRoute)}
          onOpenNotebook={() => setRoute(notebookRoute(route.book))}
        />
      ) : null}
      {route.name === "notebook" ? (
        <NotebookScreen
          book={route.book}
          onBack={() => setRoute(backFrom(route))}
          onJump={(jumpTo) => setRoute(readerRoute(route.book, jumpTo))}
        />
      ) : null}
    </View>
  );
}

/** @deprecated Use AppShell. Kept so existing imports keep working. */
export const ReaderHome = AppShell;

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: tokens.canvas },
  error: { color: "#EB5757", paddingHorizontal: 14, paddingTop: 8 },
});
