// Flutter <-> foliate-js bridge.
//
// Runs inside the WebView, served from http://127.0.0.1:<port>/reader/host.html.
// 127.0.0.1 is a "potentially trustworthy" origin, so this is a secure context and
// crypto.subtle is available -- foliate needs it to deobfuscate IDPF fonts.
//
// Security: the local server sends a strict Content-Security-Policy header. EPUB files
// can legally contain JavaScript, and this app will later pull books from OPDS/RSS feeds
// we do not control, so the CSP is what stops a malicious book from executing. Because
// foliate renders sections in blob: iframes, the parent CSP is inherited by them, and
// `script-src 'self'` blocks every inline/remote script inside a book.

import './foliate/view.js';
import { Overlayer } from './foliate/overlayer.js';

/* ------------------------------------------------------------------ transport */

const outbox = [];
let channelReady = false;

function flush() {
  if (!channelReady || !outbox.length) return;
  while (outbox.length) {
    const msg = outbox.shift();
    try {
      window.DshBridge.postMessage(msg);
    } catch (err) {
      // Channel vanished (page navigating / WebView tearing down): drop, do not re-queue
      // forever.
      outbox.length = 0;
      break;
    }
  }
}

function send(type, payload = {}) {
  outbox.push(JSON.stringify({ type, ...payload }));
  flush();
}

// The channel is injected by the host; poll briefly in case the page wins the race.
let channelTries = 0;
const channelTimer = setInterval(() => {
  channelTries += 1;
  if (window.DshBridge && typeof window.DshBridge.postMessage === 'function') {
    channelReady = true;
    clearInterval(channelTimer);
    flush();
    send('ready', { version: 1 });
  } else if (channelTries > 100) {
    clearInterval(channelTimer);
    console.warn('[bridge] DshBridge channel never appeared');
  }
}, 25);

/* ------------------------------------------------------------------ elements */

const boot = document.getElementById('boot');

function fail(message) {
  if (boot) {
    boot.classList.remove('hidden');
    boot.classList.add('error');
    boot.textContent = String(message);
  }
  send('error', { message: String(message) });
}

const view = document.createElement('foliate-view');
view.id = 'view';
document.body.appendChild(view);

/* --------------------------------------------------------------- annotations */

// [{ id, value: cfi, color, note, text }]
let annotations = [];
const byValue = new Map();
const byIndex = new Map();
const applied = new Set();

function reindex() {
  byValue.clear();
  byIndex.clear();
  for (const a of annotations) {
    if (!a || !a.value) continue;
    byValue.set(a.value, a);
    let index = null;
    try {
      index = view.resolveCFI(a.value)?.index ?? null;
    } catch (err) {
      console.warn('[bridge] cannot resolve CFI', a.value, err);
    }
    if (index === null || index === undefined) continue;
    if (!byIndex.has(index)) byIndex.set(index, []);
    byIndex.get(index).push(a);
  }
}

view.addEventListener('create-overlay', (e) => {
  const list = byIndex.get(e.detail.index);
  if (list) for (const a of list) view.addAnnotation(a);
});

view.addEventListener('draw-annotation', (e) => {
  const { draw, annotation } = e.detail;
  // Overlayer.highlight paints translucent rects; colour comes from the annotation,
  // opacity from the --overlayer-highlight-opacity var set in applyStyles().
  draw(Overlayer.highlight, { color: annotation.color || '#ffd54f' });
});

view.addEventListener('show-annotation', (e) => {
  const a = byValue.get(e.detail.value);
  send('annotationTapped', {
    id: a?.id ?? null,
    note: a?.note ?? null,
    text: a?.text ?? null,
    color: a?.color ?? null,
  });
});

view.addEventListener('external-link', (e) => {
  send('externalLink', { href: e.detail?.href_ ?? null });
});

/* ------------------------------------------------------------------ progress */

let lastRelocateSent = 0;
let pendingRelocate = null;
let relocateTimer = null;

view.addEventListener('relocate', (e) => {
  const d = e.detail || {};
  // NOTE: d.range is a live DOM Range and must never be serialized; only pick scalars.
  pendingRelocate = {
    cfi: d.cfi || null,
    fraction: typeof d.fraction === 'number' ? d.fraction : null,
    tocLabel: d.tocItem?.label ?? null,
    pageLabel: d.pageItem?.label ?? null,
    locationCurrent: d.location?.current ?? null,
    locationTotal: d.location?.total ?? null,
    atStart: !!d.atStart,
    atEnd: !!d.atEnd,
  };
  const now = Date.now();
  const since = now - lastRelocateSent;
  if (since >= 500) {
    lastRelocateSent = now;
    send('relocate', pendingRelocate);
  } else if (!relocateTimer) {
    relocateTimer = setTimeout(() => {
      relocateTimer = null;
      lastRelocateSent = Date.now();
      if (pendingRelocate) send('relocate', pendingRelocate);
    }, 500 - since);
  }
});

/* ----------------------------------------------------------------- selection */

let selTimer = null;
let lastSelKey = '';

