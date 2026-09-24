import Foundation

/// `snapshot`: what an agent can see and act on, one element per line, each actionable element
/// stamped with a ref (data-wk-ref="e<n>") that `click`/`type`/`wait` accept in place of a selector.
/// Refs stick to their element across snapshots and are never reused within a tab (the counter
/// lives in the tab, so it survives navigations).
///
/// Values are shown as they are (reading API keys is the point). With --redact, secret-looking values
/// are masked in the page itself, hashed with an in-page SHA-256, so they never cross into this
/// process. Password inputs are never read, with or without --redact.

/// Finds an element by CSS selector, `text=<words>`, or a snapshot ref (`e7` / `ref=e7`), looking
/// through same-origin iframes and open shadow roots for refs. Shared by snapshot/click/type/wait.
let findJS = """
  const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) &&
    getComputedStyle(el).visibility !== 'hidden';
  const norm = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const label = el => norm(el.innerText || el.value || el.getAttribute('aria-label') || el.title);
  const clickables = () => [...document.querySelectorAll(
    'button, a, [role=button], [role=link], [role=menuitem], [role=option], [role=tab], input[type=submit], input[type=button], summary, label, [data-identifier], [onclick], [tabindex]'
  )].filter(visible);
  const refOf = sel => { const m = /^(?:ref=)?(e[0-9]+)$/.exec(sel.trim()); return m ? m[1] : null; };
  const deepRef = (root, ref) => {
    const hit = root.querySelector('[data-wk-ref="' + ref + '"]');
    if (hit) return hit;
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) { const h = deepRef(el.shadowRoot, ref); if (h) return h; }
      if (el.tagName === 'IFRAME') {
        let doc = null;
        try { doc = el.contentDocument; } catch (e) {}
        if (doc) { const h = deepRef(doc, ref); if (h) return h; }
      }
    }
    return null;
  };
  const find = sel => {
    const ref = refOf(sel);
    if (ref) {
      const el = deepRef(document, ref);
      if (!el || !el.isConnected) throw new Error('stale ref ' + ref + ': page changed since the snapshot — take a new one');
      return el;
    }
    if (!sel.startsWith('text=')) return document.querySelector(sel);
    const want = norm(sel.slice(5));
    const all = clickables();
    return all.find(el => label(el) === want)
      || all.filter(el => label(el).includes(want)).sort((a, b) => label(a).length - label(b).length)[0]
      || null;
  };
  const missing = sel => new Error('no element matches ' + sel + '. visible clickables: ' +
    JSON.stringify([...new Set(clickables().map(label).filter(Boolean))].slice(0, 25)));
  """

