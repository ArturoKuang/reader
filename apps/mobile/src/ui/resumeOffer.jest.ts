import { describe, expect, it } from "@jest/globals";
import { POSITION_TOAST_MS } from "../sync/status";
import { resumeLocator, toastFromOffer } from "./resumeOffer";
import type { ResumeOffer } from "../sync/engine";

function offer(partial: Partial<ResumeOffer> & Pick<ResumeOffer, "locator" | "toast" | "toastLead" | "toastAction">): ResumeOffer {
  return {
    bookId: "sha256:aa",
    deviceId: "mac",
    deviceName: "your Mac",
    seq: 4,
    toastDurationMs: POSITION_TOAST_MS,
    ...partial,
  };
}

describe("cross-device position toast", () => {
  it("shows the 5-second Back to p. N toast and keeps the remote locator", () => {
    const remote = offer({
      locator: { format: "pdf", page: 40 },
      toast: "Opened where you left off on your Mac · Back to p. 40",
      toastLead: "Opened where you left off on your Mac",
      toastAction: "Back to p. 40",
    });
    const view = toastFromOffer(remote);
    expect(view?.lead).toBe("Opened where you left off on your Mac");
    expect(view?.action).toBe("Back to p. 40");
    expect(view?.durationMs).toBe(POSITION_TOAST_MS);
    expect(resumeLocator(remote)).toEqual({ format: "pdf", page: 40 });
  });

  it("hides the toast when the engine says the position is nearby or ours", () => {
    const hidden = offer({
      locator: { format: "pdf", page: 40 },
      toast: null,
      toastLead: null,
      toastAction: null,
    });
    expect(toastFromOffer(hidden)).toBeNull();
    expect(resumeLocator(hidden)).toEqual({ format: "pdf", page: 40 });
  });
});
