// Agent markdown built as DOM nodes (never innerHTML: agent text is untrusted), after the Mac reading view
// (MarkdownView.swift): headings, paragraphs (line breaks kept), bullet/ordered/task lists (nested), > quotes,
// code fences (also indented inside list items), GFM tables, --- rules; inline `code`, **bold**, *italic*,
// ~~strike~~ and http(s) links. Anything else stays plain text.

export function markdown(src: string): DocumentFragment {
  const out = document.createDocumentFragment();
  blocks(src.replace(/\r\n?/g, "\n").split("\n"), out);
  return out;
}

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$/;
const HEADING = /^ {0,3}(#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*$/;
const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^ {0,3}> ?/;
const ITEM = /^( *)([-*+]|\d{1,9}[.)])(\s+|$)(.*)$/;
const DELIM = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

const indentOf = (l: string) => l.length - l.trimStart().length;
const isTable = (lines: string[], i: number) => lines[i].includes("|") && i + 1 < lines.length && DELIM.test(lines[i + 1]) && lines[i + 1].includes("-");
const startsBlock = (lines: string[], i: number) =>
  FENCE.test(lines[i]) || HEADING.test(lines[i]) || RULE.test(lines[i]) || QUOTE.test(lines[i]) || ITEM.test(lines[i]) || isTable(lines, i);

function el<K extends keyof HTMLElementTagNameMap>(tag: K, ...kids: (Node | string)[]): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  e.append(...kids);
  return e;
}

function blocks(lines: string[], into: ParentNode): void {
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    let m: RegExpMatchArray | null;
    if ((m = line.match(FENCE))) {
      // The closing fence uses the same character, at least as long; the opening indent is taken off each line.
      const fence = m[1], ind = indentOf(line), code: string[] = [];
      const close = new RegExp(`^ {0,3}${fence[0] === "`" ? "`" : "~"}{${fence.length},}\\s*$`);
      for (i++; i < lines.length && !close.test(lines[i]); i++) code.push(lines[i].slice(Math.min(ind, indentOf(lines[i]))));
      i++;
      const c = el("code", code.join("\n"));
      if (m[2]) c.dataset.lang = m[2];
      into.append(el("pre", c));
    } else if ((m = line.match(HEADING))) {
      into.append(el(`h${m[1].length}` as "h1", inline(m[2] ?? "")));
      i++;
    } else if (RULE.test(line)) {
      into.append(el("hr"));
      i++;
    } else if (QUOTE.test(line)) {
      const inner: string[] = [];
      for (; i < lines.length && lines[i].trim() && (QUOTE.test(lines[i]) || !startsBlock(lines, i)); i++) inner.push(lines[i].replace(QUOTE, ""));
      const q = el("blockquote");
      blocks(inner, q);
      into.append(q);
    } else if (isTable(lines, i)) {
      i = table(lines, i, into);
    } else if (ITEM.test(line)) {
      i = list(lines, i, into);
    } else {
      const para: string[] = [];
      for (; i < lines.length && lines[i].trim() && (para.length === 0 || !startsBlock(lines, i)); i++) para.push(lines[i].trim());
      into.append(el("p", inline(para.join("\n"))));
    }
  }
}

// One list: items of the same kind (bullet or ordered) at this indent. An item owns the lines indented past its
// marker, blank lines inside it, and lazy continuation text; its content is parsed as blocks again (nesting).
function list(lines: string[], i: number, into: ParentNode): number {
  const first = lines[i].match(ITEM)!;
  const base = first[1].length, ordered = /\d/.test(first[2]);
  const ul = ordered ? el("ol") : el("ul");
  if (ordered && parseInt(first[2]) !== 1) ul.setAttribute("start", String(parseInt(first[2])));
  while (i < lines.length) {
    const m = lines[i].match(ITEM);
    if (!m || m[1].length < base || m[1].length > base + 3 || /\d/.test(m[2]) !== ordered) break;
    const content = m[3] ? base + m[2].length + Math.min(m[3].length, 4) : base + m[2].length + 1;
    const body = [m[4]];
    let lastBlank = false;
    for (i++; i < lines.length; i++) {
      const l = lines[i];
      if (!l.trim()) { body.push(""); lastBlank = true; continue; }
      const ind = indentOf(l);
      if (ind >= content) body.push(l.slice(content));
      else if (!lastBlank && ind > base && !ITEM.test(l)) body.push(l.trim());
      else if (!lastBlank && !startsBlock(lines, i)) body.push(l.trim());   // lazy continuation
      else if (ind > base && ITEM.test(l)) body.push(l.slice(Math.min(ind, content)));   // a nested list, under-indented
      else break;
      lastBlank = false;
    }
    while (body.length && !body[body.length - 1].trim()) body.pop();
    const li = el("li");
    const task = body[0].match(/^\[([ xX])\]\s+/);
    if (task) {
      li.className = "task";
      li.append(el("span", task[1] === " " ? "☐" : "☑"));
      body[0] = body[0].slice(task[0].length);
    }
    blocks(body, li);
    ul.append(li);
    // A blank line then something that is not an item of this list ends it.
    if (i < lines.length && !lines[i].trim()) {
      let j = i;
      while (j < lines.length && !lines[j].trim()) j++;
      const n = j < lines.length ? lines[j].match(ITEM) : null;
      if (!n || n[1].length !== base || /\d/.test(n[2]) !== ordered) break;
      i = j;
    }
  }
  into.append(ul);
  return i;
}

// A GFM table: header row, delimiter row (alignment), body rows until a blank line or a line without a pipe.
// Wrapped in its own box that scrolls sideways when the table is wider than the screen.
function table(lines: string[], i: number, into: ParentNode): number {
  const cells = (l: string) => l.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "").split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
  const head = cells(lines[i]);
  const aligns = cells(lines[i + 1]).map((d) => (d.startsWith(":") && d.endsWith(":") ? "center" : d.endsWith(":") ? "right" : ""));
  const row = (vals: string[], tag: "th" | "td") => {
    const tr = el("tr");
    head.forEach((_, c) => {
      const cell = el(tag, inline(vals[c] ?? ""));
      if (aligns[c]) cell.style.textAlign = aligns[c];
      tr.append(cell);
    });
    return tr;
  };
  const tbody = el("tbody");
  for (i += 2; i < lines.length && lines[i].trim() && lines[i].includes("|"); i++) tbody.append(row(cells(lines[i]), "td"));
  const wrap = el("div", el("table", el("thead", row(head, "th")), tbody));
  wrap.className = "table-wrap";
  into.append(wrap);
  return i;
}

export function inline(text: string): DocumentFragment {
  const out = document.createDocumentFragment();
  const re = /`([^`\n]+)`|\*\*(.+?)\*\*|__(.+?)__(?!\w)|~~(.+?)~~|\*([^*\s](?:[^*\n]*[^*\s])?)\*|(?<!\w)_([^_\s](?:[^_\n]*[^_\s])?)_(?!\w)|\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g;
  let at = 0;
  for (const m of text.matchAll(re)) {
    out.append(text.slice(at, m.index));
    if (m[1] !== undefined) out.append(el("code", m[1]));
    else if (m[2] !== undefined || m[3] !== undefined) out.append(el("strong", inline(m[2] ?? m[3])));
    else if (m[4] !== undefined) out.append(el("del", inline(m[4])));
    else if (m[5] !== undefined || m[6] !== undefined) out.append(el("em", inline(m[5] ?? m[6])));
    else {
      const a = el("a", m[7]);
      a.href = m[8];
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      out.append(a);
    }
    at = (m.index ?? 0) + m[0].length;
  }
  out.append(text.slice(at));
  return out;
}
