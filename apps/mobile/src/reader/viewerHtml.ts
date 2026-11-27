const shared = `
const OPACITY = 0.38;
function emit(message) {
  const raw = JSON.stringify(message);
  if (window.ReactNativeWebView) window.ReactNativeWebView.postMessage(raw);
}
function graphemeParts(text) {
  if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
    try {
      const parts = [];
      for (const piece of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)) {
        parts.push(piece.segment);
      }
      return parts;
    } catch (error) {
      /* Chromium has Segmenter; keep the hand-written walk if it throws. */
    }
  }
  const ZWJ = 0x200d;
  const points = [];
  for (let index = 0; index < text.length; ) {
    const codePoint = text.codePointAt(index) || 0;
    points.push(codePoint);
    index += codePoint > 0xffff ? 2 : 1;
  }
  const regional = (codePoint) => codePoint >= 0x1f1e6 && codePoint <= 0x1f1ff;
  const extendsCluster = (codePoint) =>
    /\\p{M}/u.test(String.fromCodePoint(codePoint)) ||
    (codePoint >= 0xfe00 && codePoint <= 0xfe0f) ||
    (codePoint >= 0xe0100 && codePoint <= 0xe01ef) ||
    (codePoint >= 0x1f3fb && codePoint <= 0x1f3ff);
  const parts = [];
  let cursor = 0;
  while (cursor < points.length) {
    let end = cursor + 1;
    if (regional(points[cursor]) && regional(points[cursor + 1])) end = cursor + 2;
    else {
      while (end < points.length) {
        const current = points[end];
        if (extendsCluster(current)) {
          end += 1;
          continue;
        }
        if (current === ZWJ && end + 1 < points.length) {
          end += 2;
          continue;
        }
        break;
      }
    }
    parts.push(String.fromCodePoint.apply(null, points.slice(cursor, end)));
    cursor = end;
  }
  return parts;
}
function lastGraphemes(text, count) {
  const parts = graphemeParts(text);
  return parts.slice(Math.max(0, parts.length - count)).join("");
}
function firstGraphemes(text, count) {
  return graphemeParts(text).slice(0, count).join("");
}
function plainText(root) {
  let text = "";
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) text += node.nodeValue || "";
  return text;
}
function pointIndex(root, target, offset) {
  let count = 0;
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    if (node === target) return count + offset;
    count += (node.nodeValue || "").length;
  }
  return count;
}
function rangeFromIndexes(root, start, end) {
  const doc = root.ownerDocument;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let seen = 0;
  let startNode = null;
  let startOffset = 0;
  let endNode = null;
  let endOffset = 0;
  let node;
  while ((node = walker.nextNode())) {
    const value = node.nodeValue || "";
    const next = seen + value.length;
    if (!startNode && next > start) {
      startNode = node;
      startOffset = start - seen;
    }
    if (next >= end) {
      endNode = node;
      endOffset = end - seen;
      break;
    }
    seen = next;
  }
  if (!startNode || !endNode) return null;
  const range = doc.createRange();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, Math.min(endOffset, (endNode.nodeValue || "").length));
  return range;
}
function findQuote(text, quote, prefix, suffix) {
  if (!quote) return null;
  function scan(requireContext) {
    let from = 0;
    while (from <= text.length) {
      const index = text.indexOf(quote, from);
      if (index < 0) return null;
      const before = text.slice(0, index);
      const after = text.slice(index + quote.length);
      const prefixOk = !prefix || before.endsWith(prefix);
      const suffixOk = !suffix || after.startsWith(suffix);
      if (requireContext) {
        if (prefixOk && suffixOk && (prefix || suffix)) return index;
      } else if ((!prefix && !suffix) || !prefixOk || !suffixOk) {
        return index;
      }
      from = index + Math.max(quote.length, 1);
    }
    return null;
  }
  const exact = scan(true);
  if (exact !== null) return exact;
  return scan(false);
}
function isWordChar(ch) {
  return /[0-9A-Za-z]/.test(ch) || ch === "'" || ch === "\\u2019" || ch === "-";
}
function wordRangeAt(doc, x, y) {
  const caret = doc.caretRangeFromPoint ? doc.caretRangeFromPoint(x, y) : null;
  if (!caret || !caret.startContainer || caret.startContainer.nodeType !== 3) return null;
  const text = caret.startContainer.nodeValue || "";
  let index = Math.min(caret.startOffset, Math.max(text.length - 1, 0));
  if (!isWordChar(text.charAt(index))) return null;
  let start = index;
  let end = index + 1;
  while (start > 0 && isWordChar(text.charAt(start - 1))) start -= 1;
  while (end < text.length && isWordChar(text.charAt(end))) end += 1;
  const range = doc.createRange();
  range.setStart(caret.startContainer, start);
  range.setEnd(caret.startContainer, end);
  return range;
}
function suppressNativeSelection(doc) {
  if (!doc || doc.__readerNoSelect) return;
  doc.__readerNoSelect = true;
  const style = doc.createElement("style");
  style.textContent = "html,body,body *{-webkit-user-select:none !important;user-select:none !important;-webkit-touch-callout:none !important;}";
  (doc.head || doc.documentElement).appendChild(style);
  doc.addEventListener("contextmenu", (event) => event.preventDefault());
  doc.addEventListener("selectstart", (event) => event.preventDefault());
}
function highlightIdAtPoint(x, y) {
  const marks = document.querySelectorAll(".mark[data-id]");
  for (const mark of marks) {
    const box = mark.getBoundingClientRect();
    if (x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) return mark.dataset.id;
  }
  return null;
}
function looksLikePath(value) {
  return /\/|\.(x?html?|xml)$/i.test(value);
}
function epubSectionLabel(raw, index, doc) {
  const heading = doc && (doc.querySelector("h1") && (doc.querySelector("h1").textContent || "").trim() || (doc.title || "").trim());
  const candidate = (heading || raw || "").trim();
  if (candidate && !looksLikePath(candidate)) return candidate;
  return "Chapter " + (index + 1);
}
function watchLongPress(doc, onRange, onTapHighlight) {
  suppressNativeSelection(doc);
  let timer = 0;
  let x = 0;
  let y = 0;
  let active = false;
  function clearTimer() {
    if (timer) {
      clearTimeout(timer);
      timer = 0;
    }
  }
  function cancel() {
    active = false;
    clearTimer();
  }
  function start(clientX, clientY) {
    cancel();
    x = clientX;
    y = clientY;
    active = true;
    timer = setTimeout(() => {
      active = false;
      timer = 0;
      const word = wordRangeAt(doc, x, y);
      if (word) onRange(word, x, y);
    }, 500);
  }
  function move(clientX, clientY) {
    if (!active) return;
    if (Math.abs(clientX - x) > 10 || Math.abs(clientY - y) > 10) cancel();
  }
  function end(clientX, clientY) {
    const awaiting = active && timer;
    const startX = x;
    const startY = y;
    cancel();
    if (!awaiting) return;
    if (Math.abs(clientX - startX) > 10 || Math.abs(clientY - startY) > 10) return;
    if (typeof onTapHighlight === "function") onTapHighlight(startX, startY);
  }
  doc.addEventListener("touchstart", (event) => {
    const touch = event.touches && event.touches[0];
    if (!touch) return;
    start(touch.clientX, touch.clientY);
  }, { passive: true });
  doc.addEventListener("touchmove", (event) => {
    const touch = event.touches && event.touches[0];
    if (!touch) return;
    move(touch.clientX, touch.clientY);
  }, { passive: true });
  doc.addEventListener("touchend", (event) => {
    const touch = event.changedTouches && event.changedTouches[0];
    end(touch ? touch.clientX : x, touch ? touch.clientY : y);
  });
  doc.addEventListener("touchcancel", cancel);
  doc.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "touch") return;
    start(event.clientX, event.clientY);
  });
  doc.addEventListener("pointermove", (event) => {
    if (event.pointerType === "touch") return;
    move(event.clientX, event.clientY);
  });
  doc.addEventListener("pointerup", (event) => {
    if (event.pointerType === "touch") return;
    end(event.clientX, event.clientY);
  });
  doc.addEventListener("pointercancel", (event) => {
    if (event.pointerType === "touch") return;
    cancel();
  });
}
function rgba(hex) {
  const value = parseInt(hex.slice(1), 16);
  return "rgba(" + ((value >> 16) & 255) + "," + ((value >> 8) & 255) + "," + (value & 255) + "," + OPACITY + ")";
}
`;

