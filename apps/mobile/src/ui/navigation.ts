import type { Locator } from "../sync/wire";
import type { LibraryBook } from "../library/catalog";

export interface JumpTo {
  highlightId?: string;
  locator?: Locator;
}

export type AppRoute =
  | { name: "library" }
  | { name: "reader"; book: LibraryBook; jumpTo?: JumpTo }
  | { name: "notebook"; book: LibraryBook };

export const libraryRoute: AppRoute = { name: "library" };

export function readerRoute(book: LibraryBook, jumpTo?: JumpTo): AppRoute {
  return jumpTo ? { name: "reader", book, jumpTo } : { name: "reader", book };
}

export function notebookRoute(book: LibraryBook): AppRoute {
  return { name: "notebook", book };
}

export function backFrom(route: AppRoute): AppRoute {
  if (route.name === "notebook") return readerRoute(route.book);
  return libraryRoute;
}
