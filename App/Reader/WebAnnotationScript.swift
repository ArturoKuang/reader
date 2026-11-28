import Foundation

/// The page-side half of selections, highlights, margin notes, and quote flashes
/// for EPUB and Markdown. A quote is matched against the text of the whole page, so
/// it may span formatting elements, several text nodes, or several blocks.
enum WebAnnotationScript {
    static let source = #"""
    (function () {
      // Text Reader injects into the article; never part of a quote.
      const SKIP = "script, style, noscript, template, .reader-glyph, .reader-note-pill, .reader-badge, .reader-copy, [data-tts-exclude=\"true\"]";
      const BLOCKS = new Set(["address", "article", "aside", "blockquote", "body", "caption", "dd", "details", "div", "dl", "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"]);
      // A span around the formatting whitespace inside these would be a stray child.
      const CONTAINERS = "article, blockquote, body, details, div, dl, ol, section, table, tbody, tfoot, thead, tr, ul";

      // The page text with every whitespace run, block edge, and <br> as one space.
      // `runs` maps positions in it back to the text nodes.
      function pageIndex() {
        let text = "", gap = false;
        const nodes = [], runs = [];
        (function walk(root) {
          for (let child = root.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 3) {
              const node = nodes.push(child) - 1;
              const words = /\S+/g;
              let end = 0, word;
              while ((word = words.exec(child.nodeValue))) {
                if (text && (gap || word.index > end)) text += " ";
                gap = false;
                runs.push({ at: text.length, node, offset: word.index });
                text += word[0];
                end = words.lastIndex;
              }
              if (end < child.nodeValue.length) gap = true;
            } else if (child.nodeType === 1 && !child.matches(SKIP)) {
              const block = BLOCKS.has(child.localName);
              if (block || child.localName === "br") gap = true;
              walk(child);
              if (block) gap = true;
            }
          }
        })(document.body);
        return { text, nodes, runs };
      }

      function normalize(quote) { return String(quote || "").replace(/\s+/g, " ").trim(); }

      function pointAt(index, position) {
        let lo = 0, hi = index.runs.length - 1;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (index.runs[mid].at <= position) lo = mid; else hi = mid - 1;
        }
        const run = index.runs[lo];
        return { node: run.node, offset: run.offset + position - run.at };
      }

      // Each occurrence of `quote` in document order: where it starts in the page text, and the
      // text node slices it covers.
      function* occurrenceRuns(index, quote) {
        const needle = normalize(quote);
        if (!needle) return;
        for (let at = index.text.indexOf(needle); at >= 0; at = index.text.indexOf(needle, at + 1)) {
          const first = pointAt(index, at), last = pointAt(index, at + needle.length - 1);
          const slices = [];
          for (let node = first.node; node <= last.node; node++) {
            const from = node === first.node ? first.offset : 0;
            const to = node === last.node ? last.offset + 1 : index.nodes[node].nodeValue.length;
            if (to > from) slices.push({ node, from, to });
          }
          yield { at, end: at + needle.length, slices };
        }
      }

      function* occurrences(index, quote) {
        for (const run of occurrenceRuns(index, quote)) yield run.slices;
      }

      function commonSuffix(a, b) {
        let n = 0;
        while (n < a.length && n < b.length && a[a.length - 1 - n] === b[b.length - 1 - n]) n++;
        return n;
      }

      function commonPrefix(a, b) {
        let n = 0;
        while (n < a.length && n < b.length && a[n] === b[n]) n++;
        return n;
      }

      // Repeated quotes are told apart by the text around them: the more of the stored prefix and
      // suffix an occurrence shares, the likelier it is the one that was selected. Equal scores
      // (including no context at all) keep document order.
      // An EPUB highlight belongs to one spine item, or else one chapter. The same words in
      // another chapter stay unpainted. Markdown sections carry no spine index.
      function inScope(index, mark, run) {
        const hasSpine = mark.spine !== undefined && mark.spine !== null;
        const hasChapter = mark.chapter !== undefined && mark.chapter !== null;
        if (!hasSpine && !hasChapter) return true;
        const first = run.slices[0];
        const node = first && index.nodes[first.node];
        const section = node && node.parentElement && node.parentElement.closest("section[data-index]");
        if (!section) return true;
        if (hasSpine) return section.dataset.index !== "" && Number(section.dataset.index) === mark.spine;
        return section.dataset.chapter !== "" && Number(section.dataset.chapter) === mark.chapter;
      }

