import type { Locator, ResumeOffer } from "../sync";
import { POSITION_TOAST_MS } from "../sync/status";

export interface PositionToastView {
  lead: string;
  action: string;
  /** Prior local locator the action jumps back to. Null when no local page/CFI is available (EPUB). */
  locator: Locator | null;
  durationMs: number;
}

export interface ResumePlan {
  /** Remote locator to apply on open, even when the toast stays hidden. */
  jump: Locator | null;
  toast: PositionToastView | null;
}

/**
 * Local locator from before the remote resume jump.
 * An unopened PDF defaults to page 1. EPUB progress has no stored CFI, so this is null.
 */
export function priorLocator(
  format: "pdf" | "epub",
  saved?: { page?: number } | null,
): Locator | null {
  if (format === "pdf") {
    const page = typeof saved?.page === "number" && saved.page >= 1 ? saved.page : 1;
    return { format: "pdf", page };
  }
  return null;
}

/** Button copy for undoing the auto-jump. EPUB has no page, so the label is just "Back". */
export function backActionLabel(locator: Locator | null | undefined): string {
  if (locator?.format === "pdf") return `Back to p. ${locator.page}`;
  return "Back";
}

/** Visible only when the engine produced a toast (other device, not nearby). */
export function toastFromOffer(
  offer: ResumeOffer | null | undefined,
  prior?: Locator | null,
): PositionToastView | null {
  if (!offer?.toastLead || !offer.toastAction) return null;
  return {
    lead: offer.toastLead,
    action: backActionLabel(prior),
    locator: prior ?? null,
    durationMs: offer.toastDurationMs || POSITION_TOAST_MS,
  };
}

export function shouldOfferResume(offer: ResumeOffer | null | undefined): boolean {
  return toastFromOffer(offer) !== null;
}

/** Remote locator to apply on open, even when the toast stays hidden (same device or nearby). */
export function resumeLocator(offer: ResumeOffer | null | undefined): Locator | null {
  return offer?.locator ?? null;
}

/**
 * Auto-jump to the remote locator, but point the toast action at the prior
 * local locator so "Back to p. N" can undo the jump.
 */
export function applyResume(offer: ResumeOffer | null | undefined, prior: Locator | null): ResumePlan {
  return {
    jump: resumeLocator(offer),
    toast: toastFromOffer(offer, prior),
  };
}