export function pdfViewerHtml(): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  html, body { margin: 0; background: #f6f5f3; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
  #pages { padding: 12px 0 120px; }
  .page { position: relative; margin: 0 auto 16px; background: white; box-shadow: 0 1px 4px rgba(0,0,0,.12); }
  .page > canvas { display: block; width: 100%; height: 100%; }
  /* pdf.js 4.10 sizes spans as calc(var(--scale-factor) * Npx) and then scale(1/minFontSize). --scale-factor is the viewport scale, set on each page. */
  .textLayer { position: absolute; text-align: initial; inset: 0; overflow: hidden; line-height: 1; -webkit-text-size-adjust: none; text-size-adjust: none; transform-origin: 0 0; z-index: 2; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
  .textLayer :is(span, br) { color: transparent; position: absolute; white-space: pre; transform-origin: 0% 0%; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
  .marks { position: absolute; inset: 0; z-index: 1; pointer-events: none; }
  .mark { position: absolute; border-radius: 2px; }
</style>
</head>
<body>
<div id="pages"></div>
<script>
if (typeof Promise.try !== "function") {
  Promise.try = function (callbackfn) {
    "use strict";
    if (typeof callbackfn !== "function") {
      throw new TypeError("Promise.try requires a function");
    }
    var args = Array.prototype.slice.call(arguments, 1);
    return new Promise(function (resolve) {
      resolve(callbackfn.apply(undefined, args));
    });
  };
}
</script>
<script type="module">
import * as pdfjs from "./pdfjs/pdf.min.mjs";
${shared}
const pages = [];
const highlights = new Map();
function pageRecord(element) {
  return pages.find((page) => page.element === element);
}
function paint(highlight, ignorePageHint) {
  highlights.set(highlight.id, highlight);
  let painted = 0;
  for (const page of pages) {
    const marks = page.element.querySelector(".marks");
    marks.querySelectorAll('[data-id="' + highlight.id + '"]').forEach((node) => node.remove());
    if (!ignorePageHint && highlight.page && page.pageNumber !== highlight.page) continue;
    const index = findQuote(page.text, highlight.quote, highlight.prefix, highlight.suffix);
    if (index === null) continue;
    const layer = page.textLayer;
    const range = rangeFromIndexes(layer, index, index + highlight.quote.length);
    if (!range) continue;
    const box = page.element.getBoundingClientRect();
    for (const rect of range.getClientRects()) {
      const mark = document.createElement("div");
      mark.className = "mark";
      mark.dataset.id = highlight.id;
      mark.style.left = (rect.left - box.left) + "px";
      mark.style.top = (rect.top - box.top) + "px";
      mark.style.width = rect.width + "px";
      mark.style.height = rect.height + "px";
      mark.style.background = rgba(highlight.hex);
      marks.append(mark);
      painted += 1;
    }
  }
  return painted > 0;
}
function pdfHintResolves(highlight) {
  if (!highlight.page) return false;
  const page = pages.find((item) => item.pageNumber === highlight.page);
  if (!page) return false;
  return findQuote(page.text, highlight.quote, highlight.prefix, highlight.suffix) !== null;
}
function restoreHighlight(highlight) {
  if (pdfHintResolves(highlight) && paint(highlight)) return;
  const located = locate(highlight, "restore");
  if (located.found) {
    const updated = Object.assign({}, highlight, {
      page: located.page,
      section: located.section,
      prefix: located.prefix,
      suffix: located.suffix,
      rects: located.rects && located.rects.length ? located.rects : highlight.rects,
    });
    paint(updated, true);
    emit(located);
  } else {
    paint(highlight, true);
  }
}
function removeHighlight(id) {
  highlights.delete(id);
  document.querySelectorAll('[data-id="' + id + '"]').forEach((node) => node.remove());
}
function locate(request) {
  for (const page of pages) {
    const index = findQuote(page.text, request.quote, request.prefix, request.suffix);
    if (index === null) continue;
    const range = rangeFromIndexes(page.textLayer, index, index + request.quote.length);
    const rects = [];
    if (range) {
      const box = page.element.getBoundingClientRect();
      for (const rect of range.getClientRects()) {
        const [x1, y1] = page.viewport.convertToPdfPoint(rect.left - box.left, rect.top - box.top);
        const [x2, y2] = page.viewport.convertToPdfPoint(rect.right - box.left, rect.bottom - box.top);
        rects.push([Math.min(x1, x2), Math.min(y1, y2), Math.max(x1, x2), Math.max(y1, y2)]);
      }
    }
    const before = page.text.slice(0, index);
    const after = page.text.slice(index + request.quote.length);
    return {
      type: "located",
      id: request.id,
      found: true,
      page: page.pageNumber,
      section: "Page " + page.pageNumber,
      prefix: lastGraphemes(before, 80),
      suffix: firstGraphemes(after, 80),
      rects,
      reason: request.reason || "request",
    };
  }
  return { type: "located", id: request.id, found: false, prefix: request.prefix, suffix: request.suffix, rects: [], reason: request.reason || "request" };
}
function selectionFrom(range) {
  const pageElement = (range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement).closest(".page");
  const page = pages.find((item) => item.element === pageElement);
  if (!page) return;
  const start = pointIndex(page.textLayer, range.startContainer, range.startOffset);
  const end = pointIndex(page.textLayer, range.endContainer, range.endOffset);
  const quote = page.text.slice(Math.min(start, end), Math.max(start, end));
  if (!quote.trim()) return;
  const before = page.text.slice(0, Math.min(start, end));
  const after = page.text.slice(Math.max(start, end));
  const box = page.element.getBoundingClientRect();
  const rects = [];
  for (const rect of range.getClientRects()) {
    const [x1, y1] = page.viewport.convertToPdfPoint(rect.left - box.left, rect.top - box.top);
    const [x2, y2] = page.viewport.convertToPdfPoint(rect.right - box.left, rect.bottom - box.top);
    rects.push([Math.min(x1, x2), Math.min(y1, y2), Math.max(x1, x2), Math.max(y1, y2)]);
  }
  emit({
    type: "selection",
    quote,
    before,
    after,
    page: page.pageNumber,
    section: "Page " + page.pageNumber,
    rects,
  });
}
async function openPdf(base64, workerSource) {
  const blob = new Blob([workerSource], { type: "text/javascript" });
  pdfjs.GlobalWorkerOptions.workerSrc = URL.createObjectURL(blob);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  const pdf = await pdfjs.getDocument({ data: bytes }).promise;
  const host = document.getElementById("pages");
  host.replaceChildren();
  pages.length = 0;
  const slices = [];
  const width = Math.max(document.documentElement.clientWidth - 24, 280);
  for (let number = 1; number <= pdf.numPages; number += 1) {
    const pdfPage = await pdf.getPage(number);
    const unscaled = pdfPage.getViewport({ scale: 1, rotation: 0 });
    const viewport = pdfPage.getViewport({ scale: width / unscaled.width, rotation: 0 });
    const element = document.createElement("div");
    element.className = "page";
    element.style.width = viewport.width + "px";
    element.style.height = viewport.height + "px";
    element.style.setProperty("--scale-factor", String(viewport.scale));
    const canvas = document.createElement("canvas");
    const pixelRatio = window.devicePixelRatio || 1;
    canvas.width = Math.floor(viewport.width * pixelRatio);
    canvas.height = Math.floor(viewport.height * pixelRatio);
    canvas.style.width = viewport.width + "px";
    canvas.style.height = viewport.height + "px";
    element.append(canvas);
    const textLayer = document.createElement("div");
    textLayer.className = "textLayer";
    element.append(textLayer);
    const marks = document.createElement("div");
    marks.className = "marks";
    element.append(marks);
    host.append(element);
    const renderContext = { canvasContext: canvas.getContext("2d"), viewport, canvas };
    if (pixelRatio !== 1) renderContext.transform = [pixelRatio, 0, 0, pixelRatio, 0, 0];
    await pdfPage.render(renderContext).promise;
    const content = await pdfPage.getTextContent();
    await new pdfjs.TextLayer({ textContentSource: content, container: textLayer, viewport }).render();
    const text = plainText(textLayer);
    pages.push({ pageNumber: number, element, textLayer, viewport, text });
    slices.push({ page: number, section: "Page " + number, text });
  }
  emit({ type: "corpus", slices });
  watchLongPress(document, (range) => selectionFrom(range), (clientX, clientY) => {
    const id = highlightIdAtPoint(clientX, clientY);
    if (id) emit({ type: "open-highlight", id });
  });
}
window.__hostMessage = async (raw) => {
  const message = JSON.parse(raw);
  try {
    if (message.type === "open-pdf") await openPdf(message.base64, message.workerSource);
    else if (message.type === "restore") message.highlights.forEach(restoreHighlight);
    else if (message.type === "paint") paint(message.highlight);
    else if (message.type === "remove") removeHighlight(message.id);
    else if (message.type === "locate") emit(locate(Object.assign({ reason: "request" }, message)));
  } catch (error) {
    emit({ type: "error", message: String(error && error.message || error) });
  }
};
emit({ type: "ready", format: "pdf" });
</script>
</body>
</html>`;
}

export function epubViewerHtml(): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  html, body, foliate-view { margin: 0; height: 100%; background: #f6f5f3; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
  foliate-view { display: block; width: 100%; --overlayer-highlight-opacity: 0.38; }
</style>
</head>
<body>
<script type="module">
import "./foliate-js/view.js";
import { Overlayer } from "./foliate-js/overlayer.js";
${shared}
const view = document.createElement("foliate-view");
document.body.append(view);
const highlights = new Map();
let sections = [];
async function paint(highlight) {
  const previous = highlights.get(highlight.id);
  if (previous && previous.cfi && previous.cfi !== highlight.cfi) {
    view.deleteAnnotation({ value: previous.cfi }).catch(() => {});
  }
  highlights.set(highlight.id, highlight);
  if (!highlight.cfi) return false;
  try {
    const result = await view.addAnnotation({ value: highlight.cfi, color: highlight.hex });
    return !!result;
  } catch (error) {
    return false;
  }
}
async function restoreHighlight(highlight) {
  let painted = false;
  if (highlight.cfi) painted = await paint(highlight);
  if (painted) return;
  const located = await locate(Object.assign({ reason: "restore" }, highlight));
  if (located.found && located.cfi) {
    const updated = Object.assign({}, highlight, {
      cfi: located.cfi,
      section: located.section,
      prefix: located.prefix,
      suffix: located.suffix,
    });
    await paint(updated);
    emit(located);
  } else if (highlight.cfi) {
    await paint(highlight);
  }
}
view.addEventListener("draw-annotation", (event) => {
  event.detail.draw(Overlayer.highlight, { color: event.detail.annotation.color });
});
view.addEventListener("create-overlay", () => {
  for (const highlight of highlights.values()) paint(highlight);
});
async function sectionDocs() {
  const docs = [];
  for (let index = 0; index < view.book.sections.length; index += 1) {
    const section = view.book.sections[index];
    if (section.linear === "no") continue;
    const doc = await section.createDocument();
    const text = plainText(doc.body);
    docs.push({ index, doc, text, section: epubSectionLabel(section.id, index, doc) });
  }
  return docs;
}
async function locate(request) {
  const docs = sections.length ? sections : await sectionDocs();
  for (const item of docs) {
    const index = findQuote(item.text, request.quote, request.prefix, request.suffix);
    if (index === null) continue;
    const range = rangeFromIndexes(item.doc.body, index, index + request.quote.length);
    const cfi = range ? view.getCFI(item.index, range) : undefined;
    const before = item.text.slice(0, index);
    const after = item.text.slice(index + request.quote.length);
    return {
      type: "located",
      id: request.id,
      found: true,
      cfi,
      section: item.section,
      prefix: lastGraphemes(before, 80),
      suffix: firstGraphemes(after, 80),
      rects: [],
      reason: request.reason || "request",
    };
  }
  return { type: "located", id: request.id, found: false, prefix: request.prefix, suffix: request.suffix, rects: [], reason: request.reason || "request" };
}
view.addEventListener("load", (event) => {
  const { doc, index } = event.detail;
  const known = sections.find((item) => item.index === index);
  const text = known ? known.text : plainText(doc.body);
  watchLongPress(doc, (range) => {
    const start = pointIndex(doc.body, range.startContainer, range.startOffset);
    const end = pointIndex(doc.body, range.endContainer, range.endOffset);
    const quote = text.slice(Math.min(start, end), Math.max(start, end));
    if (!quote.trim()) return;
    emit({
      type: "selection",
      quote,
      before: text.slice(0, Math.min(start, end)),
      after: text.slice(Math.max(start, end)),
      cfi: view.getCFI(index, range),
      section: known ? known.section : epubSectionLabel("", index, doc),
      rects: [],
    });
  });
});
view.addEventListener("show-annotation", (event) => {
  const cfi = event.detail && event.detail.value;
  if (!cfi) return;
  for (const highlight of highlights.values()) {
    if (highlight.cfi === cfi) {
      emit({ type: "open-highlight", id: highlight.id });
      return;
    }
  }
});
async function openEpub(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  const file = new File([bytes], "book.epub", { type: "application/epub+zip" });
  await view.open(file);
  await view.init({ showTextStart: true });
  sections = await sectionDocs();
  emit({
    type: "corpus",
    slices: sections.map((item) => ({ spineIndex: item.index, section: item.section, text: item.text })),
  });
}
window.__hostMessage = async (raw) => {
  const message = JSON.parse(raw);
  try {
    if (message.type === "open-epub") await openEpub(message.base64);
    else if (message.type === "restore") {
      for (const highlight of message.highlights) await restoreHighlight(highlight);
    }
    else if (message.type === "paint") await paint(message.highlight);
    else if (message.type === "remove") {
      const current = highlights.get(message.id);
      highlights.delete(message.id);
      if (current && current.cfi) view.deleteAnnotation({ value: current.cfi }).catch(() => {});
    }
    else if (message.type === "locate") emit(await locate(Object.assign({ reason: "request" }, message)));
  } catch (error) {
    emit({ type: "error", message: String(error && error.message || error) });
  }
};
emit({ type: "ready", format: "epub" });
</script>
</body>
</html>`;
}