      function rankedOccurrences(index, mark) {
        const prefix = normalize(mark.prefix), suffix = normalize(mark.suffix);
        const runs = [...occurrenceRuns(index, mark.quote)].filter(run => inScope(index, mark, run));
        if (runs.length < 2 || (!prefix && !suffix)) return runs;
        const score = run => {
          const before = index.text.slice(Math.max(0, run.at - prefix.length - 1), run.at).trimEnd();
          const after = index.text.slice(run.end, run.end + suffix.length + 1).trimStart();
          return commonSuffix(before, prefix) + commonPrefix(after, suffix);
        };
        return runs.map((run, order) => ({ run, order, score: score(run) }))
          .sort((a, b) => b.score - a.score || a.order - b.order)
          .map(entry => entry.run);
      }

      function wrappable(node, from, to) {
        const parent = node.parentElement;
        if (!parent || parent.closest("math, [class*='reader-hl']")) return false;
        return !!node.nodeValue.slice(from, to).trim() || !parent.matches(CONTAINERS);
      }

      // `pieces` do not overlap. Working from the end keeps earlier offsets valid.
      function wrap(node, pieces) {
        const spans = [];
        pieces.sort((a, b) => b.from - a.from).forEach(piece => {
          if (piece.to < node.nodeValue.length) node.splitText(piece.to);
          const target = piece.from > 0 ? node.splitText(piece.from) : node;
          const span = document.createElement("span");
          span.className = piece.className;
          if (piece.id) span.dataset.annotationId = piece.id;
          target.parentNode.insertBefore(span, target);
          span.appendChild(target);
          spans.unshift(span);
        });
        return spans;
      }

      function unwrap(span) {
        const parent = span.parentNode;
        if (!parent) return;
        while (span.firstChild) parent.insertBefore(span.firstChild, span);
        parent.removeChild(span);
        parent.normalize();
      }

      window.readerPaint = function (marks) {
        document.querySelectorAll("span[class^='reader-hl-']").forEach(unwrap);
        const index = pageIndex();
        const claimed = new Map(); // node position -> pieces already taken
        (marks || []).forEach(mark => {
          // The first occurrence that still has unpainted text gets this mark.
          for (const { slices } of rankedOccurrences(index, mark)) {
            const fresh = [];
            slices.forEach(slice => {
              let free = [[slice.from, slice.to]];
              (claimed.get(slice.node) || []).forEach(taken => {
                free = free.flatMap(([from, to]) => [[from, Math.min(to, taken.from)], [Math.max(from, taken.to), to]].filter(([a, b]) => b > a));
              });
              free.forEach(([from, to]) => {
                if (wrappable(index.nodes[slice.node], from, to)) fresh.push({ node: slice.node, from, to, id: mark.id, className: "reader-hl-" + (mark.color || 1) });
              });
            });
            if (!fresh.some(piece => index.nodes[piece.node].nodeValue.slice(piece.from, piece.to).trim())) continue;
            fresh.forEach(piece => {
              if (!claimed.has(piece.node)) claimed.set(piece.node, []);
              claimed.get(piece.node).push(piece);
            });
            break;
          }
        });
        claimed.forEach((pieces, node) => wrap(index.nodes[node], pieces));
        if (window.readerTTSInvalidate) window.readerTTSInvalidate();
      };

      const NOTE_ICON = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 1.5h8a1 1 0 0 1 1 1v5.5a1 1 0 0 1-1 1H5.6L3 10.8V9H2a1 1 0 0 1-1-1V2.5a1 1 0 0 1 1-1z"/></svg>';

