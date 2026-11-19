const navigation = {session: null, active: new Map(), groups: new Map(), panes: []};
const roleOrder = {director: 0, manager: 1, worker: 2, reviewer: 3};
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
function agentTab(pane) {
  let figure = '';
  if (pane.usage) {
    const total = pane.usage.input + pane.usage.cacheRead + pane.usage.cacheWrite + pane.usage.output;
    // Promote K and M values when rounding reaches 1000.
    figure = ' · ' + (total >= 999995000 ? (total / 1000000000).toFixed(2) + 'B' : total >= 999950 ? (total / 1000000).toFixed(2) + 'M' : total >= 1000 ? (total / 1000).toFixed(1) + 'K' : total);
  }
  figure += pane.closed ? ' · closed' : '';
  const letter = ({director: 'D', manager: 'M', worker: 'W', reviewer: 'R'})[pane.role];
  const label = pane.name + (letter ? ' (' + letter + ')' : '');
  const button = tab(label + figure, paneKey(pane) === currentPane(), cards.get(paneKey(pane))?.unread, () => { navigation.active.set(navigation.session, paneKey(pane)); showPane(); }, paneKey(pane), cards.get(paneKey(pane))?.needsAnswer, cards.get(paneKey(pane))?.waitingText);
  const name = document.createElement('span'), text = document.createElement('span'), value = document.createElement('span');
  name.className = 'name'; text.textContent = label; name.append(text);
  value.className = 'figure'; value.textContent = figure;
  button.replaceChildren(name, value);
  return button;
}
function updateNavigation() {
  const dismiss = document.querySelector('#dismiss');
  dismiss.hidden = !navigation.session;
  dismiss.disabled = dismissing || !navigation.panes.some(pane => pane.session === navigation.session && !pane.closed);
  const sessions = [...new Set(navigation.panes.map(pane => pane.session))];
  replaceTabs(document.querySelector('#sessions'), sessions.map(session => {
    return tab(session, session === navigation.session, navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.unread), () => chooseSession(session), session,
      navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.needsAnswer),
      navigation.panes.some(pane => pane.session === session && cards.get(paneKey(pane))?.waitingText));
  }));
  const project = navigation.panes.find(pane => pane.session === navigation.session)?.projectDir || '';
  document.querySelector('#project-path').textContent = project ? 'Folder: ' + project : '';
  const viewed = navigation.panes.filter(pane => pane.session === navigation.session);
  replaceTabs(document.querySelector('#director-tabs'), viewed.filter(pane => pane.role === 'director').map(agentTab));
  const teams = [...new Set(viewed.filter(pane => pane.role !== 'director').map(pane => pane.team || pane.session))];
  const container = document.querySelector('#team-groups');
  const focused = container.contains(document.activeElement) ? document.activeElement.dataset.key : null;
  const signature = JSON.stringify([navigation.session, teams]);
  if (container.dataset.signature !== signature) {
    for (const group of container.children) navigation.groups.set(group.dataset.session, group.open);
    container.replaceChildren(...teams.map(team => {
      const group = document.createElement('details');
      group.dataset.team = team; group.dataset.session = JSON.stringify([navigation.session, team]);
      group.open = navigation.groups.get(group.dataset.session) ?? true;
      const summary = document.createElement('summary'), tabs = document.createElement('div');
      tabs.className = 'agent-tabs'; group.append(summary, tabs);
      group.ontoggle = () => { navigation.groups.set(group.dataset.session, group.open); updateNavigation(); };
      return group;
    }));
    container.dataset.signature = signature;
  }
  for (const group of container.children) {
    const panes = viewed.filter(pane => pane.role !== 'director' && (pane.team || pane.session) === group.dataset.team);
    const summary = group.querySelector('summary');
    summary.hidden = teams.length === 1 && !viewed.some(pane => pane.role === 'director');
    if (summary.hidden) group.open = true;
    const label = group.dataset.team;
    const unread = !group.open && panes.some(pane => cards.get(paneKey(pane))?.unread);
    const needsAnswer = !group.open && panes.some(pane => cards.get(paneKey(pane))?.needsAnswer);
    const waitingText = !group.open && panes.some(pane => cards.get(paneKey(pane))?.waitingText);
    summary.textContent = label + ' (' + panes.length + ')';
    summary.className = 'tab' + (unread ? ' unread' : '') + (needsAnswer || waitingText ? ' needs-answer' : '');
    summary.setAttribute('aria-label', summary.textContent + (unread ? ', new output' : '') + (needsAnswer ? ', waiting for an answer' : waitingText ? ', text waiting in the box' : ''));
    replaceTabs(group.querySelector('.agent-tabs'), panes.map(agentTab));
  }
  if (focused) [...container.querySelectorAll('[data-key]')].find(button => button.dataset.key === focused)?.focus({preventScroll: true});
  for (const name of document.querySelectorAll('#agents .name')) {
    const distance = name.firstElementChild.scrollWidth - name.clientWidth;
    if (distance > 0) name.parentElement.style.setProperty('--name-overflow', distance + 'px');
    else name.parentElement.style.removeProperty('--name-overflow');
  }
}
function reconcileNavigation(panes, initial) {
  navigation.panes = panes.slice().sort((a, b) => a.session.localeCompare(b.session) || (roleOrder[a.role] ?? 4) - (roleOrder[b.role] ?? 4) || Number(a.id.slice(1)) - Number(b.id.slice(1)));
  if (navigation.session === null && panes.some(pane => pane.session === initial)) navigation.session = initial;
  if (!panes.some(pane => pane.session === navigation.session)) navigation.session = navigation.panes.find(pane => !pane.closed)?.session;
  for (const session of new Set(panes.map(pane => pane.session))) {
    if (!panes.some(pane => pane.session === session && paneKey(pane) === navigation.active.get(session))) {
      navigation.active.set(session, paneKey(navigation.panes.find(pane => pane.session === session)));
    }
  }
  showPane();
}
