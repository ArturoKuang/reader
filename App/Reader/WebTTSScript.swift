import Foundation

/// The page-side half of Read Aloud for EPUB and Markdown.
///
/// Nothing here edits the article DOM. Text is read through a per-section table
/// of `{ node, start, end }` entries, and the sentence and word are painted with
/// the CSS Custom Highlight API (`::highlight(tts-sentence)` / `tts-word`).
/// Browsers without it (macOS 14.0-14.1) get absolutely positioned rects in a
/// pointer-transparent layer outside the article.
enum WebTTSScript {
    /// Highlight colors for the four themes, SPEC.md Part 2 §3. They are indigo
    /// washes, so they stay apart from the six highlight swatches and the
    /// selection blue. `data-tts-theme` is set on `<html>` by `readerTTSSetTheme`.
    static let css = #"""
    ::highlight(tts-sentence) { background-color: rgba(67, 83, 255, 0.08); }
    ::highlight(tts-word) { background-color: rgba(67, 83, 255, 0.24); text-decoration: underline; text-decoration-color: rgba(55, 68, 224, 0.72); text-decoration-thickness: 1.5px; text-underline-offset: 3px; }
    @media (prefers-color-scheme: dark) {
      :root[data-tts-theme="original"] ::highlight(tts-sentence) { background-color: rgba(129, 146, 255, 0.14); }
      :root[data-tts-theme="original"] ::highlight(tts-word) { background-color: rgba(129, 146, 255, 0.34); color: #ffffff; text-decoration-color: rgba(165, 178, 255, 0.85); }
    }
    :root[data-tts-theme="paper"] ::highlight(tts-sentence) { background-color: rgba(58, 78, 176, 0.09); }
    :root[data-tts-theme="paper"] ::highlight(tts-word) { background-color: rgba(58, 78, 176, 0.23); color: #1f1810; text-decoration-color: rgba(48, 66, 158, 0.72); }
    :root[data-tts-theme="quiet"] ::highlight(tts-sentence) { background-color: rgba(58, 76, 210, 0.09); }
    :root[data-tts-theme="quiet"] ::highlight(tts-word) { background-color: rgba(58, 76, 210, 0.24); color: #141416; text-decoration-color: rgba(48, 64, 196, 0.75); }
    :root[data-tts-theme="night"] ::highlight(tts-sentence) { background-color: rgba(136, 152, 255, 0.14); }
    :root[data-tts-theme="night"] ::highlight(tts-word) { background-color: rgba(136, 152, 255, 0.34); color: #ffffff; text-decoration-color: rgba(172, 184, 255, 0.86); }
    #reader-tts-layer { position: absolute; left: 0; top: 0; width: 0; height: 0; pointer-events: none; z-index: 2147483000; }
    #reader-tts-layer div { position: absolute; border-radius: 3px; background: rgba(67, 83, 255, 0.08); }
    #reader-tts-layer div.word { background: rgba(67, 83, 255, 0.24); box-shadow: inset 0 -1.5px 0 rgba(55, 68, 224, 0.72); }
    """#

    /// The script text, with the highlight CSS embedded.
    static var source: String {
        let data = (try? JSONEncoder().encode(css)) ?? Data("\"\"".utf8)
        return body.replacingOccurrences(of: "style.textContent = TTS_CSS;", with: "style.textContent = " + String(decoding: data, as: UTF8.self) + ";")
    }

    private static let body = #"""
    (function () {
      if (window.readerTTSExtractSections) return;

      const EXCLUDE = '[data-tts-exclude="true"], .reader-glyph, .reader-note-pill, .reader-badge, .reader-copy-btn, .reader-copy, script, style, noscript, template, title';
      const BLOCKS = new Set(["address", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "td", "th", "tr", "ul"]);
      const SECTIONS = "section[data-tts-section], section[id^='spine-']";
      const hasHighlights = !!(window.CSS && CSS.highlights && typeof Highlight !== "undefined");

      // sectionIndex -> { el, text, table: [{ node, start, end, atomic? }], stale }
      const cache = new Map();
      // The text each section had when Swift planned it. A later mismatch means the DOM drifted.
      const planned = new Map();
      let last = null;
      let active = null;

      window.__readerTTSActive = false;
      window.__readerTTSProgrammaticUntil = 0;

      const style = document.createElement("style");
      style.id = "reader-tts-style";
      style.textContent = TTS_CSS;
      document.head.appendChild(style);

      window.readerTTSSetTheme = function (theme) {
        document.documentElement.dataset.ttsTheme = ["original", "paper", "quiet", "night"].includes(theme) ? theme : "original";
      };

      function post(message) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reader) window.webkit.messageHandlers.reader.postMessage(message);
      }

      function sectionIndex(el) {
        const raw = el.dataset.ttsSection !== undefined ? el.dataset.ttsSection : el.dataset.index;
        const value = Number(raw);
        return Number.isFinite(value) ? value : 0;
      }

      function sections() { return [...document.querySelectorAll(SECTIONS)]; }

      // Block edges and <br> become one newline; the planner ends a sentence at each.
      function walk(root, items) {
        for (let child = root.firstChild; child; child = child.nextSibling) {
          if (child.nodeType === 3) { items.push({ node: child }); continue; }
          if (child.nodeType !== 1 || child.matches(EXCLUDE)) continue;
          const name = child.localName;
          if (name === "br") { items.push({ brk: true }); continue; }
          if (name === "math") {
            const spoken = child.hasAttribute("data-tts-spoken") ? child.getAttribute("data-tts-spoken") : (child.textContent || "").replace(/\s+/g, " ").trim();
            const display = child.getAttribute("display") === "block";
            if (display) items.push({ brk: true });
            items.push({ node: child, spoken });
            if (display) items.push({ brk: true });
            continue;
          }
          const block = BLOCKS.has(name);
          if (block) items.push({ brk: true });
          walk(child, items);
          if (block) items.push({ brk: true });
        }
      }

      function build(root) {
        const items = [];
        walk(root, items);
        let text = "";
        const table = [];
        for (const item of items) {
          if (item.brk) { if (text.length && !text.endsWith("\n")) text += "\n"; continue; }
          // Source line wraps are spaces, not sentence ends. Same length, so offsets stay 1:1.
          const value = item.spoken !== undefined ? item.spoken : (item.node.nodeValue || "").replace(/[\r\n]/g, " ");
          if (!value) continue;
          table.push({ node: item.node, start: text.length, end: text.length + value.length, atomic: item.spoken !== undefined });
          text += value;
        }
        return { text, table };
      }

      function entryIsLive(entry) {
        return entry.node.isConnected && (entry.atomic || (entry.node.nodeValue || "").length === entry.end - entry.start);
      }

      function dataFor(index) {
        let data = cache.get(index);
        if (data && data.el.isConnected && data.table.every(entryIsLive)) return data;
        cache.delete(index);
        const el = sections().find(section => sectionIndex(section) === index);
        if (!el) return null;
        const built = build(el);
        data = { el, text: built.text, table: built.table, stale: planned.has(index) && planned.get(index) !== built.text };
        cache.set(index, data);
        return data;
      }

      window.readerTTSExtractSections = function (extra) {
        const out = new Map();
        for (const el of sections()) {
          const index = sectionIndex(el);
          const built = build(el);
          cache.set(index, { el, text: built.text, table: built.table, stale: false });
          planned.set(index, built.text);
          out.set(index, { index, text: built.text });
        }
        // Spine items that are not in this page (single and two-page EPUB) are parsed detached.
        (extra || []).forEach(item => {
          if (out.has(item.index)) return;
          const doc = new DOMParser().parseFromString("<!doctype html><body><section>" + item.html + "</section>", "text/html");
          const built = build(doc.querySelector("section"));
          planned.set(item.index, built.text);
          out.set(item.index, { index: item.index, text: built.text });
        });
        return [...out.values()].sort((a, b) => a.index - b.index);
      };

      function rangeFor(data, start, length) {
        if (!(length > 0) || !data.table.length || start < 0 || start >= data.text.length) return null;
        const table = data.table;
        const end = start + length;
        let lo = 0, hi = table.length - 1, first = -1;
        while (lo <= hi) {
          const mid = (lo + hi) >> 1;
          if (table[mid].end > start) { first = mid; hi = mid - 1; } else lo = mid + 1;
        }
        if (first < 0) return null;
        let lastIndex = -1;
        lo = first; hi = table.length - 1;
        while (lo <= hi) {
          const mid = (lo + hi) >> 1;
          if (table[mid].start < end) { lastIndex = mid; lo = mid + 1; } else hi = mid - 1;
        }
        if (lastIndex < first) return null;
        const a = table[first], b = table[lastIndex];
        try {
          const range = document.createRange();
          if (a.atomic) range.setStartBefore(a.node); else range.setStart(a.node, Math.max(start, a.start) - a.start);
          if (b.atomic) range.setEndAfter(b.node); else range.setEnd(b.node, Math.min(end, b.end) - b.start);
          return range;
        } catch (error) {
          return null;
        }
      }

      function lineRect(range) {
        if (!range) return null;
        const box = range.getBoundingClientRect();
        if (box && (box.width || box.height)) return box;
        return range.getClientRects()[0] || null;
      }

      // The bounding box of a long sentence is taller than the band, so use its first line.
      function anchorRect(a) {
        if (!a) return null;
        if (a.wordRange) return lineRect(a.wordRange);
        return a.sentRange ? (a.sentRange.getClientRects()[0] || lineRect(a.sentRange)) : null;
      }

      function reveal(a, force, smooth) {
        const rect = anchorRect(a);
        if (!rect) return false;
        const low = 72, high = window.innerHeight - 170;
        const wideLayout = document.documentElement.scrollWidth > window.innerWidth + 4;
        const offX = wideLayout && (rect.left < 0 || rect.right > window.innerWidth);
        if (!force && rect.top >= low && rect.bottom <= high && !offX) return true;
        window.__readerTTSProgrammaticUntil = performance.now() + 600;
        window.scrollTo({
          top: Math.max(0, window.scrollY + rect.top - window.innerHeight * 0.36),
          left: offX ? Math.max(0, window.scrollX + rect.left - 24) : window.scrollX,
          behavior: smooth ? "smooth" : "auto"
        });
        return true;
      }

      function paintFallback(a) {
        let layer = document.getElementById("reader-tts-layer");
        if (!layer) {
          layer = document.createElement("div");
          layer.id = "reader-tts-layer";
          layer.dataset.ttsExclude = "true";
          document.body.appendChild(layer);
        }
        layer.textContent = "";
        const add = (range, className) => {
          if (!range) return;
          for (const rect of range.getClientRects()) {
            const box = document.createElement("div");
            box.className = className;
            box.style.cssText = "left:" + (rect.left + window.scrollX) + "px;top:" + (rect.top + window.scrollY) + "px;width:" + rect.width + "px;height:" + rect.height + "px";
            layer.appendChild(box);
          }
        };
        if (a) { add(a.sentRange, "sentence"); add(a.wordRange, "word"); }
      }

      function paint(a) {
        if (!hasHighlights) return paintFallback(a);
        if (a && a.sentRange) CSS.highlights.set("tts-sentence", new Highlight(a.sentRange)); else CSS.highlights.delete("tts-sentence");
        if (a && a.wordRange) CSS.highlights.set("tts-word", new Highlight(a.wordRange)); else CSS.highlights.delete("tts-word");
      }

      function apply(args, scroll) {
        const data = dataFor(args.sectionIndex);
        if (!data || data.stale) {
          // The previous sentence is no longer the active one, so it must not stay painted.
          active = null;
          paint(null);
          return data ? "stale" : "missing";
        }
        active = {
          sentRange: rangeFor(data, args.sentStart, args.sentLen),
          wordRange: args.wordLen > 0 ? rangeFor(data, args.wordStart, args.wordLen) : null
        };
        paint(active);
        if (scroll) reveal(active, false, true);
        return "ok";
      }

      window.readerTTSHighlight = function (sectionIndex, sentStart, sentLen, wordStart, wordLen, autoScroll) {
        last = { sectionIndex, sentStart, sentLen, wordStart, wordLen };
        return apply(last, autoScroll === true);
      };

      window.readerTTSClear = function () {
        last = null;
        active = null;
        if (hasHighlights) { CSS.highlights.delete("tts-sentence"); CSS.highlights.delete("tts-word"); }
        const layer = document.getElementById("reader-tts-layer");
        if (layer) layer.textContent = "";
      };

      // Painting or replacing the article rewrites text nodes. Drop the table and repaint.
      window.readerTTSInvalidate = function () {
        cache.clear();
        if (last) apply(last, false);
      };

      window.readerTTSReset = function () {
        window.readerTTSClear();
        cache.clear();
      };

      window.readerTTSScrollToActive = function (animated) {
        if (!active) return false;
        return reveal(active, true, animated === true);
      };

      window.readerTTSSetBottomInset = function (px) {
        window.__readerTTSActive = px > 0;
        document.body.style.paddingBottom = px > 0 ? (px + 40) + "px" : "";
      };

      // The first text on screen, as a section index and an offset into that section's text.
      window.readerTTSViewportStart = function () {
        const probe = 8;
        const bottomOf = (node, atomic, from) => {
          const range = document.createRange();
          if (atomic) range.selectNode(node); else { range.setStart(node, from); range.setEnd(node, Math.min(from + 1, node.nodeValue.length)); }
          const rects = range.getClientRects();
          return rects.length ? rects[0].bottom : null;
        };
        for (const el of sections()) {
          if (el.getBoundingClientRect().bottom <= probe) continue;
          const index = sectionIndex(el);
          const data = dataFor(index);
          if (!data) continue;
          for (const entry of data.table) {
            const value = entry.atomic ? "x" : (entry.node.nodeValue || "");
            if (!value.trim()) continue;
            const range = document.createRange();
            if (entry.atomic) range.selectNode(entry.node); else range.selectNodeContents(entry.node);
            const box = range.getBoundingClientRect();
            if (!(box.bottom > probe)) continue;
            if (entry.atomic) return { sectionIndex: index, offset: entry.start };
            // Inside a node that wraps, find the first character below the top edge.
            let lo = 0, hi = value.length;
            while (lo < hi) {
              const mid = (lo + hi) >> 1;
              const bottom = bottomOf(entry.node, false, mid);
              if (bottom === null || bottom > probe) hi = mid; else lo = mid + 1;
            }
            return { sectionIndex: index, offset: entry.start + Math.min(lo, value.length - 1) };
          }
        }
        return null;
      };

      // Selects the word at a point, so "Read Aloud from Here" has a start to read from.
      window.readerTTSSelectAt = function (x, y) {
        const selection = window.getSelection();
        if (selection && !selection.isCollapsed && selection.toString().trim()) return true;
        const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (!caret || !selection) return false;
        selection.removeAllRanges();
        selection.addRange(caret);
        if (selection.modify) {
          selection.modify("move", "forward", "character");
          selection.modify("move", "backward", "word");
          selection.modify("extend", "forward", "word");
        }
        return !selection.isCollapsed;
      };

      // Scrolls the user does themselves detach follow-text. The bridge's own smooth
      // scroll sets a window; scroll events inside it keep extending it until it settles.
      let lastPost = 0;
      function userScrolled() {
        if (!window.__readerTTSActive) return;
        const now = performance.now();
        if (now - lastPost < 250) return;
        lastPost = now;
        post({ kind: "tts-manual-scroll" });
      }
      window.addEventListener("wheel", userScrolled, { passive: true });
      window.addEventListener("touchmove", userScrolled, { passive: true });
      window.addEventListener("scroll", () => {
        const now = performance.now();
        if (now <= window.__readerTTSProgrammaticUntil) {
          window.__readerTTSProgrammaticUntil = Math.max(window.__readerTTSProgrammaticUntil, now + 120);
          return;
        }
        userScrolled();
      }, { passive: true });
      window.addEventListener("resize", () => {
        window.__readerTTSProgrammaticUntil = Math.max(window.__readerTTSProgrammaticUntil, performance.now() + 300);
        if (!hasHighlights && active) paintFallback(active);
      });
    })();
    """#
}