/// Arguments: startRef (Int), redactOn (Bool), maxChars (Int), asJSON (Bool).
/// Returns {output, nextRef, truncated}.
let snapshotJS = #"""
  // --- SHA-256, so a masked secret can be told apart from another without leaving the page
  const sha256hex = (str) => {
    const K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,
      0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
      0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,
      0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,
      0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
    const bytes = new TextEncoder().encode(str);
    const len = bytes.length, bitLen = len * 8;
    const padded = new Uint8Array(((len + 9 + 63) >> 6) << 6);
    padded.set(bytes); padded[len] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(padded.length - 4, bitLen >>> 0); dv.setUint32(padded.length - 8, Math.floor(bitLen / 2 ** 32));
    const H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
    const W = new Uint32Array(64);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let off = 0; off < padded.length; off += 64) {
      for (let i = 0; i < 16; i++) W[i] = dv.getUint32(off + i * 4);
      for (let i = 16; i < 64; i++) {
        const s0 = rotr(W[i-15], 7) ^ rotr(W[i-15], 18) ^ (W[i-15] >>> 3);
        const s1 = rotr(W[i-2], 17) ^ rotr(W[i-2], 19) ^ (W[i-2] >>> 10);
        W[i] = (W[i-16] + s0 + W[i-7] + s1) >>> 0;
      }
      let [a, b, c, d, e, f, g, h] = H;
      for (let i = 0; i < 64; i++) {
        const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + W[i]) >>> 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    return H.map(x => x.toString(16).padStart(8, '0')).join('');
  };

  // --- redaction
  const SECRET = /(?:sk_live_|sk_test_|sk-|bu_|ghp_|gho_|ghs_|github_pat_|xox[bpas]-|AKIA)[A-Za-z0-9_\-]{8,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9_\-+/=]{24,}/g;
  const looksSecret = (t) => {
    if (/^(sk_live_|sk_test_|sk-|bu_|ghp_|gho_|ghs_|github_pat_|xox[bpas]-|AKIA|eyJ)/.test(t)) return true;
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/.test(t)) return true;
    // a long run is a secret only if it mixes letters and digits (not a long word, not a long number)
    return /[A-Za-z]/.test(t) && /[0-9]/.test(t) && !/^[a-z]+$/.test(t);
  };
  const redact = (s) => !redactOn ? s : s.replace(SECRET, (t) =>
    looksSecret(t) ? `‹redacted len=${t.length} #${sha256hex(t).slice(0, 8)}›` : t);
  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();

  // --- visibility
  const hiddenStyle = (el) => {
    if (el.hidden || el.inert || el.getAttribute('aria-hidden') === 'true') return true;
    const st = el.ownerDocument.defaultView.getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || st.visibility === 'collapse') return true;
    return false;
  };
  const zeroSize = (el) => !(el.offsetWidth || el.offsetHeight || el.getClientRects().length);

  // --- roles and names
  const LANDMARK = { NAV: 'nav', MAIN: 'main', HEADER: 'header', FOOTER: 'footer', ASIDE: 'aside', FORM: 'form' };
  const LANDMARK_ROLES = { navigation: 'nav', main: 'main', banner: 'header', contentinfo: 'footer',
    complementary: 'aside', region: 'region', form: 'form', search: 'search' };
  const ACTION_ROLES = ['button','link','tab','menuitem','menuitemcheckbox','menuitemradio','checkbox','radio','switch','combobox','option','textbox','searchbox','slider','spinbutton'];
  const roleOf = (el) => {
    const explicit = (el.getAttribute('role') || '').split(' ')[0];
    if (explicit) return explicit;
    const tag = el.tagName;
    if (tag === 'A') return el.hasAttribute('href') ? 'link' : null;
    if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
    if (tag === 'SELECT') return 'select';
    if (tag === 'TEXTAREA') return 'textarea';
    if (tag === 'INPUT') {
      const t = (el.getAttribute('type') || 'text').toLowerCase();
      if (t === 'hidden') return null;
      if (['submit','button','reset','image'].includes(t)) return 'button';
      if (t === 'checkbox' || t === 'radio') return t;
      return 'input ' + t;
    }
    if (el.isContentEditable && el.getAttribute('contenteditable') !== null) return 'editable';
    return null;
  };
  const isAction = (el, role) => role && (ACTION_ROLES.includes(role) || role.startsWith('input ') ||
    ['select','textarea','editable'].includes(role));
  const textOfIds = (el, ids) => ids.split(/\s+/).map(id => { const n = el.ownerDocument.getElementById(id); return n ? n.textContent : ''; }).join(' ');
  const nameOf = (el) => {
    const by = el.getAttribute('aria-labelledby');
    if (by) { const t = clean(textOfIds(el, by)); if (t) return t; }
    const al = clean(el.getAttribute('aria-label')); if (al) return al;
    if (el.labels && el.labels.length) { const t = clean([...el.labels].map(l => l.innerText).join(' ')); if (t) return t; }
    const tag = el.tagName;
    if (!['INPUT','SELECT','TEXTAREA'].includes(tag)) {
      const t = clean(el.innerText || el.textContent); if (t) return t.slice(0, 120);
      const img = el.querySelector('img[alt]'); if (img && clean(img.alt)) return clean(img.alt);
    }
    if (tag === 'INPUT' && ['submit','button','reset'].includes((el.type || '').toLowerCase()) && el.value) return clean(el.value);
    const alt = clean(el.getAttribute('alt')); if (alt) return alt;
    const title = clean(el.getAttribute('title')); if (title) return title;
    const ph = clean(el.getAttribute('placeholder')); if (ph) return ph;
    return '';
  };

  // --- refs: keep the element's ref, else hand out the next never-used number
  let nextRef = startRef;
  const refFor = (el) => {
    let r = el.getAttribute('data-wk-ref');
    if (!r) { r = 'e' + (nextRef++); el.setAttribute('data-wk-ref', r); }
    else { const n = parseInt(r.slice(1), 10); if (n >= nextRef) nextRef = n + 1; }
    return r;
  };

  const hrefOf = (el) => {
    try {
      const u = new URL(el.href, location.href);
      return u.origin === location.origin ? (u.pathname + u.search + u.hash) : u.href;
    } catch (e) { return null; }
  };

  // --- nodes: {kind: 'group'|'action'|'heading'|'text', ...}; groups have children
  const actionNode = (el, role) => {
    const n = { kind: 'action', ref: refFor(el), role, name: redact(nameOf(el)) };
    const tag = el.tagName;
    const state = [];
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') state.push('disabled');
    if (el.required || el.getAttribute('aria-required') === 'true') state.push('required');
    const exp = el.getAttribute('aria-expanded'); if (exp) state.push(exp === 'true' ? 'expanded' : 'collapsed');
    if (el.getAttribute('aria-selected') === 'true') state.push('selected');
    if (role === 'checkbox' || role === 'radio' || role === 'switch') {
      const checked = tag === 'INPUT' ? el.checked : el.getAttribute('aria-checked') === 'true';
      n.checked = checked;
    }
    if (state.length) n.state = state;
    if (tag === 'INPUT' && (el.type || '').toLowerCase() === 'password') {
      n.value = '‹password›';                       // never read
    } else if (tag === 'SELECT') {
      const opt = el.options[el.selectedIndex];
      n.value = opt ? redact(clean(opt.label || opt.text)) : '';
      n.options = [...el.options].slice(0, 12).map(o => clean(o.label || o.text));
      if (el.options.length > 12) n.options.push(`… ${el.options.length - 12} more`);
    } else if ((tag === 'INPUT' && !['checkbox','radio','submit','button','reset','image','file'].includes((el.type || '').toLowerCase())) || tag === 'TEXTAREA') {
      n.value = redact(el.value || '');
      const ph = clean(el.getAttribute('placeholder'));
      if (ph && ph !== n.name) n.placeholder = redact(ph);
    } else if (role === 'editable') {
      n.value = redact(clean(el.innerText));
    }
    if (role === 'link') { const h = hrefOf(el); if (h) n.href = redact(h); }
    return n;
  };

  const dialogs = [];
  const isDialog = (el, role) => role === 'dialog' || role === 'alertdialog' || (el.tagName === 'DIALOG' && el.open);

  const walk = (node, out) => {
    for (const child of node.childNodes) visit(child, out);
  };
  const visit = (n, out) => {
    if (n.nodeType === 3) {
      const t = clean(n.textContent);
      if (t) out.push({ kind: 'text', text: redact(t) });
      return;
    }
    if (n.nodeType !== 1) return;
    const el = n;
    const tag = el.tagName;
    if (['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','HEAD','META','LINK','SVG'].includes(tag.toUpperCase())) return;
    if (hiddenStyle(el)) return;
    if (tag === 'SLOT') { for (const a of el.assignedNodes({ flatten: true })) visit(a, out); return; }
    const role = roleOf(el);
    if (isDialog(el, role)) {
      const d = { kind: 'group', label: 'dialog', name: redact(nameOf(el).slice(0, 80)), modal: el.getAttribute('aria-modal') === 'true' || (el.matches && (() => { try { return el.matches(':modal'); } catch (e) { return false; } })()), children: [] };
      walk(el.shadowRoot || el, d.children);
      dialogs.push(d);
      return;
    }
    if (tag === 'IFRAME') {
      let doc = null;
      try { doc = el.contentDocument; } catch (e) {}
      if (doc && doc.body) {
        const g = { kind: 'group', label: 'iframe', name: clean(el.title || el.name || ''), children: [] };
        walk(doc.body, g.children);
        out.push(g);
      } else {
        let origin = '?';
        try { origin = new URL(el.src, location.href).origin; } catch (e) {}
        out.push({ kind: 'text', text: `[iframe cross-origin ${origin}]`, alone: true });
      }
      return;
    }
    if (zeroSize(el) && !el.shadowRoot && tag !== 'DETAILS') return;
    if (isAction(el, role)) { out.push(actionNode(el, role)); return; }
    const h = /^H([1-6])$/.exec(tag);
    if (h || role === 'heading') {
      const level = h ? +h[1] : +(el.getAttribute('aria-level') || 2);
      const t = clean(el.innerText);
      if (t) out.push({ kind: 'heading', level, text: redact(t) });
      return;
    }
    if (tag === 'TR') {
      const cells = [...el.children].filter(c => !hiddenStyle(c));
      const hasAction = cells.some(c => c.querySelector('a[href],button,input,select,textarea,[role=button],[role=link]'));
      if (!hasAction) {
        const t = cells.map(c => clean(c.innerText)).filter(Boolean).join('  ');
        if (t) out.push({ kind: 'text', text: redact(t), row: true });
        return;
      }
    }
    // a <label>'s text is already its control's name: list only the control
    if (tag === 'LABEL' && el.control && !hiddenStyle(el.control)) {
      if (el.contains(el.control)) visit(el.control, out);
      return;
    }
    if (tag === 'IMG') { const alt = clean(el.alt); if (alt) out.push({ kind: 'text', text: `[img] ${redact(alt)}` }); return; }
    const lm = LANDMARK[tag] || LANDMARK_ROLES[role];
    if (lm) {
      const g = { kind: 'group', label: lm, name: '', children: [] };
      walk(el.shadowRoot || el, g.children);
      if (el.shadowRoot) walk(el, g.children);
      if (g.children.length) out.push(g);
      return;
    }
    if (el.shadowRoot) walk(el.shadowRoot, out); else walk(el, out);
  };

  const top = [];
  walk(document.body || document.documentElement, top);
  // modal dialogs first, then the page, then non-modal dialogs
  const roots = [...dialogs.filter(d => d.modal), ...top, ...dialogs.filter(d => !d.modal)];

  // merge adjacent text lines inside a parent (keeps output compact)
  const merge = (list) => {
    const out = [];
    for (const n of list) {
      if (n.children) n.children = merge(n.children);
      const prev = out[out.length - 1];
      if (n.kind === 'text' && prev && prev.kind === 'text' && !n.row && !prev.row && !n.alone && !prev.alone &&
          (prev.text.length + n.text.length) < 160) {
        prev.text += ' ' + n.text;
      } else out.push(n);
    }
    return out;
  };
  const tree = merge(roots);

  // --- lines with priorities: dialog 0 (never cut), actions/headings/groups 1, text 2
  const q = (s) => JSON.stringify(s);
  const lineOf = (n) => {
    if (n.kind === 'group') return `[${n.label}${n.name ? ' ' + q(n.name) : ''}]`;
    if (n.kind === 'heading') return '#'.repeat(n.level) + ' ' + n.text;
    if (n.kind === 'text') return n.text;
    let s = `[${n.ref}] ${n.role} ${q(n.name)}`;
    if (n.checked !== undefined) s += n.checked ? ' [x]' : ' [ ]';
    if (n.options) s += ` = ${q(n.value)} (options: ${n.options.join(', ')})`;
    else if (n.value !== undefined) s += ` value=${n.value === '‹password›' ? n.value : q(n.value)}`;
    if (n.placeholder) s += ` placeholder=${q(n.placeholder)}`;
    if (n.href) s += ` → ${n.href}`;
    if (n.state) s += ' ' + n.state.join(' ');
    return s;
  };
  const flat = [];
  const flatten = (list, depth, inDialog, parent) => {
    for (const n of list) {
      const dialog = inDialog || (n.kind === 'group' && n.label === 'dialog');
      const entry = { n, depth, parent, prio: dialog ? 0 : (n.kind === 'text' ? 2 : 1), text: '  '.repeat(depth) + lineOf(n), keep: true };
      flat.push(entry);
      if (n.children) flatten(n.children, depth + 1, dialog, entry);
    }
  };
  flatten(tree, 0, false, null);

  const header = [document.title || '(untitled)', location.href];
  let size = header.join('\n').length + flat.reduce((a, e) => a + e.text.length + 1, 0);
  const liveChildren = new Map();
  for (const e of flat) if (e.parent) liveChildren.set(e.parent, (liveChildren.get(e.parent) || 0) + 1);
  let truncated = false, droppedEls = 0, droppedChars = 0;
  for (const prio of [2, 1]) {
    for (let i = flat.length - 1; i >= 0 && size > maxChars - 80; i--) {
      const e = flat[i];
      if (!e.keep || e.prio !== prio) continue;
      if (liveChildren.get(e)) continue; // drop a group only once it's empty
      e.keep = false; truncated = true;
      size -= e.text.length + 1;
      droppedChars += e.text.length + 1;
      droppedEls++;
      if (e.parent) liveChildren.set(e.parent, liveChildren.get(e.parent) - 1);
    }
  }

  let output;
  if (asJSON) {
    const kept = new Set(flat.filter(e => e.keep).map(e => e.n));
    const toJSON = (list) => list.filter(n => kept.has(n)).map(n => {
      const o = {};
      if (n.kind === 'action') {
        o.ref = n.ref; o.role = n.role; o.name = n.name;
        if (n.value !== undefined) o.value = n.value;
        if (n.checked !== undefined) o.checked = n.checked;
        if (n.options) o.options = n.options;
        if (n.placeholder) o.placeholder = n.placeholder;
        if (n.href) o.href = n.href;
        if (n.state) o.state = n.state;
      } else if (n.kind === 'group') {
        o.role = n.label; if (n.name) o.name = n.name; if (n.modal) o.modal = true;
        o.children = toJSON(n.children);
      } else if (n.kind === 'heading') { o.role = 'heading'; o.level = n.level; o.name = n.text; }
      else { o.role = 'text'; o.name = n.text; }
      return o;
    });
    output = JSON.stringify({ title: document.title, url: location.href, truncated, nodes: toJSON(tree) });
  } else {
    const lines = [...header, ...flat.filter(e => e.keep).map(e => e.text)];
    if (truncated) lines.push(`… truncated: ${droppedEls} more elements, ${droppedChars} chars (raise --max-chars)`);
    output = lines.join('\n');
  }
  return { output, nextRef, truncated };
  """#
