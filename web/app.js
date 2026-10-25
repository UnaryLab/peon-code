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
let resizeTimer;
let refreshing = false;
let refreshRequested = false;
let openedSession = null;
let lastCols;
let lastRows;
let resizedAt = -Infinity;
let fontSize = 13;
const tip = document.querySelector('#tip');
let tipOwner;
let tipTimer;
function updateTip(event) {
  const owner = event.target?.matches?.('[data-tip]') ? event.target : null;
  const starting = event.type === 'mouseenter' || (event.type === 'focus' && owner?.matches(':focus-visible'));
  if (starting && !owner?.dataset.tip) return;
  if ((event.type === 'mouseleave' || event.type === 'blur') && owner !== tipOwner) return;
  clearTimeout(tipTimer);
  tip.hidden = true;
  if (tipOwner) {
    const descriptions = (tipOwner.getAttribute('aria-describedby') || '').split(/\s+/).filter(id => id && id !== 'tip');
    if (descriptions.length) tipOwner.setAttribute('aria-describedby', descriptions.join(' '));
    else tipOwner.removeAttribute('aria-describedby');
  }
  tipOwner = starting ? owner : null;
  if (!tipOwner) return;
  tipTimer = setTimeout(() => {
    if (!owner.isConnected || !owner.getClientRects().length || !owner.dataset.tip) { tipOwner = null; return; }
    tip.textContent = owner.dataset.tip;
    tip.hidden = false;
    tip.style.left = '0px';
    const rect = owner.getBoundingClientRect();
    tip.style.left = Math.max(8, Math.min(rect.left, innerWidth - tip.offsetWidth - 8)) + 'px';
    tip.style.top = Math.max(8, Math.min(rect.bottom + 4, innerHeight - tip.offsetHeight - 8)) + 'px';
    const descriptions = (owner.getAttribute('aria-describedby') || '').split(/\s+/).filter(id => id && id !== 'tip');
    owner.setAttribute('aria-describedby', [...descriptions, 'tip'].join(' '));
  }, 2000);
}
for (const type of ['mouseenter', 'focus', 'mouseleave', 'blur', 'click', 'keydown']) document.addEventListener(type, updateTip, true);
window.addEventListener('resize', updateTip);
new MutationObserver(() => {
  if (tipOwner && (!tipOwner.isConnected || !tipOwner.getClientRects().length)) updateTip({type: 'blur', target: tipOwner});
}).observe(document.body, {childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'class', 'style']});
try {
  const saved = parseInt(localStorage.getItem('peon-font'), 10);
  if (Number.isFinite(saved)) fontSize = Math.max(8, Math.min(32, saved));
} catch {}
document.documentElement.style.setProperty('--output-font', fontSize + 'px');
for (const [selector, step] of [['.font-smaller', -1], ['.font-larger', 1]]) {
  document.querySelector(selector).onclick = () => {
    fontSize = Math.max(8, Math.min(32, fontSize + step));
    document.documentElement.style.setProperty('--output-font', fontSize + 'px');
    try { localStorage.setItem('peon-font', String(fontSize)); } catch {}
    scheduleRefresh();
  };
}
function scheduleRefresh() {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(refresh, 150);
}
window.addEventListener('resize', scheduleRefresh);
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
  if (!response.ok) throw Object.assign(new Error(result.error || 'Request failed'), {status: response.status, result});
  return result;
}
const newSession = document.querySelector('#new-session');
const newSessionForm = document.querySelector('#new-session-form');
const newSessionStatus = document.querySelector('#new-session-status');
function closeNewSession() {
  const focused = document.activeElement;
  newSessionForm.hidden = true;
  newSession.setAttribute('aria-expanded', 'false');
  if (newSessionForm.contains(focused) || focused === newSession || focused === document.body) newSession.focus();
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
    let result;
    try { result = await api('/api/open', data); }
    catch (error) {
      if (error.status !== 409 || error.result?.create !== true ||
          !confirm('Folder ' + error.result.directory + ' does not exist. Create it?')) throw error;
      result = await api('/api/open', {...data, directory: error.result.directory, create: true});
    }
    openedSession = result.session;
    newSessionStatus.hidden = true;
    newSessionStatus.textContent = '';
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
  try {
    await api('/api/dismiss', {session});
    dismissed = session;
  }
  catch (error) { alert(error.message); }
  finally { dismissing = false; updateNavigation(); }
};
const upload = document.querySelector('#upload');
const uploadForm = document.querySelector('#upload-form');
const uploadDir = document.querySelector('#upload-dir');
const uploadFiles = document.querySelector('#upload-files');
const uploadStatus = document.querySelector('#upload-status');
const uploadFolders = document.querySelector('#upload-folders');
const chooseFiles = uploadForm.querySelector('[type="submit"]');
let uploadSession;
let uploading = false;
let folderRevision = 0;
async function loadUploadFolders() {
  const session = uploadSession, revision = ++folderRevision;
  uploadFolders.replaceChildren();
  if (!session) return;
  try {
    const result = await api('/api/files?' + new URLSearchParams({session}));
    if (revision !== folderRevision || session !== uploadSession || uploadForm.hidden) return;
    uploadFolders.replaceChildren(...result.entries.filter(entry => entry.type === 'dir').map(entry => {
      const option = document.createElement('option'); option.value = entry.name; return option;
    }));
  } catch { /* Folder suggestions are optional; typed folders still work. */ }
}
function openUpload() {
  if (!swapForm.hidden) closeSwap();
  uploadForm.hidden = false;
  upload.setAttribute('aria-expanded', 'true');
  uploadDir.focus();
  loadUploadFolders();
}
function closeUpload() {
  const focused = document.activeElement;
  uploadForm.hidden = true;
  upload.setAttribute('aria-expanded', 'false');
  if (uploadForm.contains(focused) || !focused.matches('input, textarea') || !focused.value) {
    (upload.hidden || upload.disabled ? cards.get(currentPane())?.el.querySelector('.output') : upload)?.focus();
  }
}
upload.onclick = () => {
  if (upload.disabled) return;
  if (!uploadForm.hidden) { closeUpload(); return; }
  openUpload();
};
uploadForm.querySelector('.cancel').onclick = closeUpload;
uploadForm.onkeydown = event => {
  if (event.key === 'Escape') { event.preventDefault(); closeUpload(); }
};
uploadForm.onsubmit = event => {
  event.preventDefault();
  if (!chooseFiles.disabled) uploadFiles.click();
};
uploadFiles.onchange = async () => {
  const card = cards.get(currentPane());
  const files = Array.from(uploadFiles.files);
  uploadFiles.value = '';
  if (!card || card.closed || !files.length) return;
  const session = card.latest.session;
  const dir = uploadDir.value.trim() || 'upload';
  const results = [];
  uploading = true; updateSwap();
  uploadStatus.classList.remove('error');
  try {
    for (const file of files) {
      uploadStatus.textContent = [...results, 'Uploading ' + file.name + '...'].join('\n');
      try {
        const query = new URLSearchParams({session, name: file.name, dir});
        const response = await fetch('/api/upload?' + query, {method: 'POST', headers: {
          'X-Peon-Token': token, 'Content-Type': 'application/octet-stream'
        }, body: file});
        const result = await response.json();
        if (!response.ok) throw new Error(result.error || 'Request failed');
        results.push(file.name + ': ' + result.message);
      } catch (error) {
        results.push(file.name + ': ' + error.message);
        uploadStatus.classList.add('error');
      }
      uploadStatus.textContent = results.join('\n');
    }
  } finally {
    try { localStorage.setItem('peon-upload-dir:' + session, dir); } catch {}
    uploading = false; updateSwap();
  }
};
const filesButton = document.querySelector('#files');
const filesDialog = document.querySelector('#files-dialog');
const fileBreadcrumb = document.querySelector('#file-breadcrumb');
const fileList = document.querySelector('#file-list');
const filesStatus = document.querySelector('#files-status');
const uploadHere = document.querySelector('#upload-here');
const fileViewer = document.querySelector('#viewer');
const fileViewerName = document.querySelector('#file-viewer-name');
const filePreview = document.querySelector('#file-preview');
let filesSession, fileDir = '', filesRevision = 0, viewRevision = 0, viewerUrl;
function fileButton(label, action) {
  const button = document.createElement('button');
  button.type = 'button'; button.textContent = label; button.onclick = action;
  return button;
}
function renderFileBreadcrumb() {
  fileBreadcrumb.replaceChildren(fileButton('Project', () => loadFiles('')));
  let path = '';
  for (const part of fileDir.split('/').filter(Boolean)) {
    path += (path ? '/' : '') + part;
    const dir = path;
    fileBreadcrumb.append(' / ', fileButton(part, () => loadFiles(dir)));
  }
}
async function fetchFile(session, path) {
  const response = await fetch('/api/file?' + new URLSearchParams({session, path}), {headers: {'X-Peon-Token': token}});
  if (!response.ok) {
    const result = await response.json();
    throw new Error(result.error || 'Request failed');
  }
  return response;
}
async function openFile(entry, view, path = (fileDir ? fileDir + '/' : '') + entry.name) {
  const session = filesSession, revision = filesRevision;
  const viewerRevision = view ? ++viewRevision : viewRevision;
  if (view) {
    fileViewerName.textContent = entry.name;
    filePreview.textContent = 'Loading...';
    fileViewer.showModal();
  }
  try {
    const response = await fetchFile(session, path);
    const blob = await response.blob();
    if (view && (revision !== filesRevision || !filesDialog.open || !fileViewer.open || viewerRevision !== viewRevision)) return;
    const url = URL.createObjectURL(blob);
    if (view) {
      viewerUrl = url;
      const media = document.createElement(/\.pdf$/i.test(entry.name) ? 'iframe' : 'img');
      if (media.tagName === 'IMG') media.alt = entry.name;
      else media.title = entry.name;
      media.src = url;
      filePreview.replaceChildren(media);
    } else {
      const link = document.createElement('a');
      link.href = url; link.download = entry.name;
      if (entry.type === 'dir') {
        link.download += '.zip';
        const filename = /filename\*=UTF-8''([^;]+)/i.exec(response.headers.get('Content-Disposition') || '');
        if (filename) {
          try { link.download = decodeURIComponent(filename[1]); } catch {}
        }
      }
      document.body.append(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  } catch (error) {
    if (!filesDialog.open || (view && revision !== filesRevision)) return;
    if (view) {
      if (viewerRevision === viewRevision && fileViewer.open) filePreview.textContent = error.message;
    } else { filesStatus.textContent = error.message; filesStatus.classList.add('error'); }
  }
}
function formatFileSize(size) {
  const units = ['B', 'KB', 'MB', 'GB'];
  let unit = 0;
  while (unit < units.length - 1 && Number(size.toFixed(1)) >= 1024) { size /= 1024; unit++; }
  return (unit ? size.toFixed(1) : size) + ' ' + units[unit];
}
async function loadFiles(dir, fallback = false) {
  const session = filesSession, revision = ++filesRevision;
  fileDir = dir;
  renderFileBreadcrumb();
  fileList.replaceChildren();
  uploadHere.disabled = true;
  filesStatus.textContent = 'Loading...';
  filesStatus.classList.remove('error');
  try {
    const result = await api('/api/files?' + new URLSearchParams({session, dir}));
    if (revision !== filesRevision || !filesDialog.open) return;
    fileDir = result.dir;
    renderFileBreadcrumb();
    uploadHere.disabled = !fileDir;
    filesStatus.textContent = result.entries.length ? '' : 'This folder is empty.';
    fileList.replaceChildren(...result.entries.map(entry => {
      const row = document.createElement('div'); row.className = 'file-row';
      const path = (fileDir ? fileDir + '/' : '') + entry.name;
      const name = entry.type === 'dir' ? fileButton(entry.name + '/', () => loadFiles(path)) : document.createElement('span');
      name.className = 'file-name';
      if (entry.type !== 'dir') name.textContent = entry.name;
      row.append(name);
      if (entry.type === 'dir') row.append(fileButton('Download', () => openFile(entry, false)));
      if (entry.type === 'file') {
        const size = document.createElement('span'); size.className = 'meta'; size.textContent = formatFileSize(entry.size);
        row.append(size, fileButton('Download', () => openFile(entry, false)));
        if (/\.(png|jpe?g|gif|webp|svg|pdf)$/i.test(entry.name)) row.append(fileButton('View', () => openFile(entry, true)));
      }
      return row;
    }));
  } catch (error) {
    if (revision !== filesRevision || !filesDialog.open) return;
    if (fallback && dir && error.status === 404) return loadFiles('');
    filesStatus.textContent = error.message;
    filesStatus.classList.add('error');
  }
}
filesButton.onclick = () => {
  const card = cards.get(currentPane());
  if (!card || card.closed) return;
  if (!uploadForm.hidden) closeUpload();
  if (!swapForm.hidden) closeSwap();
  if (filesSession !== card.latest.session) fileDir = '';
  filesSession = card.latest.session;
  filesDialog.showModal();
  loadFiles(fileDir, true);
};
document.querySelector('#download-folder').onclick = () => {
  const project = cards.get(currentPane())?.latest.projectDir || '';
  const name = fileDir.split('/').pop() || project.split('/').filter(Boolean).pop() || 'project';
  openFile({name, type: 'dir'}, false, fileDir);
};
filesDialog.querySelector('.close').onclick = () => filesDialog.close();
filesDialog.onclose = () => { filesRevision++; if (fileViewer.open) fileViewer.close(); };
fileViewer.querySelector('.close').onclick = () => fileViewer.close();
fileViewer.onclose = () => {
  viewRevision++;
  filePreview.replaceChildren();
  if (viewerUrl) { URL.revokeObjectURL(viewerUrl); viewerUrl = null; }
};
uploadHere.onclick = () => {
  if (uploadHere.disabled) return;
  uploadDir.value = fileDir;
  filesDialog.close();
  openUpload();
};
const swap = document.querySelector('#swap');
const swapForm = document.querySelector('#swap-form');
let swapSelection;
let swapPrefill;
let availableClis = [];
let swapRevision = 0;
let swapPending = false;
function swapValues(card) {
  const words = [];
  let word = '', quote = '', escaped = false;
  for (const char of card?.latest?.agent_command || card?.latest?.command || '') {
    if (escaped) { word += char; escaped = false; }
    else if (char === '\\' && quote !== "'") escaped = true;
    else if (quote) { if (char === quote) quote = ''; else word += char; }
    else if (char === "'" || char === '"') quote = char;
    else if (/\s/.test(char)) { if (word) words.push(word); word = ''; }
    else word += char;
  }
  if (quote || escaped) return {cli: card?.latest?.cli || '', model: '', effort: ''};
  if (word) words.push(word);
  const values = {cli: card?.latest?.cli || '', model: '', effort: ''};
  for (let i = 0; i < words.length; i++) {
    if (words[i] === '--model') values.model = words[++i] || '';
    else if (words[i].startsWith('--model=')) values.model = words[i].slice(8);
    else if (words[i] === '--effort') values.effort = words[++i] || '';
    else if (words[i].startsWith('--effort=')) values.effort = words[i].slice(9);
    else if (words[i].startsWith('model_reasoning_effort=')) values.effort = words[i].slice(23);
  }
  for (const field of ['model', 'effort']) if (!/^(-|[A-Za-z0-9._=/][A-Za-z0-9._=/-]*)$/.test(values[field])) values[field] = '';
  return values;
}
function prefillSwap(card) {
  swapPrefill = swapValues(card);
  for (const field of ['cli', 'model', 'effort']) swapForm.elements[field].value = swapPrefill[field];
}
function updateSwap() {
  const card = cards.get(currentPane());
  const selected = card?.key;
  const focused = document.activeElement === swap || swapForm.contains(document.activeElement);
  const uploadFocused = uploadForm.contains(document.activeElement);
  let targetGone = !card || card.closed;
  if (selected !== swapSelection) {
    const previous = cards.get(swapSelection);
    targetGone = targetGone || !previous || previous.closed;
    swapSelection = selected;
    swapRevision++;
    if (!swapForm.hidden && !targetGone) prefillSwap(card);
  }
  const disabled = !card || card.closed || card.busy || swapPending || !!card.latest?.swap?.startsWith('checking');
  if (!swapForm.hidden && targetGone) {
    swapForm.hidden = true;
    swap.setAttribute('aria-expanded', 'false');
  }
  swap.disabled = disabled;
  filesButton.disabled = disabled;
  upload.disabled = disabled || uploading;
  for (const control of uploadForm.querySelectorAll('input, button')) control.disabled = disabled || uploading;
  swap.hidden = !card || card.closed;
  upload.hidden = swap.hidden;
  filesButton.hidden = swap.hidden;
  const session = card?.latest?.session;
  if (session !== uploadSession) {
    uploadSession = session;
    folderRevision++;
    uploadDir.value = 'upload';
    try { uploadDir.value = localStorage.getItem('peon-upload-dir:' + session) || 'upload'; } catch {}
    uploadFolders.replaceChildren();
    uploadStatus.textContent = '';
    if (filesDialog.open) filesDialog.close();
    if (!uploadForm.hidden) loadUploadFolders();
  }
  if (swap.hidden && filesDialog.open) filesDialog.close();
  if (!uploadForm.hidden && targetGone) closeUpload();
  for (const control of swapForm.querySelectorAll('input, select, button')) control.disabled = disabled;
  if ((disabled && focused) || ((disabled || uploading) && uploadFocused)) card?.el.querySelector('.output').focus();
}
const renderNavigation = updateNavigation;
updateNavigation = () => { renderNavigation(); updateSwap(); };
function closeSwap() {
  const focused = document.activeElement;
  swapForm.hidden = true;
  swap.setAttribute('aria-expanded', 'false');
  if (swapForm.contains(focused) || !focused.matches('input, textarea') || !focused.value) {
    (swap.disabled ? cards.get(currentPane())?.el.querySelector('.output') : swap)?.focus();
  }
}
swap.onclick = () => {
  if (swap.disabled) return;
  if (!swapForm.hidden) { closeSwap(); return; }
  if (!uploadForm.hidden) closeUpload();
  const card = cards.get(currentPane());
  prefillSwap(card);
  swapForm.hidden = false;
  swap.setAttribute('aria-expanded', 'true');
  swapForm.elements.cli.focus();
};
swapForm.querySelector('.cancel').onclick = closeSwap;
swapForm.onkeydown = event => {
  if (event.key === 'Escape') { event.preventDefault(); closeSwap(); }
};
swapForm.onsubmit = async event => {
  event.preventDefault();
  updateSwap();
  if (swap.disabled) return;
  const card = cards.get(currentPane());
  const identity = card.latest.identity, revision = swapRevision;
  const values = {};
  for (const field of ['cli', 'model', 'effort']) {
    const value = swapForm.elements[field].value.trim();
    values[field] = value === swapPrefill[field] || (field !== 'cli' && !value) ? '-' : value;
    if (!/^(-|[A-Za-z0-9._=/][A-Za-z0-9._=/-]*)$/.test(values[field])) { feedback(card, field + ' must be one token', true); return; }
  }
  if (values.cli !== '-' && !availableClis.includes(values.cli)) { feedback(card, 'Unknown CLI', true); return; }
  if (Object.values(values).every(value => value === '-')) { feedback(card, 'Change CLI, model, or effort first.', true); return; }
  let succeeded = false, message, error = false;
  swapPending = true;
  card.busy = true; setSelection(card, card.selected);
  feedback(card, 'Changing this agent...');
  try {
    const result = await api('/api/swap', {pane: card.id, identity, ...values});
    message = /(?:^|:\s*)checking\b/.test(result.message) ? '' : result.message;
    succeeded = true;
  } catch (failure) { message = failure.message; error = true; }
  finally {
    swapPending = false;
    card.busy = false; setSelection(card, card.selected);
    if (revision === swapRevision && card.key === currentPane() && card.latest.identity === identity) {
      feedback(card, message, error);
      if (succeeded) closeSwap();
      else if (swapForm.contains(document.activeElement) || !document.activeElement.matches('input, textarea') || !document.activeElement.value) {
        (swapForm.elements.cli.disabled ? card.el.querySelector('.output') : swapForm.elements.cli).focus();
      }
    }
  }
};
function renderButtons(card) {
  const following = [...card.el.querySelectorAll('.output')].filter(output => !card.el.hidden && output.scrollHeight - output.scrollTop - output.clientHeight < 40);
  card.el.querySelector('.prompt-buttons').replaceChildren(...actionButtons.map(action => {
    const button = document.createElement('button');
    button.type = 'button'; button.textContent = action.name;
    if (action.description) button.dataset.tip = action.description;
    button.disabled = card.busy || card.closed;
    button.onclick = () => send(card, 'send', action.prompt, false);
    return button;
  }));
  for (const output of following) {
    output.scrollTop = output.scrollHeight;
    output.parentElement.outputScrollTop = output.scrollTop;
  }
}
function feedback(card, message, error = false) {
  card.el.querySelector('.feedback').textContent = message;
  card.el.querySelector('.feedback').classList.toggle('error', error);
}
function updateBusy() {
  document.body.classList.toggle('busy', [...cards.values()].some(card => card.busy));
}
function setSelection(card, text) {
  updateBusy();
  card.selected = text;
  for (const button of card.el.querySelectorAll('.prompt-buttons button, .add-button, .button-form button, .stack-order, .add-screen, .close-screen')) button.disabled = card.busy || card.closed;
  updateSwap();
  card.el.querySelector('.explain').disabled = !text.trim() || card.busy || card.closed;
  card.el.querySelector('.discard').hidden = !card.closed;
  card.el.querySelector('.discard').disabled = card.busy;
  card.el.querySelector('.message-form button').disabled = card.busy || card.closed;
  for (const button of card.el.querySelectorAll('.keys button')) {
    button.disabled = card.closed || (card.busy && button.dataset.key !== 'C-c' && !(card === backspaceCard && button.dataset.key === 'Backspace'));
    if (button.dataset.key === 'Backspace') button.setAttribute('aria-disabled', String(card.busy || card.closed));
  }
  card.el.querySelector('.selection-note').textContent = text ? 'Updates paused while selected, right-click to explain' : '';
  card.el.querySelector('.state').textContent = card.closed ? 'Closed' : text ? 'Paused' : 'Live';
}
async function send(card, action, text, append = true) {
  const interrupt = action === 'keys' && text === 'C-c';
  if (card.closed || (card.busy && !interrupt)) return;
  const selectionRevision = card.selectionRevision;
  const draftRevision = card.draftRevision;
  if (!interrupt) {
    card.busy = true;
    card.el.querySelector('.message-form button').disabled = true;
    setSelection(card, card.selected);
  }
  feedback(card, 'Sending to this agent…');
  try {
    const result = await api('/api/' + action, {pane: card.id, identity: card.latest.identity, ...(action === 'keys' ? {key: text} : {text}), ...(action === 'send' && append ? {append: true} : {})});
    feedback(card, action === 'keys' && text === 'Enter' ? 'Pressed Enter' : result.message);
    if (action === 'explain') {
      if (card.selected === text && card.selectionRevision === selectionRevision) { setSelection(card, ''); if (card.key === currentPane()) getSelection().removeAllRanges(); }
    } else if (action === 'send' && card.draftRevision === draftRevision && card.el.querySelector('.message-form textarea').value === text) card.el.querySelector('.message-form textarea').value = '';
  } catch (error) { feedback(card, error.message, true); }
  finally { if (!interrupt) { card.busy = false; setSelection(card, card.selected); } }
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
    button.hidden = key === 'Tab' ? !!hint : ['Up', 'Down', 'Enter', 'Escape', 'Backspace'].includes(key) && pane.menu;
  }
  const buttons = labels.map(([key, label]) => {
    const button = document.createElement('button');
    button.type = 'button'; button.dataset.key = key; button.textContent = label;
    button.dataset.tip = 'Send ' + (key === 'Escape' ? 'Esc' : key) + ' to the agent';
    button.disabled = card.busy || card.closed;
    button.onclick = () => send(card, 'keys', key);
    return button;
  });
  card.el.querySelector('.key-shortcuts').replaceChildren(...buttons);
}
function saveScreens(card, remove = false) {
  clearTimeout(card.screensTimer);
  card.screensTimer = null;
  try {
    if (remove) {
      if (![...cards.values()].some(other => other !== card && other.screensKey === card.screensKey)) localStorage.removeItem(card.screensKey);
      return;
    }
    const screens = [...card.el.querySelectorAll('.screen')].map(screen => {
      const output = screen.querySelector('.output');
      if (!card.el.hidden && !('savedAnchor' in screen)) screen.anchor = output.scrollHeight - output.scrollTop - output.clientHeight < 40 ? null : scrollAnchor(output)?.anchor || null;
      return {anchor: screen.anchor || null};
    });
    if (card.stack === 'vertical' && screens.length === 1 && !screens[0].anchor) localStorage.removeItem(card.screensKey);
    else localStorage.setItem(card.screensKey, JSON.stringify({stack: card.stack, screens}));
  } catch {}
}
window.addEventListener('pagehide', () => {
  for (const card of cards.values()) if (card.screensTimer) saveScreens(card);
});
function wireScreen(card, screen) {
  const output = screen.querySelector('.output');
  screen.outputScrollTop = output.scrollTop;
  output.onscroll = () => {
    if (card.el.hidden || card.closed) return;
    const scrollingUp = output.scrollTop < screen.outputScrollTop;
    if (output.scrollTop !== screen.outputScrollTop) screen.anchorRemainder = 0;
    screen.outputScrollTop = output.scrollTop;
    screen.anchor = output.scrollHeight - output.scrollTop - output.clientHeight < 40 ? null : scrollAnchor(output)?.anchor || null;
    clearTimeout(card.screensTimer);
    card.screensTimer = setTimeout(() => saveScreens(card), 300);
    if ([...card.el.querySelectorAll('.output')].every(other => other.scrollHeight - other.scrollTop - other.clientHeight < 40)) card.lines = 1000;
    else if (scrollingUp && output.scrollTop < 200 && !card.selected && getSelection().isCollapsed && card.latest?.history > card.lines && card.latest.capturedLines === card.lines && card.lines < 200000) {
      card.lines += 1000;
    }
  };
  output.onkeydown = event => {
    if (event.ctrlKey && event.key === 'c' && !event.shiftKey && !event.altKey && !event.metaKey && !event.isComposing && getSelection().isCollapsed && !card.closed) {
      event.preventDefault(); send(card, 'keys', 'C-c'); return;
    }
    if (event.ctrlKey || event.altKey || event.metaKey || event.isComposing || card.closed) return;
    if (event.key === 'Escape' && card.selected) {
      event.preventDefault(); setSelection(card, ''); getSelection().removeAllRanges(); return;
    }
    if (card.busy) return;
    const key = {ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right', Enter: 'Enter', Escape: 'Escape', Backspace: 'Backspace'}[event.key];
    if (typeof key === 'string') { event.preventDefault(); send(card, 'keys', key); }
  };
  output.oncontextmenu = event => {
    if (card.selected.trim() && !card.busy && !card.closed) {
      event.preventDefault(); send(card, 'explain', card.selected);
    }
  };
}
function createCard(pane) {
  const el = document.querySelector('#pane-template').content.firstElementChild.cloneNode(true);
  el.dataset.pane = pane.id;
  el.dataset.key = paneKey(pane);
  const card = {el, id: pane.id, key: paneKey(pane), stack: 'vertical', lines: 1000, fullHistory: false, selected: '', selectionRevision: 0, draftRevision: 0, busy: false, closed: false, unread: false, needsAnswer: false, boxText: '', boxSince: 0, waitingText: false, latest: null, rendered: null, keysOpen: false};
  card.screensKey = 'peon-screens:' + pane.session + '/' + pane.name;
  let saved;
  try {
    const value = JSON.parse(localStorage.getItem(card.screensKey));
    if (value && ['vertical', 'horizontal'].includes(value.stack) && Array.isArray(value.screens) && value.screens.length && value.screens.every(screen => screen && (screen.anchor === null || (screen.anchor && typeof screen.anchor.text === 'string' && Number.isFinite(screen.anchor.pixelOffset) && Number.isInteger(screen.anchor.index) && Number.isInteger(screen.anchor.lineCount))))) saved = value;
  } catch {}
  const stackOrder = el.querySelector('.stack-order');
  const updateStack = () => {
    el.querySelector('.screens').classList.toggle('horizontal', card.stack === 'horizontal');
    stackOrder.textContent = card.stack === 'horizontal' ? '↔' : '↕';
    stackOrder.setAttribute('aria-label', card.stack === 'horizontal' ? 'Screens side by side, switch to vertical' : 'Screens stacked vertically, switch to side by side');
  };
  stackOrder.onclick = () => {
    const positions = [...el.querySelectorAll('.output')].map(output => ({output, atEnd: output.scrollHeight - output.scrollTop - output.clientHeight < 40, top: output.scrollTop, fromBottom: output.scrollHeight - output.scrollTop}));
    card.stack = card.stack === 'vertical' ? 'horizontal' : 'vertical';
    updateStack();
    for (const {output, atEnd, top, fromBottom} of positions) {
      output.scrollTop = atEnd ? output.scrollHeight : card.fullHistory ? top : output.scrollHeight - fromBottom;
      output.parentElement.outputScrollTop = output.scrollTop;
    }
    saveScreens(card);
    scheduleRefresh();
  };
  wireScreen(card, el.querySelector('.screen'));
  const addScreen = (persist = true) => {
    const positions = [...el.querySelectorAll('.output')].map(output => ({output, atEnd: output.scrollHeight - output.scrollTop - output.clientHeight < 40, top: output.scrollTop, fromBottom: output.scrollHeight - output.scrollTop}));
    const screen = el.querySelector('.screen').cloneNode(true);
    const close = document.createElement('button');
    close.type = 'button'; close.className = 'close-screen'; close.textContent = 'x';
    close.setAttribute('aria-label', 'Close screen'); close.dataset.tip = 'Close this screen';
    close.onclick = () => { screen.remove(); el.querySelector('.output').focus(); saveScreens(card); scheduleRefresh(); };
    screen.append(close);
    el.querySelector('.screens').append(screen);
    wireScreen(card, screen);
    for (const {output, atEnd, top, fromBottom} of positions) {
      output.scrollTop = atEnd ? output.scrollHeight : card.fullHistory ? top : output.scrollHeight - fromBottom;
      output.parentElement.outputScrollTop = output.scrollTop;
    }
    const output = screen.querySelector('.output');
    output.scrollTop = output.scrollHeight;
    screen.outputScrollTop = output.scrollTop;
    if (persist) { saveScreens(card); scheduleRefresh(); }
  };
  el.querySelector('.add-screen').onclick = () => addScreen();
  if (saved) {
    card.stack = saved.stack; updateStack();
    for (let i = 1; i < saved.screens.length; i++) addScreen(false);
    [...el.querySelectorAll('.screen')].forEach((screen, i) => { screen.savedAnchor = screen.anchor = saved.screens[i].anchor; });
  }
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
  el.querySelector('.discard').onclick = () => {
    if (card.busy) return;
    saveScreens(card, true);
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
    const selected = range && [...card.el.querySelectorAll('.output')].some(output => output.contains(range.startContainer) && output.contains(range.endContainer));
    if (selected) {
      card.selectionRevision++;
      setSelection(card, selection.toString());
    } else if (card.selected && !card.closed) {
      card.selectionRevision++;
      setSelection(card, '');
    }
  }
});
function scrollAnchor(output, saved, rolled = 0) {
  const viewport = output.getBoundingClientRect(), style = getComputedStyle(output);
  const range = document.createRange();
  function lineTop(offset) {
    const walker = document.createTreeWalker(output, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (offset < node.length) {
        range.setStart(node, offset); range.setEnd(node, offset + 1);
        return range.getBoundingClientRect().top;
      }
      offset -= node.length;
    }
    return null;
  }
  let anchor = saved;
  if (!anchor) {
    const x = viewport.left + parseFloat(style.paddingLeft) + 1, y = viewport.top + parseFloat(style.paddingTop) + 1;
    const caret = document.caretPositionFromPoint?.(x, y) || document.caretRangeFromPoint?.(x, y);
    const node = caret?.offsetNode || caret?.startContainer;
    if (!node || !output.contains(node)) return null;
    range.selectNodeContents(output); range.setEnd(node, caret.offset ?? caret.startOffset);
    const text = output.textContent, offset = range.toString().length;
    let start = text.slice(0, offset).lastIndexOf('\n') + 1;
    let index = text.slice(0, start).split('\n').length - 1;
    const oldLines = text.split('\n'), windows = oldLines.map((_, i) => oldLines.slice(i, i + 3).join('\n')), counts = new Map();
    for (const window of windows) counts.set(window, (counts.get(window) || 0) + 1);
    let top, fallback;
    for (; index < oldLines.length; index++) {
      top = lineTop(start);
      if (top === null || top >= viewport.bottom - parseFloat(style.paddingBottom)) break;
      if (oldLines[index].trim()) {
        const candidate = {text: windows[index], pixelOffset: top - viewport.top, index, lineCount: oldLines.length};
        if (!fallback) fallback = candidate;
        if (counts.get(windows[index]) === 1) { anchor = candidate; break; }
      }
      start += oldLines[index].length + 1;
    }
    anchor = anchor || fallback;
    if (!anchor) return null;
  }
  return {anchor, restore() {
    const following = anchor.text.split('\n');
    const lines = output.textContent.split('\n'), matches = i => following.every((line, j) => lines[i + j] === line);
    const expected = anchor.index - rolled + lines.length - anchor.lineCount;
    let match = -1;
    for (let i = 0; i < lines.length; i++) if (matches(i) && (match < 0 || Math.abs(i - expected) < Math.abs(match - expected))) match = i;
    if (match < 0) return false;
    const top = lineTop(lines.slice(0, match).join('\n').length + (match ? 1 : 0));
    if (top === null) return false;
    // Carry fractions because some browsers round scrollTop to whole pixels.
    const target = output.scrollTop + top - output.getBoundingClientRect().top - anchor.pixelOffset + (output.parentElement.anchorRemainder || 0);
    output.scrollTop = target;
    output.parentElement.anchorRemainder = target - output.scrollTop;
    return true;
  }};
}
function updateOutput(card) {
  if (!card.latest || card.latest.capturedLines < card.lines || card.selected || dragging || card.el.hidden) return;
  const key = JSON.stringify([card.latest.output, card.latest.defaultStyle]);
  const fullHistory = card.latest.history <= card.latest.capturedLines;
  card.fullHistory = fullHistory;
  if (key === card.rendered) return;
  const start = Math.max(0, (card.latest.history || 0) - card.latest.capturedLines);
  const rolled = Math.max(0, start - (card.renderedStart ?? start));
  const outputs = [...card.el.querySelectorAll('.output')];
  for (const [index, output] of outputs.entries()) {
    const screen = output.parentElement, restoring = 'savedAnchor' in screen;
    const atEnd = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
    const anchor = restoring ? screen.savedAnchor && scrollAnchor(output, screen.savedAnchor, rolled) : atEnd ? null : scrollAnchor(output, undefined, rolled);
    const fromBottom = output.scrollHeight - output.scrollTop;
    if (index === 0) renderAnsi(output, card.latest.output, card.latest.defaultStyle);
    else output.replaceChildren(...[...outputs[0].childNodes].map(node => node.cloneNode(true)));
    if (restoring ? !anchor?.restore() : atEnd || !anchor?.restore()) {
      output.scrollTop = restoring || atEnd ? output.scrollHeight : output.scrollHeight - fromBottom;
      screen.anchorRemainder = 0;
    }
    delete screen.savedAnchor;
    screen.outputScrollTop = output.scrollTop;
  }
  card.rendered = key;
  card.renderedStart = start;
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
        query.set('session', visible.latest.session);
        query.set('pane', visible.id);
      }
    }
    const parameters = query.toString();
    const {panes, initial, version} = await api("/api/panes" + (parameters ? '?' + parameters : ''));
    document.querySelector('#version').textContent = version ? 'v' + version : '';
    const cols = query.get('cols'), rows = query.get('rows');
    if (cols && rows && (cols !== lastCols || rows !== lastRows)) {
      resizedAt = performance.now();
      lastCols = cols; lastRows = rows;
    }
    const sessions = new Set(panes.map(pane => pane.session)).size;
    connection.textContent = sessions + " session" + (sessions === 1 ? "" : "s") + " connected with total " + panes.length + " agent" + (panes.length === 1 ? "" : "s");
    document.querySelector("#empty").hidden = !!panes.length;
    const keys = new Set(panes.map(paneKey));
    for (const pane of panes) {
      const card = cards.get(paneKey(pane)) || createCard(pane);
      if (card.closed) { card.closed = false; setSelection(card, card.selected); feedback(card, 'Agent reconnected'); }
      // Redraws after 2 seconds may flag unread; raise the window if seen.
      if (pane.role === 'manager' && card.latest && card.latest.output !== pane.output && card.key !== currentPane() && performance.now() - resizedAt > 2000) card.unread = true;
      card.needsAnswer = pane.menu;
      const boxText = inputBox(pane), now = performance.now();
      if (!boxText) card.boxSince = 0;
      else if (boxText !== card.boxText || card.latest?.output !== pane.output) card.boxSince = now;
      card.boxText = boxText;
      card.waitingText = !!boxText && now - card.boxSince >= BOX_WAIT_MS;
      const swapStatus = pane.swap || '';
      card.latest = {...pane, capturedLines: visible && visible.id === pane.id ? lines : 1000};
      if (card.swapState !== swapStatus) {
        card.swapState = swapStatus;
        clearTimeout(card.swapTimer);
        const state = card.el.querySelector('.swap-state');
        state.textContent = swapStatus;
        state.classList.toggle('error', swapStatus.startsWith('failed'));
        if (swapStatus.startsWith('done') || swapStatus.startsWith('failed')) card.swapTimer = setTimeout(() => { state.textContent = ''; }, 5000);
      }
      setSelection(card, card.selected);
      updateKeys(card);
      card.el.querySelector("h2").textContent = pane.name;
      const weekly = pane.weekly ? " / " + (pane.cli ? pane.cli + " " : "") + "weekly " + (100 - pane.weekly.usedPercent).toFixed(1) + "% left, resets " + new Date(pane.weekly.resetsAt * 1000).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}) : "";
      card.el.querySelector(".meta").textContent = pane.session + " / " + pane.role + " / " + pane.id + weekly;
      updateOutput(card);
    }
    for (const [key, card] of cards) {
      if (!keys.has(key)) {
        if (dismissed !== card.latest.session && (card.selected || card.el.querySelector('.message-form textarea').value || card.busy)) {
          if (!card.closed) feedback(card, 'This agent closed. Copy your text or discard it.', true);
          card.closed = true;
          card.boxText = ''; card.boxSince = 0; card.waitingText = false;
          setSelection(card, card.selected);
          panes.push({...card.latest, closed: true});
        } else { saveScreens(card, true); card.el.remove(); cards.delete(key); }
      }
    }
    document.querySelector('#empty').hidden = !!panes.length;
    if (dismissed && !panes.some(pane => pane.session === dismissed && !pane.closed)) {
      if (navigation.session === dismissed) navigation.session = undefined;
      dismissed = null;
    }
    if (openedSession && panes.some(pane => pane.session === openedSession && !pane.closed)) {
      if (!document.activeElement.matches('input, textarea') || !document.activeElement.value) navigation.session = openedSession;
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
api('/api/clis').then(clis => {
  availableClis = clis;
  swapForm.elements.cli.replaceChildren(...clis.map(cli => {
    const option = document.createElement('option'); option.value = cli; option.textContent = cli; return option;
  }));
  if (!swapForm.hidden) prefillSwap(cards.get(currentPane()));
}).catch(error => { connection.textContent = error.message; });
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
