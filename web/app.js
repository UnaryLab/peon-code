'use strict';
const token = location.hash.slice(1) || sessionStorage.getItem('peon-token') || '';
sessionStorage.setItem('peon-token', token);
history.replaceState(null, '', location.pathname);
const cards = new Map();
const BOX_WAIT_MS = 10000;
const connection = document.querySelector('#connection');
const cellMeasure = document.createElement('span');
cellMeasure.textContent = 'M'.repeat(32);
cellMeasure.setAttribute('aria-hidden', 'true');
Object.assign(cellMeasure.style, {display: 'inline-block', position: 'fixed', top: '0', left: '0', visibility: 'hidden', whiteSpace: 'pre'});
document.body.append(cellMeasure);
let dragging = false;
let dismissing = false;
let dismissed = null;
let actionButtons = [];
let backspaceTimer;
let backspaceCard;
let refreshTimer;
let refreshing = false;
let refreshRequested = false;
let openedSession = null;
function stopBackspaceRepeat() {
  clearTimeout(backspaceTimer);
  const card = backspaceCard;
  backspaceCard = null;
  if (card) setSelection(card, card.selected);
}
async function api(path, data) {
  const response = await fetch(path, {method: data ? 'POST' : 'GET', headers: {
    'X-Peon-Token': token, ...(data ? {'Content-Type': 'application/json'} : {})
  }, ...(data ? {body: JSON.stringify(data)} : {})});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Request failed');
  return result;
}
const newSession = document.querySelector('#new-session');
const newSessionForm = document.querySelector('#new-session-form');
const newSessionStatus = document.querySelector('#new-session-status');
function closeNewSession() {
  newSessionForm.hidden = true;
  newSession.setAttribute('aria-expanded', 'false');
  newSession.focus();
}
newSession.onclick = () => {
  if (!newSessionForm.hidden) { closeNewSession(); return; }
  newSessionForm.hidden = false;
  newSession.setAttribute('aria-expanded', 'true');
  newSessionForm.elements.directory.focus();
};
newSessionForm.querySelector('.cancel').onclick = closeNewSession;
newSessionForm.onkeydown = event => {
  if (event.key === 'Escape') { event.preventDefault(); closeNewSession(); }
};
newSessionForm.onsubmit = async event => {
  event.preventDefault();
  const submit = newSessionForm.querySelector('[type="submit"]');
  if (submit.disabled) return;
  submit.disabled = true;
  newSessionStatus.hidden = false;
  newSessionStatus.classList.remove('error');
  newSessionStatus.textContent = 'Starting session...';
  try {
    const data = {directory: newSessionForm.elements.directory.value};
    const session = newSessionForm.elements.session.value.trim();
    if (session) data.session = session;
    const file = newSessionForm.elements.config.files[0];
    if (file) {
      if (file.size > 200 * 1024) throw new Error('Team config must be at most 200 KiB.');
      const text = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('Could not read the team config.'));
        reader.readAsText(file);
      });
      data.config_name = file.name;
      data.config_text = text;
    }
    const result = await api('/api/open', data);
    openedSession = result.session;
    newSessionStatus.textContent = 'Opened session ' + result.session;
    newSessionForm.reset();
    closeNewSession();
    await refresh();
  } catch (error) {
    newSessionStatus.textContent = error.message;
    newSessionStatus.classList.add('error');
  } finally { submit.disabled = false; }
};
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
function renderButtons(card) {
  card.el.querySelector('.prompt-buttons').replaceChildren(...actionButtons.map(action => {
    const button = document.createElement('button');
    button.type = 'button'; button.textContent = action.name; button.title = action.description;
    button.disabled = card.busy || card.closed;
    button.onclick = () => send(card, 'send', action.prompt, false);
    return button;
  }));
}
function feedback(card, message, error = false) {
  card.el.querySelector('.feedback').textContent = message;
  card.el.querySelector('.feedback').classList.toggle('error', error);
}
function setSelection(card, text) {
  card.selected = text;
  for (const button of card.el.querySelectorAll('.prompt-buttons button, .add-button, .button-form button[type="submit"]')) button.disabled = card.busy || card.closed;
  card.el.querySelector('.explain').disabled = !text.trim() || card.busy || card.closed;
  card.el.querySelector('.discard').hidden = !card.closed;
  card.el.querySelector('.discard').disabled = card.busy;
  card.el.querySelector('.message-form button').disabled = card.busy || card.closed;
  for (const button of card.el.querySelectorAll('.keys button')) {
    button.disabled = (card.busy || card.closed) && !(card === backspaceCard && button.dataset.key === 'Backspace');
    if (button.dataset.key === 'Backspace') button.setAttribute('aria-disabled', String(card.busy || card.closed));
  }
  card.el.querySelector('.selection-note').textContent = text ? 'Updates paused while selected' : '';
  card.el.querySelector('.state').textContent = card.closed ? 'Closed' : text ? 'Paused' : 'Live';
}
async function send(card, action, text, append = true) {
  if (card.closed || card.busy) return;
  const selectionRevision = card.selectionRevision;
  const draftRevision = card.draftRevision;
  card.busy = true;
  card.el.querySelector('.message-form button').disabled = true;
  setSelection(card, card.selected);
  feedback(card, 'Sending to this agent…');
  try {
    const result = await api('/api/' + action, {pane: card.id, identity: card.latest.identity, ...(action === 'keys' ? {key: text} : {text}), ...(action === 'send' && append ? {append: true} : {})});
    feedback(card, action === 'keys' && text === 'Enter' ? 'Pressed Enter' : result.message);
    if (action === 'explain') {
      if (card.selected === text && card.selectionRevision === selectionRevision) { setSelection(card, ''); if (card.key === currentPane()) getSelection().removeAllRanges(); }
    } else if (action === 'send' && card.draftRevision === draftRevision && card.el.querySelector('.message-form textarea').value === text) card.el.querySelector('.message-form textarea').value = '';
  } catch (error) { feedback(card, error.message, true); }
  finally { card.busy = false; setSelection(card, card.selected); }
}
function inputHint(pane) {
  const markerRow = (pane.screen || '').split('\n').reverse().find(row => /[❯›]/.test(row));
  if (!markerRow) return '';
  const parsed = document.createElement('div');
  for (const row of (pane.styledScreen || '').split('\n').reverse()) {
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
function inputBox(pane) {
  const screen = (pane.screen || '').split('\n');
  if (screen[screen.length - 1] === '') screen.pop();
  if (pane.menu || !Number.isInteger(pane.cursorY) || pane.cursorY < 0 || pane.cursorY >= screen.length || !/^ *[❯›]/.test(screen[pane.cursorY])) return '';
  const styled = (pane.styledScreen || '').split('\n');
  if (styled[styled.length - 1] === '') styled.pop();
  if (styled.length < screen.length) return '';
  const parsed = document.createElement('div');
  let text = '', afterMarker = false;
  renderAnsi(parsed, styled[pane.cursorY], '', (span, hinted) => {
    const marker = span.search(/[❯›]/);
    if (!afterMarker && marker >= 0) { afterMarker = true; span = span.slice(marker + 1); }
    if (afterMarker && !hinted) text += span;
  });
  return parsed.textContent.trimEnd() === screen[pane.cursorY].trimEnd() ? text.trim() : '';
}
function updateKeys(card) {
  const pane = card.latest;
  const labels = pane.menu ? [['Up', 'Up'], ['Down', 'Down'], ['Enter', 'Enter'], ['Escape', 'Esc']] : [];
  const hint = inputHint(pane);
  if (hint) labels.push(['Tab', ('Tab: ' + hint).slice(0, 60)]);
  const signature = JSON.stringify(labels);
  if (signature === card.shortcutsRendered) return;
  card.shortcutsRendered = signature;
  for (const button of card.el.querySelectorAll('.key-buttons button')) {
    const key = button.dataset.key;
    button.hidden = key === 'Tab' ? !!hint : pane.menu;
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
  const card = {el, id: pane.id, key: paneKey(pane), lines: 1000, scrollTop: 0, fullHistory: false, selected: '', selectionRevision: 0, draftRevision: 0, busy: false, closed: false, unread: false, needsAnswer: false, boxText: '', boxSince: 0, waitingText: false, latest: null, rendered: null, keysOpen: false};
  const keysToggle = el.querySelector('.keys-toggle');
  keysToggle.onclick = () => {
    card.keysOpen = !card.keysOpen;
    keysToggle.setAttribute('aria-expanded', String(card.keysOpen));
    el.querySelector('.key-buttons').hidden = !card.keysOpen;
  };
  for (const button of el.querySelectorAll('.key-buttons button')) button.onclick = () => send(card, 'keys', button.dataset.key);
  const backspace = el.querySelector('.key-buttons button[data-key="Backspace"]');
  let backspaceRepeated = false;
  backspace.onclick = event => { if (!backspaceRepeated || event.detail === 0) send(card, 'keys', 'Backspace'); };
  backspace.onpointerdown = event => {
    if (event.button !== 0 || card.busy || card.closed) return;
    backspaceRepeated = false;
    stopBackspaceRepeat();
    backspaceCard = card;
    backspaceTimer = setTimeout(function repeat() {
      backspaceRepeated = true;
      send(card, 'keys', 'Backspace');
      backspaceTimer = setTimeout(repeat, 80);
    }, 400);
  };
  backspace.onpointerleave = stopBackspaceRepeat;
  const shortcuts = document.createElement('div');
  shortcuts.className = 'key-shortcuts';
  el.querySelector('.keys').append(shortcuts);
  el.querySelector('.message-form textarea').oninput = () => { card.draftRevision++; };
  el.querySelector('.message-form textarea').onkeydown = event => {
    if (event.key === 'Enter' && event.shiftKey && !event.isComposing) {
      event.preventDefault(); el.querySelector('.message-form').requestSubmit();
    }
  };
  el.querySelector('h2').textContent = pane.name;
  el.querySelector('.meta').textContent = pane.session + ' / ' + pane.id + ' / ' + pane.command;
  el.querySelector('.explain').onclick = () => send(card, 'explain', card.selected);
  renderButtons(card);
  const buttonForm = el.querySelector('.button-form');
  el.querySelector('.add-button').onclick = () => {
    buttonForm.hidden = false;
    buttonForm.querySelector('[name="name"]').focus();
  };
  buttonForm.querySelector('.cancel').onclick = () => {
    buttonForm.hidden = true; buttonForm.reset(); el.querySelector('.add-button').focus();
  };
  buttonForm.onsubmit = async event => {
    event.preventDefault();
    if (card.busy || card.closed) return;
    card.busy = true; setSelection(card, card.selected);
    try {
      actionButtons = await api('/api/buttons', Object.fromEntries(new FormData(buttonForm)));
      for (const other of cards.values()) renderButtons(other);
      buttonForm.hidden = true; buttonForm.reset();
      feedback(card, 'Button saved');
    } catch (error) { feedback(card, error.message, true); }
    finally { card.busy = false; setSelection(card, card.selected); }
  };
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
    if (event.ctrlKey || event.altKey || event.metaKey || event.isComposing || card.closed) return;
    if (event.key === 'Escape' && card.selected) {
      event.preventDefault(); setSelection(card, ''); getSelection().removeAllRanges(); return;
    }
    if (card.busy) return;
    const key = {ArrowUp: 'Up', ArrowDown: 'Down', Enter: 'Enter', Escape: 'Escape', Backspace: 'Backspace'}[event.key];
    if (typeof key === 'string') { event.preventDefault(); send(card, 'keys', key); }
  };
  el.querySelector('.output').oncontextmenu = event => {
    if (document.querySelector('#right-click').checked && card.selected.trim() && !card.busy && !card.closed) {
      event.preventDefault(); send(card, 'explain', card.selected);
    }
  };
  el.querySelector('.discard').onclick = () => {
    if (card.busy) return;
    el.remove(); cards.delete(card.key);
    reconcileNavigation(navigation.panes.filter(pane => paneKey(pane) !== card.key));
  };
  el.querySelector('.message-form').onsubmit = event => {
    event.preventDefault();
    const text = el.querySelector('.message-form textarea').value;
    if (!text.trim() && card.latest.menu) return;
    if (!card.busy) send(card, text.trim() ? 'send' : 'keys', text.trim() ? text : 'Enter');
  };
  document.querySelector('#panes').append(el);
  cards.set(card.key, card);
  return card;
}
document.addEventListener('pointerdown', event => { dragging = !!event.target.closest('.output'); });
document.addEventListener('pointerup', () => { dragging = false; stopBackspaceRepeat(); }, true);
document.addEventListener('pointercancel', () => { dragging = false; stopBackspaceRepeat(); }, true);
window.addEventListener('blur', stopBackspaceRepeat);
document.addEventListener('visibilitychange', () => { if (document.hidden) stopBackspaceRepeat(); });
document.addEventListener('selectionchange', () => {
  const selection = getSelection();
  const range = !selection.isCollapsed && selection.rangeCount ? selection.getRangeAt(0) : null;
  for (const card of cards.values()) {
    const output = card.el.querySelector('.output');
    if (range && output.contains(range.startContainer) && output.contains(range.endContainer)) {
      card.selectionRevision++;
      setSelection(card, selection.toString());
    } else if (card.selected && !card.closed) {
      card.selectionRevision++;
      setSelection(card, '');
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
  if (refreshing) { refreshRequested = true; return; }
  refreshing = true;
  clearTimeout(refreshTimer);
  try {
    const visible = cards.get(currentPane());
    const lines = visible && !visible.closed ? visible.lines : 1000;
    const query = new URLSearchParams();
    if (lines > 1000) { query.set('pane', visible.id); query.set('lines', lines); }
    if (visible && !visible.closed && !visible.el.hidden) {
      const output = visible.el.querySelector('.output');
      const style = getComputedStyle(output);
      cellMeasure.style.font = style.font;
      const cell = cellMeasure.getBoundingClientRect();
      const cols = Math.floor((output.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)) / (cell.width / cellMeasure.textContent.length));
      const rows = Math.floor((output.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)) / cell.height);
      if (cols >= 20 && cols <= 500 && rows >= 5 && rows <= 300) {
        query.set('cols', cols); query.set('rows', rows);
      }
    }
    const parameters = query.toString();
    const {panes, initial} = await api("/api/panes" + (parameters ? '?' + parameters : ''));
    connection.textContent = panes.length + " agent" + (panes.length === 1 ? "" : "s") + " connected";
    document.querySelector("#empty").hidden = !!panes.length;
    const keys = new Set(panes.map(paneKey));
    for (const pane of panes) {
      const card = cards.get(paneKey(pane)) || createCard(pane);
      if (card.closed) { card.closed = false; setSelection(card, card.selected); feedback(card, 'Agent reconnected'); }
      if (pane.role === 'manager' && card.latest && card.latest.output !== pane.output && card.key !== currentPane()) card.unread = true;
      card.needsAnswer = pane.menu;
      const boxText = inputBox(pane), now = performance.now();
      if (!boxText) card.boxSince = 0;
      else if (boxText !== card.boxText || card.latest?.output !== pane.output) card.boxSince = now;
      card.boxText = boxText;
      card.waitingText = !!boxText && now - card.boxSince >= BOX_WAIT_MS;
      card.latest = {...pane, capturedLines: visible && visible.id === pane.id ? lines : 1000};
      updateKeys(card);
      card.el.querySelector("h2").textContent = pane.name;
      card.el.querySelector(".meta").textContent = pane.session + " / " + pane.role + " / " + pane.id;
      updateOutput(card);
    }
    for (const [key, card] of cards) {
      if (!keys.has(key)) {
        if (card.selected || card.el.querySelector('.message-form textarea').value || card.busy) {
          if (!card.closed) feedback(card, 'This agent closed. Copy your text or discard it.', true);
          card.closed = true;
          card.boxText = ''; card.boxSince = 0; card.waitingText = false;
          setSelection(card, card.selected);
          panes.push({...card.latest, closed: true});
        } else { card.el.remove(); cards.delete(key); }
      }
    }
    document.querySelector('#empty').hidden = !!panes.length;
    if (dismissed && !panes.some(pane => pane.session === dismissed && !pane.closed)) {
      if (navigation.session === dismissed) navigation.session = undefined;
      dismissed = null;
      document.querySelector('#dismiss-status').hidden = true;
    }
    if (openedSession && panes.some(pane => pane.session === openedSession && !pane.closed)) {
      navigation.session = openedSession;
      openedSession = null;
    }
    reconcileNavigation(panes, initial);
  } catch (error) { connection.textContent = error.message; }
  finally {
    refreshing = false;
    refreshTimer = setTimeout(refresh, refreshRequested ? 0 : 1200);
    refreshRequested = false;
  }
}
refresh().then(async function refreshButtons() {
  try {
    const buttons = await api('/api/buttons');
    if (JSON.stringify(buttons) !== JSON.stringify(actionButtons)) {
      actionButtons = buttons;
      for (const card of cards.values()) renderButtons(card);
    }
  } catch (error) { connection.textContent = error.message; }
  finally { setTimeout(refreshButtons, 5000); }
});