      // A compact pill right after the last painted span of the note's highlight, so it reads as
      // part of the passage. A note without a painted highlight falls back to its first occurrence.
      window.readerMarginNotes = function (notes) {
        document.querySelectorAll(".reader-glyph").forEach(node => node.remove());
        const index = pageIndex();
        (notes || []).forEach(note => {
          const spans = document.querySelectorAll("span[data-annotation-id=\"" + CSS.escape(note.id) + "\"]");
          let anchor = spans[spans.length - 1];
          if (!anchor) {
            const found = occurrences(index, note.quote).next().value;
            if (!found) return;
            anchor = index.nodes[found[found.length - 1].node];
          }
          const mark = document.createElement("button");
          mark.type = "button";
          mark.className = "reader-glyph";
          mark.dataset.id = note.id;
          mark.dataset.ttsExclude = "true";
          mark.setAttribute("aria-label", "Open note");
          mark.style.setProperty("--hl-color", note.color || "#888");
          mark.innerHTML = NOTE_ICON;
          mark.title = (note.body || "").split("\n")[0];
          anchor.after(mark);
        });
        if (window.readerTTSInvalidate) window.readerTTSInvalidate();
      };

      // The on-screen box of a highlight in viewport CSS pixels, or of its note pill when the
      // highlight is not painted. A highlight that is scrolled out of view is brought to the middle.
      window.readerHighlightRect = function (id) {
        const key = CSS.escape(id);
        const parts = () => {
          let nodes = [...document.querySelectorAll("span[data-annotation-id=\"" + key + "\"]")];
          if (!nodes.length) nodes = [...document.querySelectorAll(".reader-glyph[data-id=\"" + key + "\"]")];
          return nodes;
        };
        let nodes = parts();
        if (!nodes.length) return null;
        const onScreen = rect => rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < window.innerHeight && rect.right > 0 && rect.left < window.innerWidth;
        const lines = () => nodes.flatMap(node => [...node.getClientRects()]).filter(onScreen);
        let visible = lines();
        if (!visible.length) {
          nodes[0].scrollIntoView({ block: "center", behavior: "instant" });
          nodes = parts();
          visible = lines();
          if (!visible.length) return null;
        }
        const left = Math.min(...visible.map(r => r.left)), top = Math.min(...visible.map(r => r.top));
        const right = Math.max(...visible.map(r => r.right)), bottom = Math.max(...visible.map(r => r.bottom));
        // A passage that fills the page is anchored by its first visible line.
        if (bottom - top > window.innerHeight * 0.5) {
          const first = visible[0];
          return { x: first.left, y: first.top, width: first.width, height: first.height };
        }
        return { x: left, y: top, width: right - left, height: bottom - top };
      };

      window.readerFlash = function (quote) {
        const index = pageIndex();
        const found = occurrences(index, quote).next().value;
        if (!found) return;
        const spans = found.flatMap(slice => {
          const node = index.nodes[slice.node];
          const parent = node.parentElement;
          if (parent.closest("math") || (!node.nodeValue.slice(slice.from, slice.to).trim() && parent.matches(CONTAINERS))) return [];
          return wrap(node, [{ from: slice.from, to: slice.to, className: "reader-flash" }]);
        });
        const target = spans[0] || index.nodes[found[0].node].parentElement;
        target.scrollIntoView({ block: "center" });
        if (window.readerTTSInvalidate) window.readerTTSInvalidate();
        setTimeout(() => {
          spans.forEach(unwrap);
          if (window.readerTTSInvalidate) window.readerTTSInvalidate();
        }, 1200);
      };