view.addEventListener('load', (e) => {
  const { doc, index } = e.detail;
  if (boot) boot.classList.add('hidden');
  const onSelectionChanged = () => {
    if (selTimer) clearTimeout(selTimer);
    selTimer = setTimeout(() => reportSelection(doc, index), 150);
  };
  doc.addEventListener('selectionchange', onSelectionChanged);
  doc.addEventListener('pointerup', onSelectionChanged);
  doc.addEventListener('touchend', onSelectionChanged);
  send('sectionLoaded', { index });
});

function reportSelection(doc, index) {
  let sel = null;
  try {
    sel = doc.getSelection?.() ?? null;
  } catch (err) {
    return;
  }
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
    if (lastSelKey !== '') {
      lastSelKey = '';
      send('selectionCleared');
    }
    return;
  }
  const text = sel.toString().replace(/\s+/g, ' ').trim();
  if (!text) return;
  let cfi = null;
  try {
    cfi = view.getCFI(index, sel.getRangeAt(0));
  } catch (err) {
    console.warn('[bridge] getCFI failed', err);
  }
  if (!cfi) return;
  const key = `${cfi}|${text.length}`;
  if (key === lastSelKey) return;
  lastSelKey = key;
  send('selection', { cfi, text, index });
}

/* --------------------------------------------------------------- read styles */

// Injected into every section document via renderer.setStyles().
//
// The base size goes on <html>, and every element that carries body text is pinned to
// it in rem. This is not belt-and-braces. Real EPUBs routinely declare an absolute size
// on the text element itself -- `p { font-size: 10pt }` is extremely common (both the
// Wenshuoge editions and most Calibre output do it). An inherited value always loses to
// a declaration on the element itself, *even when the inherited one is !important*, so
// putting the size on <body> alone resized headings (which usually declare no size and
// therefore inherit) while leaving body text completely untouched. That was a real
// reported bug, found only on a real book, not on a synthetic one.
function buildStyles(opts) {
  const o = opts || {};
  const size = o.fontSize ?? 18;
  const fontFamily = o.fontFamily
    ? `"${o.fontFamily}", system-ui, "Noto Sans CJK SC", sans-serif`
    : 'system-ui, "Noto Sans CJK SC", "Source Han Sans SC", sans-serif';
  return `
    :root {
      --overlayer-highlight-opacity: ${o.highlightOpacity ?? 0.45};
    }
    html {
      font-size: ${size}px !important;
      color: ${o.color || '#1a1a1a'} !important;
      background: ${o.background || '#ffffff'} !important;
    }
    body {
      font-family: ${fontFamily} !important;
      font-size: 1rem !important;
      line-height: ${o.lineHeight ?? 1.7} !important;
      color: ${o.color || '#1a1a1a'} !important;
      background: ${o.background || '#ffffff'} !important;
      text-align: ${o.textAlign || 'justify'} !important;
      padding: 0 !important;
      margin: 0 !important;
      /* Hyphenation costs a dictionary lookup per word and buys nothing for CJK, which
         is the primary target here. Off by default. */
      -webkit-hyphens: none;
      hyphens: none;
    }

    /* Block-level text carriers: pinned to the root size so the book's own absolute
       sizes cannot win. */
    p, div, li, blockquote, dd, dt, td, th, figcaption, figure,
    section, article, aside, main, header, footer, pre, address, center {
      font-size: 1rem !important;
    }
    /* Inline runs follow whatever container they sit in. */
    span, em, strong, i, b, u, s, a, cite, q, code, kbd, samp, ruby {
      font-size: inherit !important;
    }
    /* Keep the deviations that actually carry meaning. */
    small { font-size: 0.85rem !important; }
    sub, sup { font-size: 0.72rem !important; }
    ruby rt { font-size: 0.5rem !important; }

    /* Headings keep a hierarchy, scaled off the same root size. */
    h1 { font-size: 1.70rem !important; }
    h2 { font-size: 1.45rem !important; }
    h3 { font-size: 1.25rem !important; }
    h4 { font-size: 1.12rem !important; }
    h5 { font-size: 1.00rem !important; }
    h6 { font-size: 0.92rem !important; }

    p { margin: 0 0 0.85em !important; }
    img, svg, video { max-width: 100% !important; height: auto !important; }
    a { color: ${o.linkColor || '#1565c0'} !important; }
    ::selection { background: ${o.selectionColor || 'rgba(21,101,192,.28)'}; }
  `;
}

function applyStyles(opts) {
  document.body.style.setProperty('--page-bg', (opts && opts.background) || '#ffffff');
  const css = buildStyles(opts);
  try {
    view.renderer?.setStyles?.(css);
  } catch (err) {
    console.warn('[bridge] setStyles failed', err);
  }
}

/* ------------------------------------------------------------- layout config */

