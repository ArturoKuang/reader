import { describe, expect, it } from "@jest/globals";
import { POSITION_TOAST_MS } from "../sync/status";
import { applyResume, priorLocator, resumeLocator, toastFromOffer } from "./resumeOffer";
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

const remoteOffer = offer({
  locator: { format: "pdf", page: 4 },
  toast: "Opened where you left off on your Mac · Back to p. 4",
  toastLead: "Opened where you left off on QA v1 Observer Mac",
  toastAction: "Back to p. 4",
});

describe("cross-device position toast", () => {
  it("jumps to the remote page and offers Back to the prior local page", () => {
    const prior = priorLocator("pdf", { page: 1 });
    const planned = applyResume(remoteOffer, prior);
    expect(planned.jump).toEqual({ format: "pdf", page: 4 });
    expect(planned.toast?.lead).toBe("Opened where you left off on QA v1 Observer Mac");
    expect(planned.toast?.action).toBe("Back to p. 1");
    expect(planned.toast?.locator).toEqual({ format: "pdf", page: 1 });
    expect(planned.toast?.durationMs).toBe(POSITION_TOAST_MS);
    expect(resumeLocator(remoteOffer)).toEqual({ format: "pdf", page: 4 });
  });

  it("navigates back to the prior local locator, not the remote page, when the toast action is tapped", () => {
    const prior = { format: "pdf" as const, page: 1 };
    const planned = applyResume(remoteOffer, prior);
    expect(planned.toast?.action).toBe("Back to p. 1");
    expect(planned.toast?.locator).toEqual(prior);
    expect(planned.toast?.locator).not.toEqual(planned.jump);
    expect(planned.jump).toEqual({ format: "pdf", page: 4 });
  });

  it("defaults an unopened PDF to Back to p. 1", () => {
    expect(priorLocator("pdf", null)).toEqual({ format: "pdf", page: 1 });
    expect(priorLocator("pdf", undefined)).toEqual({ format: "pdf", page: 1 });
    const planned = applyResume(remoteOffer, priorLocator("pdf", null));
    expect(planned.toast?.action).toBe("Back to p. 1");
    expect(planned.toast?.locator).toEqual({ format: "pdf", page: 1 });
  });

  it("falls back to a page-less Back label for EPUB", () => {
    const epub = offer({
      locator: { format: "epub", cfi: "epubcfi(/6/8!/4/2/1:0)", progression: 0.5 },
      toast: "Opened where you left off on your Mac · Back to /6/8",
      toastLead: "Opened where you left off on your Mac",
      toastAction: "Back to /6/8",
    });
    const planned = applyResume(epub, priorLocator("epub", { page: undefined }));
    expect(planned.jump).toEqual({ format: "epub", cfi: "epubcfi(/6/8!/4/2/1:0)", progression: 0.5 });
    expect(planned.toast?.action).toBe("Back");
    expect(planned.toast?.locator).toBeNull();
  });

  it("hides the toast when the engine says the position is nearby or ours", () => {
    const hidden = offer({
      locator: { format: "pdf", page: 40 },
      toast: null,
      toastLead: null,
      toastAction: null,
    });
    expect(toastFromOffer(hidden, { format: "pdf", page: 1 })).toBeNull();
    expect(applyResume(hidden, { format: "pdf", page: 1 }).toast).toBeNull();
    expect(applyResume(hidden, { format: "pdf", page: 1 }).jump).toEqual({ format: "pdf", page: 40 });
    expect(resumeLocator(hidden)).toEqual({ format: "pdf", page: 40 });
  });
});
