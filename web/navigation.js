const navigation = {session: null, active: new Map(), panes: []};
const roleOrder = {manager: 0, reviewer: 1, worker: 2};
function paneKey(pane) { return pane.identity ? pane.id + ':' + pane.identity : pane.id; }
function currentPane() { return navigation.active.get(navigation.session); }
function chooseSession(session) {
  navigation.session = session;
  const panes = navigation.panes.filter(pane => pane.session === session);
  if (!panes.some(pane => paneKey(pane) === currentPane())) navigation.active.set(session, panes[0] && paneKey(panes[0]));
  showPane();
}
function showPane() {
  for (const card of cards.values()) card.el.hidden = card.key !== currentPane();
  const card = cards.get(currentPane());
  if (card) { card.unread = false; if (!card.selected) updateOutput(card); }
  updateNavigation();
}
function tab(label, active, unread, onClick, key) {
  const button = document.createElement('button');
  button.type = 'button'; button.textContent = label; button.dataset.key = key;
  button.className = 'tab' + (active ? ' active' : '') + (unread ? ' unread' : '');
  button.setAttribute('aria-current', active ? 'true' : 'false');
  if (unread) button.setAttribute('aria-label', label + ', new output');
  button.onclick = onClick;
  return button;
}
function replaceTabs(container, buttons) {
  const signature = JSON.stringify(buttons.map(button => [button.dataset.key, button.textContent, button.className]));
  if (container.dataset.signature === signature) return;
  const focused = container.contains(document.activeElement) ? document.activeElement.dataset.key : null;
  container.replaceChildren(...buttons); container.dataset.signature = signature;
  if (focused) buttons.find(button => button.dataset.key === focused)?.focus({preventScroll: true});
}
function updateNavigation() {
  const sessions = [...new Set(navigation.panes.map(pane => pane.session))];
  replaceTabs(document.querySelector('#sessions'), sessions.map(session => {
    const project = navigation.panes.find(pane => pane.session === session)?.projectDir || '';
    const label = session + (project ? ' · ' + project.split('/').pop() : '');
    const button = tab(label, session === navigation.session, navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.unread), () => chooseSession(session), session);
    button.title = project; return button;
  }));
  const project = navigation.panes.find(pane => pane.session === navigation.session)?.projectDir || '';
  document.querySelector('#project-path').textContent = project ? 'Folder: ' + project : '';
  replaceTabs(document.querySelector('#agents'), navigation.panes.filter(pane => pane.session === navigation.session).map(pane =>
    tab(pane.name + ' · ' + pane.role + (pane.closed ? ' · closed' : ''), paneKey(pane) === currentPane(), cards.get(paneKey(pane))?.unread, () => { navigation.active.set(navigation.session, paneKey(pane)); showPane(); }, paneKey(pane))));
}
function reconcileNavigation(panes) {
  navigation.panes = panes.slice().sort((a, b) => a.session.localeCompare(b.session) || (roleOrder[a.role] ?? 2) - (roleOrder[b.role] ?? 2) || Number(a.id.slice(1)) - Number(b.id.slice(1)));
  if (!panes.some(pane => pane.session === navigation.session)) navigation.session = navigation.panes[0]?.session;
  for (const session of new Set(panes.map(pane => pane.session))) {
    if (!panes.some(pane => pane.session === session && paneKey(pane) === navigation.active.get(session))) {
      navigation.active.set(session, paneKey(navigation.panes.find(pane => pane.session === session)));
    }
  }
  showPane();
}