      // The text of `root` laid out like the parsed book text that re-anchoring searches:
      // one newline between blocks, a tab between cells. Also finds `range` in it.
      function contextOf(root, range) {
        let text = "", start = null, end = null;
        const breakLine = mark => {
          text = text.replace(/ +$/, "");
          if (text && !text.endsWith("\n") && !text.endsWith("\t")) text += mark;
        };
        (function walk(parent, pre) {
          for (let child = parent.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 3) {
              // Source line wraps outside <pre> are spaces.
              const flatten = value => pre ? value : value.replace(/[ \t]*[\r\n]\s*/g, " ");
              let value = flatten(child.nodeValue);
              let lead = 0;
              if (!pre && (!text || /[\n\t]$/.test(text))) {
                lead = value.length - value.replace(/^\s+/, "").length;
                value = value.slice(lead);
              }
              if (range.intersectsNode(child)) {
                const from = child === range.startContainer ? range.startOffset : 0;
                const to = child === range.endContainer ? range.endOffset : child.nodeValue.length;
                if (to > from && value) {
                  const place = offset => text.length + Math.min(Math.max(flatten(child.nodeValue.slice(0, offset)).length - lead, 0), value.length);
                  if (start === null) start = place(from);
                  end = place(to);
                }
              }
              text += value;
            } else if (child.nodeType === 1 && !child.matches(SKIP + ", .md-code-lang, .footnote-ref")) {
              const name = child.localName;
              if (name === "br") { text = text.replace(/ +$/, "") + "\n"; continue; }
              const cell = name === "td" || name === "th";
              const block = BLOCKS.has(name);
              if (cell) { if (child.previousElementSibling) text += "\t"; }
              else if (block) breakLine("\n");
              walk(child, pre || name === "pre");
              if (block && !cell) breakLine("\n");
            }
          }
        })(root, !!(root.closest && root.closest("pre")));
        // The parsed text of a section has no trailing line break.
        text = text.replace(/\n+$/, "");
        return start === null ? null : { text, start: Math.min(start, text.length), end: Math.min(end, text.length) };
      }

      window.readerSelection = function () {
        const sel = document.getSelection();
        if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
        const text = sel.toString();
        const range = sel.getRangeAt(0);
        // The offset is the range's own, so two equal words in one text node get different locations.
        const start = range.startContainer.nodeType === 3 ? range.startOffset : 0;
        const host = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
        const selector = "section[id^='spine-'], section[data-tts-section]";
        const section = host && host.closest ? host.closest(selector) : null;
        const index = section ? Number(section.dataset.index || section.dataset.ttsSection || 0) : 0;
        const box = range.getBoundingClientRect();
        let offset = start;
        if (section && section.dataset.anchor) {
          const before = document.createRange();
          before.selectNodeContents(section);
          before.setEnd(range.startContainer, range.startOffset);
          offset = before.toString().length;
        }
        const root = section && section.contains(range.startContainer) && section.contains(range.endContainer) ? section : document.body;
        const context = contextOf(root, range);
        let prefix = "", suffix = "", sentence = text;
        if (context) {
          // Never keep half of a surrogate pair at a cut.
          prefix = context.text.slice(Math.max(0, context.start - 40), context.start).replace(/^[\uDC00-\uDFFF]/, "");
          suffix = context.text.slice(context.end, context.end + 40).replace(/[\uD800-\uDBFF]$/, "");
          const from = context.text.lastIndexOf("\n", context.start - 1) + 1;
          const to = context.text.indexOf("\n", context.end);
          sentence = context.text.slice(from, to < 0 ? context.text.length : to).trim() || text;
        }
        return { text, index, rect: { x: box.left, y: box.top, width: box.width, height: box.height }, prefix, suffix, sentence, cfi: section && section.dataset.anchor ? "mdloc(s=" + index + ",a=" + section.dataset.anchor + ",o=" + offset + ",e=" + (offset + text.length) + ")" : "epubcfi(/6/" + ((index + 1) * 2) + "!/4,/1:" + start + ",/1:" + (start + text.length) + ")" };
      };
    })();
    """#

    /// Highlight hover and the inline note pill. Shared by the EPUB page and the Markdown page.
    static let css = #"""
    span[class^="reader-hl-"] { cursor: pointer; border-radius: 2px; transition: filter 0.12s ease; }
    span[class^="reader-hl-"]:hover { filter: brightness(0.94); }
    @media (prefers-color-scheme: dark) { span[class^="reader-hl-"]:hover { filter: brightness(1.12); } }
    .reader-glyph {
      display: inline-flex; align-items: center; justify-content: center; float: none;
      width: 15px; height: 15px; margin: 0 0 0 3px; padding: 0; box-sizing: border-box;
      vertical-align: super; line-height: 1; border-radius: 999px; cursor: pointer;
      border: 1px solid color-mix(in srgb, var(--hl-color, #888) 70%, transparent);
      background: color-mix(in srgb, var(--hl-color, #888) 26%, transparent);
      color: var(--hl-color, #888);
      transition: transform 0.12s ease, background 0.12s ease;
    }
    .reader-glyph:hover { transform: scale(1.16); background: color-mix(in srgb, var(--hl-color, #888) 40%, transparent); }
    .reader-glyph svg { width: 9px; height: 9px; fill: currentColor; }
    """#
}
