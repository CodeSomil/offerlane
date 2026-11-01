// Offerlane autofill engine. Injected into every frame; Swift calls window.__ja.<fn>(...).
// It fills fields and clicks what Swift asks for. It never submits, never touches CAPTCHAs and doesn't hide itself.
(() => {
  if (window.__ja) return;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const rnd = (a, b) => a + Math.random() * (b - a);
  let pace = 1;  // Swift sets <1 in self-tests
  const wait = (a, b) => sleep(rnd(a, b) * pace);
  const docs = () => {
    const out = [document];
    document.querySelectorAll('iframe').forEach(f => { try { if (f.contentDocument && f.contentDocument.body) out.push(f.contentDocument); } catch (e) {} });
    return out;
  };
  const txt = n => (n?.innerText || n?.textContent || '').trim();
  const vis = e => { if (!e) return false; const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
    return e.type == 'file' || (r.width > 0 && r.height > 0 && s.visibility != 'hidden' && s.display != 'none'); };
  const q = sel => { for (const d of docs()) { const e = d.querySelector(sel); if (e) return e; } return null; };
  const qa = sel => docs().flatMap(d => [...d.querySelectorAll(sel)]);
  const aid = id => q(`[data-automation-id="${id}"]`);
  const aidVis = id => qa(`[data-automation-id="${id}"]`).find(vis) || null;

  // ---- labels (ported from browser.py COLLECT) ----
  const lab = e => {
    const d = e.ownerDocument; let t = '';
    if (e.id) { const l = d.querySelector(`label[for="${CSS.escape(e.id)}"]`); if (l) t = txt(l); }
    if (!t && e.getAttribute('aria-labelledby')) t = e.getAttribute('aria-labelledby').split(' ').map(x => txt(d.getElementById(x))).join(' ');
    if (!t) t = e.getAttribute('aria-label') || '';
    if (!t) { const l = e.closest('label'); if (l) t = txt(l); }
    if (!t) { let p = e.parentElement; for (let k = 0; k < 5 && p && !t; k++, p = p.parentElement) {
      const l = p.querySelector('label,legend,[class*=label]'); if (l && !l.contains(e) && !l.querySelector('input,textarea,select')) t = txt(l); } }
    return (t || e.placeholder || e.name || '').replace(/\s+/g, ' ').slice(0, 300);
  };
  const grp = e => {
    const f = e.closest('fieldset'); if (f && f.querySelector('legend')) return txt(f.querySelector('legend'));
    let p = e.parentElement;
    for (let k = 0; k < 6 && p; k++, p = p.parentElement) {
      const c = [...p.querySelectorAll('label,legend,[class*=label],[class*=question],p,span')].find(n => !n.contains(e) && !n.querySelector('input') && !n.closest('label')
        && txt(n).length > 3 && p.querySelectorAll('input[type=radio],input[type=checkbox]').length > 1);
      if (c) return txt(c);
    }
    return '';
  };
  let counter = 0;
  const byIndex = i => q(`[data-ja="${i}"]`);

  function collect() {
    const out = [];
    for (const d of docs()) d.querySelectorAll('input,textarea,select').forEach(e => {
      const ty = (e.tagName == 'INPUT' ? (e.type || 'text') : e.tagName).toLowerCase();
      if (['hidden', 'submit', 'button', 'search', 'image', 'reset', 'password'].includes(ty) || !vis(e) || e.disabled || (e.readOnly && ty != 'file')
          || (ty != 'file' && e.tabIndex < 0 && e.getAttribute('role') != 'combobox')) return;
      if (/beecatcher|honeypot|hp_|trap/i.test((e.getAttribute('data-automation-id') || '') + ' ' + (e.name || '') + ' ' + (e.id || '')) || e.closest('[aria-hidden=true]')) return;
      if (e.getAttribute('data-automation-id') == 'searchBox') return;
      if (!e.dataset.ja) e.dataset.ja = ++counter;
      const i = +e.dataset.ja, L = lab(e);
      let fl = '';
      if (ty == 'file') { let p = e.parentElement; for (let k = 0; k < 5 && p && !fl; k++, p = p.parentElement) {
        const l = p.querySelector('label,[class*=label],legend,h3,h4'); if (l && txt(l).length > 2 && !/^attach/i.test(txt(l))) fl = txt(l); } }
      const g = ['radio', 'checkbox'].includes(ty) ? grp(e) : '';
      out.push({ i, type: ty, name: (e.name || '') + ' ' + (e.id || ''), flabel: fl, label: L, group: g, role: e.getAttribute('role') || '',
        required: e.required || e.getAttribute('aria-required') == 'true' || /\*\s*$/.test(L) || /\*/.test(g),
        value: e.tagName == 'SELECT' ? ((e.selectedIndex < 0 || (e.selectedIndex == 0 && /^\s*(select|choose|please|--|$)/i.test(e.options[0]?.text || ''))) ? '' : e.options[e.selectedIndex].text)
               : (ty == 'file' ? (e.files && e.files.length ? e.files[0].name : '') : (e.value || '')),
        checked: !!e.checked, options: e.tagName == 'SELECT' ? [...e.options].map(o => o.text.trim()) : null });
    });
    return out;
  }

  // ---- human-paced input ----
  function setNative(e, v) {
    const proto = e.tagName == 'TEXTAREA' ? HTMLTextAreaElement.prototype : e.tagName == 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, v);
  }
  const fire = (e, type, init = {}) => e.dispatchEvent(new (type.startsWith('key') ? KeyboardEvent : Event)(type, { bubbles: true, cancelable: true, ...init }));
  async function moveTo(e) {
    e.scrollIntoView({ block: 'center', inline: 'nearest' }); await wait(120, 300);
    const r = e.getBoundingClientRect(), tx = r.left + r.width * rnd(.3, .7), ty = r.top + r.height * rnd(.3, .7);
    const sx = rnd(0, innerWidth), sy = rnd(0, innerHeight), n = Math.floor(rnd(6, 14));
    for (let k = 1; k <= n; k++) {
      const x = sx + (tx - sx) * k / n, y = sy + (ty - sy) * k / n;
      (document.elementFromPoint(x, y) || document.body).dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: x, clientY: y }));
      await sleep(12 * pace);
    }
    e.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, clientX: tx, clientY: ty }));
  }
  async function hclick(e) { await moveTo(e); e.focus?.(); e.click(); await wait(400, 1000); }
  async function htype(e, text) {
    text = String(text); await moveTo(e); e.focus(); fire(e, 'focus'); await wait(100, 250);
    setNative(e, ''); fire(e, 'input');
    if (text.length > 100) { setNative(e, text); fire(e, 'input'); }   // long answers are pasted, like a person would
    else for (const ch of text) {
      fire(e, 'keydown', { key: ch }); setNative(e, e.value + ch); fire(e, 'input'); fire(e, 'keyup', { key: ch });
      await sleep(rnd(25, 70) * pace);
    }
    fire(e, 'change'); fire(e, 'blur'); e.blur?.(); await wait(200, 600);
  }

  const api = {
    setPace: p => { pace = p; return true; },
    collect,
    type: async (i, v) => { const e = byIndex(i); if (!e) return false; await htype(e, v); return true; },
    select: async (i, label) => { const e = byIndex(i); if (!e) return false; await moveTo(e);
      const o = [...e.options].find(o => o.text.trim() == label); if (!o) return false;
      setNative(e, o.value); fire(e, 'input'); fire(e, 'change'); await wait(350, 900); return true; },
    click: async i => { const e = byIndex(i); if (!e) return false; await hclick(e); return true; },
    comboType: async (i, v) => { const e = byIndex(i); if (!e) return false; await htype(e, v); await wait(700, 1200);
      fire(e, 'keydown', { key: 'Enter', code: 'Enter', keyCode: 13 }); return true; },
    upload: async (i, b64, name, mime) => { const e = byIndex(i); if (!e) return false;
      const bin = atob(b64), bytes = new Uint8Array(bin.length); for (let k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
      const dt = new DataTransfer(); dt.items.add(new File([bytes], name, { type: mime }));
      e.files = dt.files; fire(e, 'input'); fire(e, 'change'); await wait(1500, 2500); return e.files.length > 0; },
    uploadAid: async (id, b64, name, mime) => { const e = aid(id); if (!e) return false; e.dataset.ja ||= ++counter; return api.upload(+e.dataset.ja, b64, name, mime); },
    requiredRadioNames: () => [...new Set(qa('input[type=radio][required],input[type=radio][aria-required=true]')
      .filter(r => !r.ownerDocument.querySelector(`input[type=radio][name="${CSS.escape(r.name)}"]:checked`)).map(r => r.name))],

    // ---- page state ----
    text: () => docs().map(d => d.body?.innerText || '').join('\n').slice(0, 30000),
    url: () => location.href,
    exists: id => !!aid(id),
    visible: id => !!aidVis(id),
    anyVisible: sel => qa(sel).some(vis),
    count: sel => qa(sel).length,
    checked: id => !!aidVis(id)?.checked,
    clickAid: async id => { const e = aidVis(id); if (!e) return false; await hclick(e); return true; },
    typeAid: async (id, v) => { const e = aidVis(id); if (!e) return false; await htype(e, v); return true; },
    typeSel: async (sel, v) => { const e = qa(sel).find(vis); if (!e) return false; await htype(e, v); return true; },
    typeAllPasswords: async (v, max) => { const ps = qa('input[type=password]').filter(vis).slice(0, max); for (const p of ps) await htype(p, v); return ps.length; },
    aidText: id => txt(aidVis(id) || aid(id)),
    errors: () => qa('[data-automation-id="errorMessage"],[data-automation-id="inputError"]').filter(vis).map(txt),
    hasFormInputs: () => qa('input[type=file],input[type=email]').length > 0,

    // Visible buttons (and submit inputs): names in DOM order.
    buttons: () => qa('button,input[type=submit],input[type=button],[role=button]').filter(vis)
      .map((b, k) => { b.dataset.jab = k; return { k, name: (txt(b) || b.value || b.getAttribute('aria-label') || '').trim(), submit: b.type == 'submit' }; }),
    clickButton: async k => { const b = q(`[data-jab="${k}"]`); if (!b) return false; await hclick(b); return true; },
    // First visible button or link whose text matches the regex.
    clickMatching: async (rx, links) => { const re = new RegExp(rx, 'i');
      const e = qa(links ? 'button,a,[role=button],[role=link],input[type=submit]' : 'button,[role=button],input[type=submit]').filter(vis)
        .find(b => re.test((txt(b) || b.value || b.getAttribute('aria-label') || '').trim()));
      if (!e) return false; await hclick(e); return true; },
    hasMatching: (rx, links) => { const re = new RegExp(rx, 'i');
      return qa(links ? 'button,a,[role=button],[role=link]' : 'button,[role=button],input[type=submit]').filter(vis).some(b => re.test((txt(b) || b.value || '').trim())); },

    // ---- Workday custom controls ----
    listboxes: () => qa('button[aria-haspopup="listbox"]').filter(vis).map((b, k) => {
      b.dataset.jalb = k;
      const ff = b.closest('[data-automation-id^="formField"]'), l = ff?.querySelector('label');
      const L = (l ? txt(l) : (b.getAttribute('aria-label') || '')).trim();
      return { k, label: L, current: txt(b), required: L.includes('*') || /required/i.test(b.getAttribute('aria-label') || '') };
    }),
    openListbox: async k => { const b = q(`[data-jalb="${k}"]`); if (!b) return []; await hclick(b); await wait(500, 700);
      return qa('[role="listbox"] [role="option"]').filter(vis).map(txt); },
    chooseOption: async label => { const o = qa('[role="listbox"] [role="option"]').filter(vis).find(o => txt(o) == label); if (!o) return false; await hclick(o); await wait(300, 500); return true; },
    escape: () => { (document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return true; },
    searchBoxes: () => qa('[data-automation-id="searchBox"]').filter(vis).map((s, k) => {
      s.dataset.jasb = k; const ff = s.closest('[data-automation-id^="formField"]');
      return { k, label: ff?.querySelector('label') ? txt(ff.querySelector('label')) : 'source', selected: !!ff?.querySelector('[data-automation-id="selectedItem"]') };
    }),
    promptPick: async (k, v) => { const s = q(`[data-jasb="${k}"]`); if (!s) return false; await htype(s, v);
      fire(s, 'keydown', { key: 'Enter', code: 'Enter', keyCode: 13 }); await wait(1000, 1400);
      const o = qa('[data-automation-id="promptOption"],[role="option"]').find(vis); if (!o) return false; await hclick(o); return true; },

    banner: html => { let b = document.getElementById('ja-banner');
      if (!b) { b = document.createElement('div'); b.id = 'ja-banner'; document.body.prepend(b); }
      b.style.cssText = 'position:sticky;top:0;z-index:2147483647;background:#1d4ed8;color:#fff;font:14px/1.4 -apple-system,system-ui;padding:10px 14px;box-shadow:0 2px 8px #0004';
      b.innerHTML = html; return true; },
  };
  window.__ja = api;
})();
