/**
 * Phone colors from the shared design tokens. Highlight order and opacity
 * match ReaderCore (`HighlightPalette.hex`, `HighlightAppearance.opacity`).
 * Files store the 1-based index, not the hex.
 */

export const tokens = {
  highlight: {
    opacity: 0.38,
    default: 1,
    palette: [
      { id: 1, hex: "#F2C94C" },
      { id: 2, hex: "#6FCF97" },
      { id: 3, hex: "#56CCF2" },
      { id: 4, hex: "#F28FB1" },
      { id: 5, hex: "#BB6BD9" },
      { id: 6, hex: "#F2994A" },
    ],
  },
  syncStatus: {
    unpaired: { dot: "#8E8E93", label: "Not paired" },
    synced: { dot: "#27AE60", label: "Synced" },
    syncing: { dot: "#2F80ED", label: "Syncing…" },
    offline: { dot: "#8E8E93", label: "Offline, changes saved" },
    conflict: { dot: "#F2994A", label: "2 versions to review" },
    error: { dot: "#EB5757", label: "Can't reach Mac mini" },
    storageFull: {
      dot: "#EB5757",
      label: "Mac mini is full",
      detail: "Books paused. Highlights and notes still sync.",
      action: "Check again",
      badge: "Waiting for space",
    },
  },
  space: [4, 8, 12, 16, 24, 32] as const,
  radius: { chip: 999, card: 12, sheet: 16, highlightBar: 2 },
  type: {
    title: { size: 22, weight: "600" as const, lineHeight: 28 },
    heading: { size: 17, weight: "600" as const, lineHeight: 22 },
    body: { size: 16, weight: "400" as const, lineHeight: 24 },
    quote: { size: 15, weight: "400" as const, lineHeight: 22 },
    caption: { size: 13, weight: "400" as const, lineHeight: 18 },
  },
  touchTarget: 44,
  ink: "#1C1C1E",
  paper: "#FFFFFF",
  canvas: "#F6F5F3",
  line: "#E5E3DF",
  selection: "rgba(47, 128, 237, 0.18)",
};

export function highlightPaint(hex: string): string {
  const value = hex.replace("#", "");
  const red = Number.parseInt(value.slice(0, 2), 16);
  const green = Number.parseInt(value.slice(2, 4), 16);
  const blue = Number.parseInt(value.slice(4, 6), 16);
  return `rgba(${red}, ${green}, ${blue}, ${tokens.highlight.opacity})`;
}
