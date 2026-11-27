export interface TimerHandle {
  cancel(): void;
}

export interface Clock {
  now(): number;
  iso(): string;
  setTimeout(fn: () => void | Promise<void>, ms: number): TimerHandle;
}

export function systemClock(): Clock {
  return {
    now: () => Date.now(),
    iso: () => new Date().toISOString(),
    setTimeout(fn, ms) {
      const id = setTimeout(() => {
        void fn();
      }, ms);
      return { cancel: () => clearTimeout(id) };
    },
  };
}

interface FakeTimer {
  at: number;
  fn: () => void | Promise<void>;
  cancelled: boolean;
}

/** Deterministic clock for tests. `advance` runs due timers in order. */
export class FakeClock implements Clock {
  private timeMs = 0;
  private timers: FakeTimer[] = [];

  now(): number {
    return this.timeMs;
  }

  iso(): string {
    return new Date(this.timeMs).toISOString();
  }

  setTimeout(fn: () => void | Promise<void>, ms: number): TimerHandle {
    const timer: FakeTimer = { at: this.timeMs + ms, fn, cancelled: false };
    this.timers.push(timer);
    return {
      cancel: () => {
        timer.cancelled = true;
      },
    };
  }

  async advance(ms: number): Promise<void> {
    const target = this.timeMs + ms;
    for (;;) {
      const next = this.timers
        .filter((timer) => !timer.cancelled && timer.at <= target)
        .sort((left, right) => left.at - right.at)[0];
      if (!next) break;
      this.timeMs = next.at;
      next.cancelled = true;
      await next.fn();
    }
    this.timeMs = target;
  }
}
