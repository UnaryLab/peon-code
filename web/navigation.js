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
function tab(label, active, unread, onClick, key, needsAnswer, waitingText) {
  const button = document.createElement('button');
  button.type = 'button'; button.textContent = label; button.dataset.key = key;
  button.className = 'tab' + (active ? ' active' : '') + (unread ? ' unread' : '') + (needsAnswer || waitingText ? ' needs-answer' : '');
  button.setAttribute('aria-current', active ? 'true' : 'false');
  if (unread || needsAnswer || waitingText) button.setAttribute('aria-label', label + (unread ? ', new output' : '') + (needsAnswer ? ', waiting for an answer' : waitingText ? ', text waiting in the box' : ''));
  button.onclick = onClick;
  return button;
}
function replaceTabs(container, buttons) {
  const signature = JSON.stringify(buttons.map(button => [button.dataset.key, button.textContent, button.className, button.getAttribute('aria-label')]));
  if (container.dataset.signature === signature) return;
  const focused = container.contains(document.activeElement) ? document.activeElement.dataset.key : null;
  container.replaceChildren(...buttons); container.dataset.signature = signature;
  if (focused) buttons.find(button => button.dataset.key === focused)?.focus({preventScroll: true});
}
function updateNavigation() {
  const dismiss = document.querySelector('#dismiss');
  dismiss.hidden = !navigation.session;
  dismiss.disabled = dismissing || !navigation.panes.some(pane => pane.session === navigation.session && !pane.closed);
  const sessions = [...new Set(navigation.panes.map(pane => pane.session))];
  replaceTabs(document.querySelector('#sessions'), sessions.map(session => {
    const project = navigation.panes.find(pane => pane.session === session)?.projectDir || '';
    const label = session + (project ? ' · ' + project.split('/').pop() : '');
    const button = tab(label, session === navigation.session, navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.unread), () => chooseSession(session), session,
      navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.needsAnswer),
      navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.waitingText));
    button.title = project; return button;
  }));
  const project = navigation.panes.find(pane => pane.session === navigation.session)?.projectDir || '';
  document.querySelector('#project-path').textContent = project ? 'Folder: ' + project : '';
  replaceTabs(document.querySelector('#agents'), navigation.panes.filter(pane => pane.session === navigation.session).map(pane =>
    tab(pane.name + ' · ' + pane.role + (pane.closed ? ' · closed' : ''), paneKey(pane) === currentPane(), cards.get(paneKey(pane))?.unread, () => { navigation.active.set(navigation.session, paneKey(pane)); showPane(); }, paneKey(pane), cards.get(paneKey(pane))?.needsAnswer, cards.get(paneKey(pane))?.waitingText)));
}
function reconcileNavigation(panes, initial) {
  navigation.panes = panes.slice().sort((a, b) => a.session.localeCompare(b.session) || (roleOrder[a.role] ?? 2) - (roleOrder[b.role] ?? 2) || Number(a.id.slice(1)) - Number(b.id.slice(1)));
  if (navigation.session === null && panes.some(pane => pane.session === initial)) navigation.session = initial;
  if (!panes.some(pane => pane.session === navigation.session)) navigation.session = navigation.panes.find(pane => !pane.closed)?.session;
  for (const session of new Set(panes.map(pane => pane.session))) {
    if (!panes.some(pane => pane.session === session && paneKey(pane) === navigation.active.get(session))) {
      navigation.active.set(session, paneKey(navigation.panes.find(pane => pane.session === session)));
    }
  }
  showPane();
}
