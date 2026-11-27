import type { Locator, ResumeOffer } from "../sync";
import { POSITION_TOAST_MS } from "../sync/status";

export interface PositionToastView {
  lead: string;
  action: string;
  locator: Locator;
  durationMs: number;
}

/** Visible only when the engine produced a toast (other device, not nearby). */
export function toastFromOffer(offer: ResumeOffer | null | undefined): PositionToastView | null {
  if (!offer?.toastLead || !offer.toastAction) return null;
  return {
    lead: offer.toastLead,
    action: offer.toastAction,
    locator: offer.locator,
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