function applyLayout(cfg) {
  const c = cfg || {};
  const r = view.renderer;
  if (!r || typeof r.setAttribute !== 'function') return;
  // foliate's paginator only accepts px lengths and a percentage gap.
  if (c.flow) r.setAttribute('flow', c.flow);
  if (c.gap != null) r.setAttribute('gap', `${c.gap}%`);
  if (c.margin != null) r.setAttribute('margin', `${Math.round(c.margin)}px`);
  if (c.maxInlineSize != null) r.setAttribute('max-inline-size', `${Math.round(c.maxInlineSize)}px`);
  if (c.maxColumnCount != null) r.setAttribute('max-column-count', String(c.maxColumnCount));
  if (c.animated != null) {
    if (c.animated) r.setAttribute('animated', '');
    else r.removeAttribute('animated');
  }
}

/* -------------------------------------------------------------- public API */

globalThis.dshReader = {
  async open(url) {
    try {
      if (boot) {
        boot.classList.remove('hidden', 'error');
        boot.textContent = '正在打开…';
      }
      await view.open(url);
      const md = view.book?.metadata ?? {};
      send('opened', {
        title: typeof md.title === 'string' ? md.title : null,
        language: md.language ?? null,
        isFixedLayout: !!view.isFixedLayout,
        sectionCount: view.book?.sections?.length ?? null,
      });
      send('toc', {
        items: (view.book?.toc ?? []).map((t) => ({ label: t.label, href: t.href })),
      });
    } catch (err) {
      fail(`无法打开这本书：${err?.message ?? err}`);
    }
  },

  // `target` must be a bare EPUB CFI string, or { fraction }, or null.
  // It must NOT be an object wrapping the CFI: view.init() runs the value through
  // resolveNavigation(), which only takes the CFI branch for a *string* (or a
  // number / { fraction }); anything else falls through to book.resolveHref().
  async restore(target) {
    try {
      await view.init({ lastLocation: target ?? null, showTextStart: !target });
    } catch (err) {
      console.warn('[bridge] restore failed', err, target);
      try { await view.goToTextStart(); } catch (_) {}
    }
  },

  async goTo(target) {
    try { await view.goTo(target); } catch (err) { fail(`跳转失败：${err?.message ?? err}`); }
  },

  async goToFraction(fraction) {
    try { await view.goToFraction(fraction); } catch (err) { console.warn(err); }
  },

  next() { try { view.next(); } catch (err) { console.warn(err); } },
  prev() { try { view.prev(); } catch (err) { console.warn(err); } },

  setAnnotations(list) {
    const next = Array.isArray(list) ? list : [];
    const nextValues = new Set(next.map((a) => a.value));

    // Retire highlights that no longer exist so deleted notes disappear immediately.
    for (const value of applied) {
      if (!nextValues.has(value)) {
        try { view.addAnnotation({ value }, true); } catch (err) { /* section may be unloaded */ }
      }
    }
    applied.clear();
    for (const value of nextValues) applied.add(value);

    annotations = next;
    reindex();
    for (const a of annotations) {
      try { view.addAnnotation(a); } catch (err) { /* applied when its section loads */ }
    }
  },

  async addAnnotation(annotation) {
    try {
      annotations = annotations.filter((a) => a.id !== annotation.id).concat([annotation]);
      reindex();
      await view.addAnnotation(annotation);
      return { ok: true, index: view.resolveCFI(annotation.value)?.index ?? null };
    } catch (err) {
      return { ok: false, error: String(err?.message ?? err) };
    }
  },

  async removeAnnotation(id) {
    const a = annotations.find((x) => x.id === id);
    if (!a) return { ok: false, error: 'not found' };
    annotations = annotations.filter((x) => x.id !== id);
    reindex();
    try { await view.addAnnotation({ value: a.value }, true); } catch (err) { /* ignore */ }
    return { ok: true };
  },

  async revealAnnotation(id) {
    const a = annotations.find((x) => x.id === id);
    if (!a) return { ok: false };
    try { await view.showAnnotation(a); } catch (err) { return { ok: false, error: String(err) }; }
    return { ok: true };
  },

  applyStyles,
  applyLayout,

  // Returns the current CFI so the host can persist progress before closing.
  currentLocation() {
    const d = view.lastLocation || {};
    return {
      cfi: d.cfi || null,
      fraction: typeof d.fraction === 'number' ? d.fraction : null,
      tocLabel: d.tocItem?.label ?? null,
    };
  },

  // Tells the host whether a text selection is currently active.
  selectionState() {
    for (const { doc, index } of view.renderer?.getContents?.() ?? []) {
      let sel = null;
      try { sel = doc.getSelection?.() ?? null; } catch (_) { continue; }
      if (sel && !sel.isCollapsed && sel.rangeCount > 0 && sel.toString().trim()) {
        let cfi = null;
        try { cfi = view.getCFI(index, sel.getRangeAt(0)); } catch (_) {}
        return { active: true, cfi, text: sel.toString().trim(), index };
      }
    }
    return { active: false };
  },

  clearSelection() {
    for (const { doc } of view.renderer?.getContents?.() ?? []) {
      try { doc.getSelection()?.removeAllRanges(); } catch (_) {}
    }
    lastSelKey = '';
  },
};

window.addEventListener('error', (e) => {
  send('scriptError', { message: String(e.message ?? e) });
});
window.addEventListener('unhandledrejection', (e) => {
  send('scriptError', { message: String(e.reason?.message ?? e.reason) });
});
