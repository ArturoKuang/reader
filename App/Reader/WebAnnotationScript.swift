import Foundation

/// The page-side half of selections, highlights, margin notes, and quote flashes
/// for EPUB and Markdown. A quote is matched against the text of the whole page, so
/// it may span formatting elements, several text nodes, or several blocks.
enum WebAnnotationScript {
    static let source = #"""
    (function () {
      // Text Reader injects into the article; never part of a quote.
      const SKIP = "script, style, noscript, template, .reader-glyph, .reader-badge, .reader-copy";
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

      // The text node slices of each occurrence of `quote`, in document order.
      function* occurrences(index, quote) {
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
          yield slices;
        }
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
          for (const slices of occurrences(index, mark.quote)) {
            const fresh = [];
            slices.forEach(slice => {
              let free = [[slice.from, slice.to]];
              (claimed.get(slice.node) || []).forEach(taken => {
                free = free.flatMap(([from, to]) => [[from, Math.min(to, taken.from)], [Math.max(from, taken.to), to]].filter(([a, b]) => b > a));
              });
              free.forEach(([from, to]) => {
                if (wrappable(index.nodes[slice.node], from, to)) fresh.push({ node: slice.node, from, to, className: "reader-hl-" + (mark.color || 1) });
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

      window.readerMarginNotes = function (notes) {
        document.querySelectorAll(".reader-glyph").forEach(node => node.remove());
        const index = pageIndex();
        (notes || []).forEach(note => {
          const found = occurrences(index, note.quote).next().value;
          if (!found) return;
          const section = index.nodes[found[0].node].parentElement.closest("section") || document.body;
          const mark = document.createElement("button");
          mark.className = "reader-glyph";
          mark.dataset.id = note.id;
          mark.textContent = "●";
          mark.style.color = note.color || "#888";
          mark.title = (note.body || "").split("\n")[0];
          section.appendChild(mark);
        });
        if (window.readerTTSInvalidate) window.readerTTSInvalidate();
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
        const node = sel.anchorNode ? sel.anchorNode.textContent || "" : "";
        const start = Math.max(0, node.indexOf(text));
        const host = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement);
        const selector = "section[id^='spine-'], section[data-tts-section]";
        const section = host && host.closest ? host.closest(selector) : null;
        const index = section ? Number(section.dataset.index || section.dataset.ttsSection || 0) : 0;
        const range = sel.getRangeAt(0);
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
}
