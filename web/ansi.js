// Terminal text remains DOM text: escapes never become HTML or executable links.
const ANSI_PALETTE = ['#000000','#800000','#008000','#808000','#000080','#800080','#008080','#c0c0c0',
  '#808080','#ff0000','#00ff00','#ffff00','#0000ff','#ff00ff','#00ffff','#ffffff'];
function terminalColor(value) {
  if (/^#[0-9a-f]{6}$/i.test(value || '')) return value;
  if (/^colour\d+$/.test(value || '')) return indexedColor(Number(value.slice(6)));
  const names = ['black','red','green','yellow','blue','magenta','cyan','white'];
  if (names.includes(value)) return ANSI_PALETTE[names.indexOf(value)];
  if (value?.startsWith('bright') && names.includes(value.slice(6))) return ANSI_PALETTE[names.indexOf(value.slice(6)) + 8];
  return null;
}
function indexedColor(index) {
  if (!Number.isInteger(index) || index < 0 || index > 255) return null;
  if (index < 16) return ANSI_PALETTE[index];
  if (index > 231) { const gray = 8 + (index - 232) * 10; return `rgb(${gray}, ${gray}, ${gray})`; }
  const levels = [0,95,135,175,215,255]; const n = index - 16;
  return `rgb(${levels[Math.floor(n / 36)]}, ${levels[Math.floor(n / 6) % 6]}, ${levels[n % 6]})`;
}
function renderAnsi(output, text, defaultStyle = '', onSpan = null) {
  const defaults = {fg: '#d0d0d0', bg: '#000000'};
  for (const part of defaultStyle.split(',')) {
    const [key, value] = part.split('=');
    if ((key === 'fg' || key === 'bg') && terminalColor(value)) defaults[key] = terminalColor(value);
  }
  output.style.color = defaults.fg; output.style.backgroundColor = defaults.bg;
  let style = {}, gray = false, cursor = 0;
  const fragment = document.createDocumentFragment();
  function grayRgb(rgb) { return Math.max(...rgb) <= 249 && Math.max(...rgb) - Math.min(...rgb) <= 16; }
  function append(value) {
    if (!value) return;
    if (onSpan) onSpan(value, !!style.dim || gray);
    const span = document.createElement('span');
    span.textContent = value;
    span.style.color = style.reverse ? (style.bg || defaults.bg) : (style.fg || defaults.fg);
    span.style.backgroundColor = style.reverse ? (style.fg || defaults.fg) : (style.bg || defaults.bg);
    if (style.bold) span.style.fontWeight = 'bold';
    if (style.dim) span.style.opacity = '.65';
    if (style.italic) span.style.fontStyle = 'italic';
    span.style.textDecoration = [style.underline && 'underline', style.strike && 'line-through', style.overline && 'overline'].filter(Boolean).join(' ');
    if (style.hidden) span.style.visibility = 'hidden';
    fragment.append(span);
  }
  const escapes = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[^[]?/g;
  for (const match of text.matchAll(escapes)) {
    append(text.slice(cursor, match.index)); cursor = match.index + match[0].length;
    if (!/^\x1b\[[\d;:]*m$/.test(match[0])) continue;
    const values = match[0].slice(2, -1).split(';').map(value => value === '' ? 0 : value.includes(':') ? value : Number(value));
    for (let i = 0; i < values.length; i++) {
      let code = values[i];
      if (typeof code === 'string') {
        const parts = code.split(':').map(Number); code = parts[0];
        if ((code === 38 || code === 48) && parts[1] === 2) {
          const rgb = parts.slice(-3); if (rgb.every(n => n >= 0 && n <= 255)) { style[code === 38 ? 'fg' : 'bg'] = `rgb(${rgb.join(', ')})`; if (code === 38) gray = grayRgb(rgb); }
        } else if ((code === 38 || code === 48) && parts[1] === 5) { style[code === 38 ? 'fg' : 'bg'] = indexedColor(parts[2]); if (code === 38) gray = parts[2] >= 232 && parts[2] <= 249; }
        continue;
      }
      if (code === 0) { style = {}; gray = false; }
      else if (code === 1) style.bold = true;
      else if (code === 2) style.dim = true;
      else if (code === 3) style.italic = true;
      else if (code === 4 || code === 21) style.underline = true;
      else if (code === 7) style.reverse = true;
      else if (code === 8) style.hidden = true;
      else if (code === 9) style.strike = true;
      else if (code === 22) { delete style.bold; delete style.dim; }
      else if (code === 23) delete style.italic;
      else if (code === 24) delete style.underline;
      else if (code === 27) delete style.reverse;
      else if (code === 28) delete style.hidden;
      else if (code === 29) delete style.strike;
      else if (code === 53) style.overline = true;
      else if (code === 55) delete style.overline;
      else if (code === 39) { delete style.fg; gray = false; }
      else if (code === 49) delete style.bg;
      else if (code >= 30 && code <= 37) { style.fg = indexedColor(code - 30); gray = false; }
      else if (code >= 40 && code <= 47) style.bg = indexedColor(code - 40);
      else if (code >= 90 && code <= 97) { style.fg = indexedColor(code - 90 + 8); gray = code === 90; }
      else if (code >= 100 && code <= 107) style.bg = indexedColor(code - 100 + 8);
      else if (code === 38 || code === 48) {
        const key = code === 38 ? 'fg' : 'bg', mode = values[++i];
        if (mode === 5) { const index = values[++i]; style[key] = indexedColor(index); if (code === 38) gray = index >= 232 && index <= 249; }
        else if (mode === 2) { const rgb = values.slice(i + 1, i + 4); i += 3; if (rgb.length === 3 && rgb.every(n => Number.isInteger(n) && n >= 0 && n <= 255)) { style[key] = `rgb(${rgb.join(', ')})`; if (code === 38) gray = grayRgb(rgb); } }
      }
      else if (code === 58) { const mode = values[++i]; i += mode === 5 ? 1 : mode === 2 ? 3 : 0; }
    }
  }
  append(text.slice(cursor)); output.replaceChildren(fragment);
}
function restoreSelection(output, selected) {
  const start = output.textContent.indexOf(selected);
  if (start < 0) return;
  const walker = document.createTreeWalker(output, NodeFilter.SHOW_TEXT);
  const range = document.createRange(); let position = 0, node, started = false;
  while ((node = walker.nextNode())) {
    const end = position + node.length;
    if (!started && start < end) { range.setStart(node, start - position); started = true; }
    if (started && start + selected.length <= end) {
      range.setEnd(node, start + selected.length - position); getSelection().removeAllRanges(); getSelection().addRange(range); return;
    }
    position = end;
  }
}
