import Foundation

// Offline stylesheet for rendered Markdown (SPEC.md Part 2, sections 3 and 4).
extension MarkdownHTMLRenderer {
    static let stylesheet = #"""
:root, body[data-theme="original"] {
  --bg: #ffffff;
  --fg: #1c1c1e;
  --fg-muted: #636366;
  --border: rgba(0, 0, 0, 0.10);
  --surface: #f5f5f7;
  --surface-elev: #efeff2;
  --accent: #007aff;
  --code-bg: #f4f5f7;
  --code-fg: #1f2328;
  /* Syntax tokens (Light) */
  --tok-kw: #9a348e;
  --tok-str: #116329;
  --tok-num: #0550ae;
  --tok-com: #6e7781;
  --tok-fn: #6639ba;
  --tok-type: #953800;
  --tok-op: #cf222e;
  --tok-prop: #0550ae;
  /* TTS tokens */
  --tts-sentence-bg: rgba(67, 83, 255, 0.08);
  --tts-word-bg: rgba(67, 83, 255, 0.24);
  --tts-word-ul: rgba(55, 68, 224, 0.72);
  --tts-word-fg: inherit;
}

@media (prefers-color-scheme: dark) {
  body[data-theme="original"] {
    --bg: #1e1e1e;
    --fg: #f2f2f7;
    --fg-muted: #98989d;
    --border: rgba(255, 255, 255, 0.12);
    --surface: #28282b;
    --surface-elev: #323236;
    --accent: #0a84ff;
    --code-bg: #252528;
    --code-fg: #e6edf3;
    --tok-kw: #ff7b72;
    --tok-str: #a5d6ff;
    --tok-num: #79c0ff;
    --tok-com: #8b949e;
    --tok-fn: #d2a8ff;
    --tok-type: #ffa657;
    --tok-op: #ff7b72;
    --tok-prop: #79c0ff;
    --tts-sentence-bg: rgba(129, 146, 255, 0.14);
    --tts-word-bg: rgba(129, 146, 255, 0.34);
    --tts-word-ul: rgba(165, 178, 255, 0.85);
    --tts-word-fg: #ffffff;
  }
}

body[data-theme="paper"] {
  --bg: #f4ecd8; --fg: #2b2118; --fg-muted: #6e5c4a;
  --border: rgba(43, 33, 24, 0.14); --surface: #ebe1c8; --surface-elev: #e3d6b8;
  --accent: #8b4c1c; --code-bg: #ebe1c8; --code-fg: #2b2118;
  --tts-sentence-bg: rgba(58, 78, 176, 0.09);
  --tts-word-bg: rgba(58, 78, 176, 0.23);
  --tts-word-ul: rgba(48, 66, 158, 0.72);
}

body[data-theme="quiet"] {
  --bg: #ececec; --fg: #1c1c1e; --fg-muted: #5c5c60;
  --border: rgba(0, 0, 0, 0.11); --surface: #e2e2e4; --surface-elev: #d9d9dc;
  --accent: #0066cc; --code-bg: #e3e3e6; --code-fg: #1c1c1e;
  --tts-sentence-bg: rgba(58, 76, 210, 0.09);
  --tts-word-bg: rgba(58, 76, 210, 0.24);
  --tts-word-ul: rgba(48, 64, 196, 0.75);
}

body[data-theme="night"] {
  --bg: #1c1c1e; --fg: #f2f2f7; --fg-muted: #98989d;
  --border: rgba(255, 255, 255, 0.12); --surface: #262629; --surface-elev: #303034;
  --accent: #0a84ff; --code-bg: #242427; --code-fg: #e6edf3;
  --tok-kw: #ff7b72; --tok-str: #a5d6ff; --tok-num: #79c0ff; --tok-com: #8b949e;
  --tok-fn: #d2a8ff; --tok-type: #ffa657; --tok-op: #ff7b72; --tok-prop: #79c0ff;
  --tts-sentence-bg: rgba(136, 152, 255, 0.14);
  --tts-word-bg: rgba(136, 152, 255, 0.34);
  --tts-word-ul: rgba(172, 184, 255, 0.86);
  --tts-word-fg: #ffffff;
}

/* Base Typography */
body {
  background: var(--bg); color: var(--fg);
  font-family: var(--font-family, -apple-system, BlinkMacSystemFont, sans-serif);
  font-size: calc(16px * var(--font-scale, 1));
  line-height: var(--line-height, 1.6);
  max-width: 720px; margin: 0 auto;
  padding: 36px var(--page-margin, 48px) 64px;
  text-align: var(--text-align, start);
  -webkit-font-smoothing: antialiased;
}
body.reader-tts-open { padding-bottom: 136px !important; }
h1, h2, h3, h4 { line-height: 1.25; font-weight: 650; margin: 1.4em 0 0.55em; letter-spacing: -0.015em; }
h1 { font-size: 1.85em; margin-top: 0.2em; }
h2 { font-size: 1.42em; padding-bottom: 0.25em; border-bottom: 1px solid var(--border); }
h3 { font-size: 1.18em; }
blockquote { margin: 1em 0; padding: 0.15em 0 0.15em 14px; border-left: 3px solid var(--border); color: var(--fg-muted); }
hr { border: 0; border-top: 1px solid var(--border); margin: 1.8em 0; }
img { max-width: 100%; height: auto; border-radius: 6px; }

/* 1. Collapsible YAML Frontmatter Card */
details.md-frontmatter {
  margin: 0 0 1.5em; background: var(--surface);
  border: 1px solid var(--border); border-radius: 10px;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 0.84em;
}
details.md-frontmatter > summary {
  list-style: none; cursor: pointer; padding: 8px 12px;
  color: var(--fg-muted); font-weight: 600; display: flex; align-items: center; gap: 6px;
}
details.md-frontmatter > summary::before { content: "▸"; font-size: 0.85em; transition: transform 140ms ease; }
details.md-frontmatter[open] > summary::before { transform: rotate(90deg); }
.md-fm-grid {
  display: grid; grid-template-columns: minmax(90px, 140px) 1fr; gap: 6px 12px;
  padding: 0 12px 10px; border-top: 1px solid var(--border); padding-top: 8px;
}
.md-fm-key { color: var(--fg-muted); font-weight: 500; overflow-wrap: anywhere; }
.md-fm-val { color: var(--fg); display: flex; flex-wrap: wrap; gap: 4px; }
.md-fm-chip { background: var(--surface-elev); border-radius: 999px; padding: 1px 8px; font-size: 0.92em; }

/* 2. Obsidian Callouts (Static & Foldable) */
.callout {
  --co: #0a84ff;
  margin: 1.1em 0; border-radius: 8px; border-left: 3px solid var(--co);
  background: color-mix(in srgb, var(--co) 9%, var(--bg));
  padding: 10px 14px;
}
.callout[data-callout="tip"], .callout[data-callout="hint"] { --co: #28a745; }
.callout[data-callout="warning"], .callout[data-callout="caution"] { --co: #d97706; }
.callout[data-callout="danger"], .callout[data-callout="error"], .callout[data-callout="bug"] { --co: #dc2626; }
.callout[data-callout="example"] { --co: #7c3aed; }
.callout[data-callout="quote"] { --co: #6e7781; }
.callout[data-callout="abstract"], .callout[data-callout="summary"] { --co: #0891b2; }
.callout[data-callout="success"], .callout[data-callout="check"] { --co: #16a34a; }
.callout[data-callout="question"] { --co: #ca8a04; }
.callout-title {
  display: flex; align-items: center; gap: 7px; font-weight: 600;
  color: var(--co); font-size: 0.95em; list-style: none;
}
details.callout > summary.callout-title { cursor: pointer; }
details.callout > summary.callout-title::after {
  content: "▸"; margin-left: auto; opacity: 0.7; transition: transform 140ms ease;
}
details.callout[open] > summary.callout-title::after { transform: rotate(90deg); }
.callout-content > :first-child { margin-top: 6px; }
.callout-content > :last-child { margin-bottom: 0; }

/* 3. Wikilinks */
a.md-wikilink {
  color: var(--accent); text-decoration: none;
  border-bottom: 1px dashed color-mix(in srgb, var(--accent) 55%, transparent);
}
a.md-wikilink:hover { border-bottom-style: solid; }
.md-wikilink--unresolved {
  color: var(--fg-muted); opacity: 0.65;
  border-bottom: 1px dotted var(--fg-muted); cursor: default;
}

/* 4. GFM Tables & Task Lists */
.md-table-wrap { overflow-x: auto; margin: 1.1em 0; }
table { width: 100%; border-collapse: collapse; font-size: 0.92em; }
th, td { padding: 7px 11px; border: 1px solid var(--border); text-align: left; }
th { background: var(--surface); font-weight: 600; }
tbody tr:nth-child(even) { background: color-mix(in srgb, var(--surface) 45%, transparent); }
ul.contains-task-list { list-style: none; padding-left: 0.3em; }
li.task-list-item { display: flex; align-items: baseline; gap: 8px; margin: 0.25em 0; }
li.task-list-item input[type="checkbox"] { accent-color: var(--accent); transform: translateY(1px); }
li.task-list-item.is-checked { color: var(--fg-muted); text-decoration: line-through; }

/* 5. Footnotes */
a.footnote-ref { font-size: 0.78em; vertical-align: super; color: var(--accent); text-decoration: none; padding: 0 2px; }
section.footnotes { margin-top: 2.2em; padding-top: 1em; border-top: 1px solid var(--border); font-size: 0.86em; color: var(--fg-muted); }
section.footnotes li { margin: 0.4em 0; scroll-margin-top: 24px; }
a.footnote-backref { text-decoration: none; color: var(--accent); margin-left: 4px; }

/* 6. Code Blocks & Syntax Tokens */
code {
  font-family: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
  font-size: 0.86em; background: var(--code-bg); color: var(--code-fg);
  padding: 0.14em 0.38em; border-radius: 4px;
}
pre {
  position: relative; background: var(--code-bg); border: 1px solid var(--border);
  border-radius: 8px; padding: 13px 15px; overflow-x: auto; line-height: 1.5; margin: 1.1em 0;
}
pre code { background: transparent; padding: 0; font-size: 0.85em; }
.md-code-lang {
  position: absolute; top: 6px; right: 10px; font-size: 11px;
  font-family: -apple-system, sans-serif; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.04em;
}
.tok-kw { color: var(--tok-kw); font-weight: 500; }
.tok-str { color: var(--tok-str); }
.tok-num { color: var(--tok-num); }
.tok-com { color: var(--tok-com); font-style: italic; }
.tok-fn { color: var(--tok-fn); }
.tok-type { color: var(--tok-type); }
.tok-op { color: var(--tok-op); }
.tok-prop { color: var(--tok-prop); }

/* 7. MathML */
math { font-family: "STIX Two Math", "Cambria Math", "Apple Symbols", math; color: var(--fg); }
math[display="block"] {
  display: block; overflow-x: auto; padding: 0.65em 0; margin: 0.9em 0; text-align: center;
}
.reader-tts-sentence { background: var(--tts-sentence-bg); border-radius: 3px; box-decoration-break: clone; -webkit-box-decoration-break: clone; transition: background 120ms ease; }
.reader-tts-word { background: var(--tts-word-bg); color: var(--tts-word-fg, inherit); border-radius: 3px; box-shadow: inset 0 -1.5px 0 var(--tts-word-ul); box-decoration-break: clone; -webkit-box-decoration-break: clone; }
::highlight(tts-sentence) { background-color: var(--tts-sentence-bg); }
::highlight(tts-word) { background-color: var(--tts-word-bg); color: var(--tts-word-fg, inherit); }
li.task-list-item > div { flex: 1; min-width: 0; }
"""#
}
