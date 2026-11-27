import type { TextSlice } from "../highlight/locate";

export interface ViewerHighlight {
  id: string;
  color: number;
  hex: string;
  opacity: number;
  quote: string;
  prefix: string;
  suffix: string;
  page?: number;
  cfi?: string;
  section?: string;
  rects: number[][];
}

export type HostToViewer =
  | { type: "open-pdf"; base64: string; workerSource: string; page?: number }
  | { type: "open-epub"; base64: string; cfi?: string }
  | { type: "restore"; highlights: ViewerHighlight[] }
  | { type: "paint"; highlight: ViewerHighlight }
  | { type: "remove"; id: string }
  | { type: "locate"; id: string; quote: string; prefix: string; suffix: string }
  | { type: "goto"; page?: number; cfi?: string };

export type ViewerToHost =
  | { type: "ready"; format: "pdf" | "epub" }
  | {
      type: "selection";
      quote: string;
      before: string;
      after: string;
      page?: number;
      cfi?: string;
      section?: string;
      rects: number[][];
    }
  | { type: "corpus"; slices: TextSlice[] }
  | {
      type: "located";
      id: string;
      found: boolean;
      page?: number;
      cfi?: string;
      section?: string;
      prefix: string;
      suffix: string;
      rects: number[][];
      reason?: "restore" | "request";
    }
  | { type: "open-highlight"; id: string }
  | { type: "error"; message: string }
  | {
      type: "location";
      format: "pdf" | "epub";
      page?: number;
      pageCount?: number;
      cfi?: string;
      section?: string;
      progression?: number;
    };

const hostTypes = new Set(["open-pdf", "open-epub", "restore", "paint", "remove", "locate", "goto"]);
const viewerTypes = new Set(["ready", "selection", "corpus", "located", "open-highlight", "error", "location"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function parseHostMessage(raw: string): HostToViewer | null {
  return parse(raw, hostTypes) as HostToViewer | null;
}

export function parseViewerMessage(raw: string): ViewerToHost | null {
  return parse(raw, viewerTypes) as ViewerToHost | null;
}

function parse(raw: string, allowed: Set<string>): HostToViewer | ViewerToHost | null {
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || typeof value.type !== "string" || !allowed.has(value.type)) return null;
    return value as HostToViewer | ViewerToHost;
  } catch {
    return null;
  }
}
