// A small markdown subset for agent text, built as DOM nodes (never innerHTML): code fences, paragraphs (line breaks
// kept), `code`, **bold**, and http(s) links. Anything else stays plain text.

export function markdown(src: string): DocumentFragment {
  const out = document.createDocumentFragment();
  const parts = src.split(/^```[^\n]*\n?/m);
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = part.replace(/\n$/, "");
      pre.append(code);
      out.append(pre);
      return;
    }
    for (const block of part.split(/\n{2,}/)) {
      const text = block.replace(/^\n+|\n+$/g, "");
      if (!text) continue;
      const p = document.createElement("p");
      p.append(inline(text));
      out.append(p);
    }
  });
  return out;
}

export function inline(text: string): DocumentFragment {
  const out = document.createDocumentFragment();
  const re = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g;
  let at = 0;
  for (const m of text.matchAll(re)) {
    out.append(text.slice(at, m.index));
    if (m[1] !== undefined) {
      const c = document.createElement("code");
      c.textContent = m[1];
      out.append(c);
    } else if (m[2] !== undefined) {
      const b = document.createElement("strong");
      b.textContent = m[2];
      out.append(b);
    } else {
      const a = document.createElement("a");
      a.textContent = m[3];
      a.href = m[4];
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      out.append(a);
    }
    at = (m.index ?? 0) + m[0].length;
  }
  out.append(text.slice(at));
  return out;
}
