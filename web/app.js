'use strict';
const token = location.hash.slice(1) || sessionStorage.getItem('peon-token') || '';
sessionStorage.setItem('peon-token', token);
history.replaceState(null, '', location.pathname);
const cards = new Map();
const connection = document.querySelector('#connection');
let dragging = false;
let dismissing = false;
let dismissed = null;
async function api(path, data) {
  const response = await fetch(path, {method: data ? 'POST' : 'GET', headers: {
    'X-Peon-Token': token, ...(data ? {'Content-Type': 'application/json'} : {})
  }, ...(data ? {body: JSON.stringify(data)} : {})});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Request failed');
  return result;
}
document.querySelector('#dismiss').onclick = async () => {
  const session = navigation.session;
  if (!session || dismissing || !confirm('Close session ' + session + '? Its agents stop.')) return;
  dismissing = true;
  updateNavigation();
  const status = document.querySelector('#dismiss-status');
  status.hidden = false;
  status.classList.remove('error');
  status.textContent = 'Closing session ' + session;
  try {
    status.textContent = (await api('/api/dismiss', {session})).message;
    dismissed = session;
  }
  catch (error) { status.textContent = error.message; status.classList.add('error'); }
  finally { dismissing = false; updateNavigation(); }
};
function feedback(card, message, error = false) {
  card.el.querySelector('.feedback').textContent = message;
  card.el.querySelector('.feedback').classList.toggle('error', error);
}
function setSelection(card, text) {
  card.selected = text;
  card.el.querySelector('.copy').disabled = !text.trim();
  card.el.querySelector('.explain').disabled = !text.trim() || card.busy || card.closed;
  card.el.querySelector('.resume').hidden = !text || card.closed;
  card.el.querySelector('.discard').hidden = !card.closed;
  card.el.querySelector('.discard').disabled = card.busy;
  card.el.querySelector('form button').disabled = card.busy || card.closed;
  card.el.querySelector('.append').disabled = card.busy || card.closed;
  for (const button of card.el.querySelectorAll('.keys button')) button.disabled = card.busy || card.closed;
  card.el.querySelector('.selection-note').textContent = text ? 'Selection saved · updates paused' : '';
  card.el.querySelector('.state').textContent = card.closed ? 'Closed' : text ? 'Paused' : 'Live';
}
async function send(card, action, text, append = false) {
  if (card.closed || card.busy) return;
  const selectionRevision = card.selectionRevision;
  const draftRevision = card.draftRevision;
  card.busy = true;
  card.el.querySelector('form button').disabled = true;
  setSelection(card, card.selected);
  feedback(card, 'Sending to this agent…');
  try {
    const result = await api('/api/' + action, {pane: card.id, identity: card.latest.identity, ...(action === 'keys' ? {key: text} : {text}), ...(append ? {append: true} : {})});
    feedback(card, result.message);
    if (action === 'send') { card.appendText = null; card.el.querySelector('.append-action').hidden = true; }
    if (action === 'explain') {
      if (card.selected === text && card.selectionRevision === selectionRevision) { setSelection(card, ''); if (card.key === currentPane()) getSelection().removeAllRanges(); }
    } else if (action === 'send' && card.draftRevision === draftRevision && card.el.querySelector('textarea').value === text) card.el.querySelector('textarea').value = '';
  } catch (error) {
    feedback(card, error.message, true);
    if (action === 'send' && error.message.includes('holds typed text') && card.draftRevision === draftRevision && card.el.querySelector('textarea').value === text) {
      card.appendText = text;
      card.el.querySelector('.append-action').hidden = false;
    }
  }
  finally { card.busy = false; setSelection(card, card.selected); }
}
function inputHint(pane) {
  const markerRow = (pane.screen || '').split('\n').reverse().find(row => /[❯›]/.test(row));
  if (!markerRow) return '';
  const parsed = document.createElement('div');
  for (const row of pane.output.split('\n').reverse()) {
    if (!/[❯›]/.test(row)) continue;
    let hint = '', afterMarker = false;
    renderAnsi(parsed, row, '', (text, hinted) => {
      const marker = text.search(/[❯›]/);
      if (!afterMarker && marker >= 0) { afterMarker = true; text = text.slice(marker + 1); }
      if (afterMarker && hinted) hint += text;
    });
    if (/[❯›]/.test(parsed.textContent)) return parsed.textContent.trimEnd() === markerRow.trimEnd() ? hint.trim() : '';
  }
  return '';
}
function updateKeys(card) {
  const pane = card.latest;
  const labels = [];
  if (pane.menu) {
    // Claude's numbered menu rows are recognized; Codex and Copilot use the folded Keys controls.
    const rows = [...(pane.screen || '').matchAll(/^(?:[❯›] | {2})([1-9])\. (.+)$/gm)];
    let previous = null;
    for (const match of rows.reverse()) {
      const digit = Number(match[1]);
      if (previous !== null && digit !== previous - 1) break;
      labels.unshift([match[1], (match[1] + '. ' + match[2].trim()).slice(0, 40)]);
      if (digit === 1) break;
      previous = digit;
    }
    labels.push(['Enter', 'Enter'], ['Escape', 'Esc']);
  }
  const hint = inputHint(pane);
  if (hint) labels.push(['Tab', ('Tab: ' + hint).slice(0, 60)]);
  const signature = JSON.stringify(labels);
  if (signature === card.shortcutsRendered) return;
  card.shortcutsRendered = signature;
  const hasChoices = labels.some(([key]) => /^[1-9]$/.test(key));
  for (const button of card.el.querySelectorAll('.key-buttons button')) {
    const key = button.dataset.key;
    button.hidden = key === 'Tab' ? !!hint : /^[1-9]$/.test(key) ? hasChoices : pane.menu && (key === 'Enter' || key === 'Escape');
  }
  const buttons = labels.map(([key, label]) => {
    const button = document.createElement('button');
    button.type = 'button'; button.dataset.key = key; button.textContent = label;
    button.disabled = card.busy || card.closed;
    button.onclick = () => send(card, 'keys', key);
    return button;
  });
  card.el.querySelector('.key-shortcuts').replaceChildren(...buttons);
}
function createCard(pane) {
  const el = document.querySelector('#pane-template').content.firstElementChild.cloneNode(true);
  el.dataset.pane = pane.id;
  el.dataset.key = paneKey(pane);
  const card = {el, id: pane.id, key: paneKey(pane), lines: 1000, scrollTop: 0, fullHistory: false, selected: '', selectionRevision: 0, draftRevision: 0, appendText: null, busy: false, closed: false, unread: false, needsAnswer: false, latest: null, rendered: null, keysOpen: false};
  const fallbackKeys = el.querySelector('.key-buttons');
  fallbackKeys.prepend(fallbackKeys.querySelector('[data-key="Up"]'), fallbackKeys.querySelector('[data-key="Down"]'));
  const keysToggle = el.querySelector('.keys-toggle');
  keysToggle.onclick = () => {
    card.keysOpen = !card.keysOpen;
    keysToggle.setAttribute('aria-expanded', String(card.keysOpen));
    el.querySelector('.key-buttons').hidden = !card.keysOpen;
  };
  for (const button of el.querySelectorAll('.key-buttons button')) button.onclick = () => send(card, 'keys', button.dataset.key);
  const shortcuts = document.createElement('div');
  shortcuts.className = 'key-shortcuts';
  el.querySelector('.keys').append(shortcuts);
  el.querySelector('textarea').oninput = () => { card.draftRevision++; card.appendText = null; el.querySelector('.append-action').hidden = true; };
  el.querySelector('.append').onclick = () => { if (card.appendText !== null) send(card, 'send', card.appendText, true); };
  el.querySelector('textarea').onkeydown = event => {
    if (event.key === 'Enter' && event.shiftKey && !event.isComposing) {
      event.preventDefault(); el.querySelector('form').requestSubmit();
    }
  };
  el.querySelector('h2').textContent = pane.name;
  el.querySelector('.meta').textContent = pane.session + ' / ' + pane.id + ' / ' + pane.command;
  el.querySelector('.explain').onclick = () => send(card, 'explain', card.selected);
  el.querySelector('.output').onscroll = event => {
    const output = event.currentTarget;
    if (card.el.hidden || card.closed) return;
    const scrollingUp = output.scrollTop < card.scrollTop;
    card.scrollTop = output.scrollTop;
    if (output.scrollHeight - output.scrollTop - output.clientHeight < 40) card.lines = 1000;
    else if (scrollingUp && output.scrollTop < 200 && !card.selected && getSelection().isCollapsed && card.latest?.history > card.lines && card.latest.capturedLines === card.lines && card.lines < 200000) {
      card.lines += 1000;
    }
  };
  el.querySelector('.output').onkeydown = event => {
    if (event.ctrlKey || event.altKey || event.metaKey || event.isComposing || card.closed || card.busy) return;
    const key = {ArrowUp: 'Up', ArrowDown: 'Down', Enter: 'Enter', Escape: 'Escape'}[event.key] || (/^[1-9]$/.test(event.key) ? event.key : null);
    if (typeof key === 'string') { event.preventDefault(); send(card, 'keys', key); }
  };
  el.querySelector('.output').oncontextmenu = event => {
    if (document.querySelector('#right-click').checked && card.selected.trim() && !card.busy && !card.closed) {
      event.preventDefault(); send(card, 'explain', card.selected);
    }
  };
  el.querySelector('.copy').onclick = async () => {
    try { await navigator.clipboard.writeText(card.selected); feedback(card, 'Copied'); }
    catch {
      restoreSelection(el.querySelector(".output"), card.selected);
      feedback(card, 'Use ⌘ / Ctrl + C to copy the highlighted text.', true);
    }
  };
  el.querySelector('.resume').onclick = () => { setSelection(card, ''); getSelection().removeAllRanges(); };
  el.querySelector('.discard').onclick = () => {
    if (card.busy) return;
    el.remove(); cards.delete(card.key);
    reconcileNavigation(navigation.panes.filter(pane => paneKey(pane) !== card.key));
  };
  el.querySelector('form').onsubmit = event => {
    event.preventDefault();
    const text = el.querySelector('textarea').value;
    if (text.trim() && !card.busy) send(card, 'send', text);
  };
  document.querySelector('#panes').append(el);
  cards.set(card.key, card);
  return card;
}
document.addEventListener('pointerdown', event => { dragging = !!event.target.closest('.output'); });
document.addEventListener('pointerup', () => { dragging = false; });
document.addEventListener('pointercancel', () => { dragging = false; });
document.addEventListener('selectionchange', () => {
  const selection = getSelection();
  if (!selection.rangeCount || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  for (const card of cards.values()) {
    const output = card.el.querySelector('.output');
    if (output.contains(range.startContainer) && output.contains(range.endContainer)) {
      card.selectionRevision++;
      setSelection(card, selection.toString());
      return;
    }
  }
});
function updateOutput(card) {
  if (!card.latest || card.latest.capturedLines < card.lines || card.selected || dragging || card.el.hidden) return;
  const key = JSON.stringify([card.latest.output, card.latest.defaultStyle]);
  const fullHistory = card.latest.history <= card.latest.capturedLines;
  const preserveTop = card.fullHistory && fullHistory;
  card.fullHistory = fullHistory;
  if (key === card.rendered) return;
  const output = card.el.querySelector(".output");
  const atEnd = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
  const oldScrollTop = output.scrollTop;
  const fromBottom = output.scrollHeight - output.scrollTop;
  renderAnsi(output, card.latest.output, card.latest.defaultStyle);
  card.rendered = key;
  if (atEnd) output.scrollTop = output.scrollHeight;
  else output.scrollTop = preserveTop ? oldScrollTop : output.scrollHeight - fromBottom;
  card.scrollTop = output.scrollTop;
}
async function refresh() {
  try {
    const visible = cards.get(currentPane());
    const lines = visible && !visible.closed ? visible.lines : 1000;
    const query = lines > 1000 ? '?pane=' + encodeURIComponent(visible.id) + '&lines=' + lines : '';
    const {panes, initial} = await api("/api/panes" + query);
    connection.textContent = panes.length + " agent" + (panes.length === 1 ? "" : "s") + " connected";
    document.querySelector("#empty").hidden = !!panes.length;
    const keys = new Set(panes.map(paneKey));
    for (const pane of panes) {
      const card = cards.get(paneKey(pane)) || createCard(pane);
      if (card.closed) { card.closed = false; setSelection(card, card.selected); feedback(card, 'Agent reconnected'); }
      if (pane.role === 'manager' && card.latest && card.latest.output !== pane.output && card.key !== currentPane()) card.unread = true;
      card.needsAnswer = pane.menu;
      card.latest = {...pane, capturedLines: visible && visible.id === pane.id ? lines : 1000};
      updateKeys(card);
      card.el.querySelector("h2").textContent = pane.name;
      card.el.querySelector(".meta").textContent = pane.session + " / " + pane.role + " / " + pane.id;
      updateOutput(card);
    }
    for (const [key, card] of cards) {
      if (!keys.has(key)) {
        if (card.selected || card.el.querySelector('textarea').value || card.busy) {
          if (!card.closed) feedback(card, 'This agent closed. Copy your text or discard it.', true);
          card.closed = true;
          setSelection(card, card.selected);
          panes.push({...card.latest, closed: true});
        } else { card.el.remove(); cards.delete(key); }
      }
    }
    document.querySelector('#empty').hidden = !!panes.length;
    if (dismissed && !panes.some(pane => pane.session === dismissed && !pane.closed)) {
      if (navigation.session === dismissed) navigation.session = undefined;
      dismissed = null;
    }
    reconcileNavigation(panes, initial);
  } catch (error) { connection.textContent = error.message; }
  finally { setTimeout(refresh, 1200); }
}
refresh();
