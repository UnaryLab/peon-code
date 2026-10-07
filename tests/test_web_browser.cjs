// Optional: NODE_PATH=<installed Playwright directory> node tests/test_web_browser.cjs <launch-url>
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
(async () => {
  const url = process.argv[2]; assert(url, 'Pass a running peon-code-web launch URL');
  const token = new URL(url).hash.slice(1);
  const browser = await chromium.launch({headless: true, chromiumSandbox: false});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 950}});
    await page.route('**/app.js', async route => {
      const response = await route.fetch(), script = await response.text();
      assert(script.includes('const BOX_WAIT_MS = 10000;'));
      await route.fulfill({response, body: script.replace('const BOX_WAIT_MS = 10000;', 'const BOX_WAIT_MS = 1000;')});
    });
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error' && /Content Security|Refused|unsafe/i.test(message.text())) errors.push(message.text()); });
    const roles = [
      {id: '%5', name: 'Builder', role: 'worker', session: 'alpha'},
      {id: '%2', name: 'Reviewer', role: 'reviewer', session: 'alpha'},
      {id: '%3', name: 'Boss', role: 'manager', session: 'alpha'},
      {id: '%8', name: 'Lead', role: 'manager', session: 'zeta'},
      {id: '%9', name: 'Check', role: 'reviewer', session: 'zeta'},
      {id: '%10', name: 'Build', role: 'worker', session: 'zeta'}
    ];
    for (const pane of roles) pane.identity = 'first:' + pane.id;
    let empty = false, blocked = true, explainDelay = 0, sendError = null;
    const revision = Object.fromEntries(roles.map(pane => [pane.id, 0]));
    const menu = {};
    const screen = {};
    const cursorY = {};
    const menuShown = {};
    const sent = [];
    const firstLine = "It's quoted 日本語 <script>alert('x')</script>.";
    const output = "\x1b[38;2;200;30;40mIt's \x1b[38;5;46;48;2;10;20;30mquoted 日本語 <script>alert('x')</script>.\x1b[0m\n" +
      '\x1b[91mBright\x1b[48;5;17mBlue bg\x1b[38:2::1:2:3mColon RGB\x1b[1;3;4mStyle\x1b[0mAfter\n' + 'A line of agent output.\n'.repeat(70);
    await page.route('**/api/panes', route => {
      assert.equal(route.request().headers()['x-peon-token'], token);
      return route.fulfill({json: {panes: empty ? [] : roles.map(pane => ({...pane, projectDir: '/work/' + pane.session + ' project', command: 'codex', output: output + revision[pane.id] + (menu[pane.id] || ''), screen: screen[pane.id] || '', cursorY: cursorY[pane.id] ?? -1, menu: !!menuShown[pane.id], defaultStyle: 'fg=#abcdef,bg=#123456'}))}});
    });
    await page.route('**/api/explain', async route => {
      sent.push(route.request().postDataJSON());
      if (explainDelay) await new Promise(resolve => setTimeout(resolve, explainDelay));
      return route.fulfill({status: blocked ? 409 : 200, json: blocked ? {error: 'target box busy'} : {message: 'Explained'}});
    });
    await page.route('**/api/send', async route => {
      sent.push(route.request().postDataJSON());
      const error = sendError;
      await new Promise(resolve => setTimeout(resolve, 300));
      await route.fulfill({status: error ? 409 : 200, json: error ? {error} : {message: 'Message sent'}});
    });
    let keyRequest, keyDelay = 0, keyCount = 0;
    await page.route('**/api/keys', async route => {
      keyCount++;
      keyRequest = route.request().postDataJSON();
      if (keyDelay) await new Promise(resolve => setTimeout(resolve, keyDelay));
      await route.fulfill({json: {message: 'Key sent'}});
    });
    const card = id => page.locator(`.pane[data-pane="${id}"]`);
    const paneTab = id => page.locator(`#agents [data-key="${id}:${roles.find(pane => pane.id === id).identity}"]`);
    const sessionTab = name => page.locator(`#sessions [data-key="${name}"]`);
    async function selectFirstLine() {
      await card('%3').locator('.output').evaluate(el => {
        el.scrollTop = 0;
        const nodes = el.querySelectorAll('span'); const range = document.createRange();
        range.setStart(nodes[0].firstChild, 0); range.setEnd(nodes[1].firstChild, nodes[1].textContent.length);
        getSelection().removeAllRanges(); getSelection().addRange(range);
      });
      await page.waitForFunction(() => !document.querySelector('.pane:not([hidden]) .explain').disabled);
    }
    await page.goto(url); await page.waitForSelector('.pane:not([hidden])');
    assert.equal(await page.locator('.pane:not([hidden])').getAttribute('data-pane'), '%3');
    assert.deepEqual(await page.locator('#agents button').allTextContents(), ['Boss · manager', 'Reviewer · reviewer', 'Builder · worker']);
    assert.equal(await page.locator('.tab.unread').count(), 0);
    assert.equal(await page.locator('#project-path').textContent(), 'Folder: /work/alpha project');
    assert.equal(await page.locator('#right-click').isChecked(), true);
    await card('%3').locator('.output').press('ArrowDown');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Key sent');
    assert.deepEqual(keyRequest, {pane: '%3', identity: 'first:%3', key: 'Down'});
    const colors = await card('%3').locator('.output').evaluate(el => ({
      bg: getComputedStyle(el).backgroundColor, fg: getComputedStyle(el).color,
      spans: [...el.querySelectorAll('span')].slice(0, 8).map(span => ({text: span.textContent, fg: getComputedStyle(span).color, bg: getComputedStyle(span).backgroundColor, bold: getComputedStyle(span).fontWeight, italic: getComputedStyle(span).fontStyle}))
    }));
    assert.equal(colors.bg, 'rgb(18, 52, 86)'); assert.equal(colors.fg, 'rgb(171, 205, 239)');
    assert.equal(colors.spans[0].fg, 'rgb(200, 30, 40)'); assert.equal(colors.spans[1].fg, 'rgb(0, 255, 0)'); assert.equal(colors.spans[1].bg, 'rgb(10, 20, 30)');
    assert(colors.spans.some(span => span.text === 'Bright' && span.fg === 'rgb(255, 0, 0)'));
    assert(colors.spans.some(span => span.text === 'Blue bg' && span.bg === 'rgb(0, 0, 95)'));
    assert(colors.spans.some(span => span.text === 'Colon RGB' && span.fg === 'rgb(1, 2, 3)'));
    assert(colors.spans.some(span => span.text === 'Style' && span.bold === '700' && span.italic === 'italic'));
    assert.equal(await card('%3').locator('script').count(), 0);
    const widths = await card('%3').evaluate(el => [el.getBoundingClientRect().width, el.parentElement.getBoundingClientRect().width]);
    assert.equal(widths[0], widths[1]);
    assert(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight));
    assert(await card('%3').locator('.output').evaluate(el => el.getBoundingClientRect().height > innerHeight * 0.65));
    const resized = await card('%3').evaluate(el => {
      const textarea = el.querySelector('textarea'); const original = textarea.style.height;
      textarea.style.height = '10000px';
      const result = {
        outputHeight: el.querySelector('.output').getBoundingClientRect().height,
        controlsVisible: ['textarea', 'form button', '.feedback'].every(selector => {
          const rect = el.querySelector(selector).getBoundingClientRect(); return rect.top >= 0 && rect.bottom <= innerHeight;
        })
      };
      textarea.style.height = original; return result;
    });
    assert(resized.outputHeight > 0); assert(resized.controlsVisible);
    assert.deepEqual(await page.evaluate(() => {
      const pane = {screen: '› Typed', output: '› Typed\n', cursorY: 0, menu: false};
      return [inputBox({...pane, cursorY: -1}), inputBox({...pane, cursorY: 99}), inputBox({...pane, cursorY: '0'}), inputBox({...pane, screen: 'Prose › Typed'}), inputBox({...pane, output: '› Different\n'})];
    }), ['', '', '', '', '']);
    menu['%5'] = '\nHistorical › marker\n  › Typed input\n\n';
    screen['%5'] = '  › Typed input\n\n'; cursorY['%5'] = 0;
    await paneTab('%5').click();
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith('Typed input\n\n'));
    assert.equal(await paneTab('%5').evaluate(el => el.classList.contains('needs-answer')), false);
    await page.waitForFunction(() => document.querySelector('#agents [data-key="%5:first:%5"]').getAttribute('aria-label')?.endsWith(', text waiting in the box'));
    assert((await sessionTab('alpha').getAttribute('aria-label')).endsWith(', text waiting in the box'));
    await paneTab('%5').click();
    assert(await paneTab('%5').evaluate(el => el.classList.contains('needs-answer')));
    revision['%5']++;
    await page.waitForFunction(() => !document.querySelector('#agents [data-key="%5:first:%5"]').classList.contains('needs-answer'));
    assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('needs-answer')), false);
    await page.waitForFunction(() => document.querySelector('#agents [data-key="%5:first:%5"]').classList.contains('needs-answer'));
    menuShown['%5'] = true;
    await page.waitForFunction(() => document.querySelector('#agents [data-key="%5:first:%5"]').getAttribute('aria-label')?.endsWith(', waiting for an answer'));
    assert((await sessionTab('alpha').getAttribute('aria-label')).endsWith(', waiting for an answer'));
    menuShown['%5'] = false;
    menu['%5'] = '\n  › \n\n'; screen['%5'] = '  › \n\n';
    await page.waitForFunction(() => !document.querySelector('#agents [data-key="%5:first:%5"]').classList.contains('needs-answer'));
    assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('needs-answer')), false);
    for (const [name, style] of [['dim', '\x1b[2m'], ['gray', '\x1b[38;5;242m']]) {
      menu['%5'] = '\n  › ' + style + name + ' hint\x1b[0m\n\n'; screen['%5'] = '  › ' + name + ' hint\n\n';
      await page.waitForFunction(label => document.querySelector('.pane[data-pane="%5"] .key-shortcuts').textContent === 'Tab: ' + label, name + ' hint');
      await page.waitForTimeout(1400);
      assert.equal(await paneTab('%5').evaluate(el => el.classList.contains('needs-answer')), false);
      assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('needs-answer')), false);
    }
    cursorY['%5'] = -1; menu['%5'] = ''; screen['%5'] = '';
    await paneTab('%3').click();
    menu['%5'] = '\n\x1b[31m❯\x1b[0m 1. Accept';
    screen['%5'] = '  1. Prose example\n  2. Another example\n\n❯ 1. Accept\n  2. ' + 'Long menu label '.repeat(5) + '\n';
    menuShown['%5'] = true;
    await page.waitForSelector('#agents [data-key="%5:first:%5"].needs-answer');
    assert(await sessionTab('alpha').evaluate(el => el.classList.contains('needs-answer')));
    assert((await paneTab('%5').getAttribute('aria-label')).endsWith(', waiting for an answer'));
    await paneTab('%5').click();
    assert(await paneTab('%5').evaluate(el => el.classList.contains('needs-answer')));
    const shortcuts = card('%5').locator('.key-shortcuts button');
    assert.deepEqual(await shortcuts.allTextContents(), ['1. Accept', ('2. ' + 'Long menu label '.repeat(5)).slice(0, 40), 'Enter', 'Esc']);
    assert.equal((await shortcuts.nth(1).textContent()).length, 40);
    assert.deepEqual((await shortcuts.allTextContents()).slice(2), ['Enter', 'Esc']);
    assert.equal(await card('%5').locator('.keys-toggle').getAttribute('aria-expanded'), 'false');
    assert(await card('%5').locator('.key-shortcuts').evaluate(el => el.previousElementSibling.className === 'key-buttons'));
    await card('%5').locator('.keys-toggle').click();
    assert.deepEqual(await card('%5').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Tab', ...await shortcuts.allTextContents()]);
    for (const key of ['1', '2', 'Enter', 'Escape']) assert.equal(await card('%5').locator(`.keys button[data-key="${key}"]:visible`).count(), 1);
    for (const key of ['3', '4', '5', '6', '7', '8', '9']) assert.equal(await card('%5').locator(`.keys button[data-key="${key}"]:visible`).count(), 0);
    const menuKeyCount = keyCount, menuMessageCount = sent.length;
    await card('%5').locator('textarea').fill(' \n'); await card('%5').locator('form button').click();
    await card('%5').locator('textarea').fill(''); await card('%5').locator('textarea').press('Shift+Enter');
    await page.waitForTimeout(350);
    assert.equal(keyCount, menuKeyCount); assert.equal(sent.length, menuMessageCount);
    await card('%5').locator('.key-shortcuts button[data-key="Enter"]').click();
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .feedback').textContent === 'Pressed Enter');
    assert.deepEqual(keyRequest, {pane: '%5', identity: 'first:%5', key: 'Enter'});
    assert.equal(keyCount, menuKeyCount + 1);
    await card('%5').locator('textarea').fill('Keep the shortcut draft');
    await card('%5').locator('.output').evaluate(el => {
      const node = el.querySelector('span').firstChild, range = document.createRange();
      range.setStart(node, 0); range.setEnd(node, 4);
      getSelection().removeAllRanges(); getSelection().addRange(range);
    });
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .state').textContent === 'Paused');
    keyDelay = 500;
    await shortcuts.first().click();
    await page.waitForFunction(() => [...document.querySelectorAll('.pane[data-pane="%5"] .keys button')].every(button => button.disabled));
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .feedback').textContent === 'Key sent');
    assert.deepEqual(keyRequest, {pane: '%5', identity: 'first:%5', key: '1'});
    assert.equal(await card('%5').locator('textarea').inputValue(), 'Keep the shortcut draft');
    assert.equal(await page.evaluate(() => getSelection().toString()), "It's");
    await card('%5').locator('.resume').click();
    await card('%5').locator('textarea').fill('');
    keyDelay = 0;
    const savedMenu = menu['%5'];
    const codexRows = ['❯ 1. Old numbered prose', '  2. More prose', '', '  Quoted choice (y)', '  Quoted always (a)', '', '  Yes, proceed (y)', '› Yes, and ' + 'do not ask again '.repeat(4) + '(a)', '  No, tell Codex what to do differently (n)', '  Duplicate yes (y)', '', '  Enter to confirm'];
    const codexLabels = ['1. Yes, proceed', ('2. Yes, and ' + 'do not ask again '.repeat(4).trim()).slice(0, 40), '3. No, tell Codex what to do differently', 'Enter', 'Esc'];
    for (const [cursor, footer] of [[7, ''], [11, '\n  Footer capture']]) {
      screen['%5'] = codexRows.join('\n') + footer + '\n'; cursorY['%5'] = cursor;
      menu['%5'] = '\n' + screen['%5'];
      await page.waitForFunction(text => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith(text), screen['%5']);
      assert.deepEqual(await shortcuts.allTextContents(), codexLabels);
      assert.deepEqual(await card('%5').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Tab', ...codexLabels]);
      for (const key of ['y', 'a', 'n', 'Enter', 'Escape']) assert.equal(await card('%5').locator(`.keys button[data-key="${key}"]:visible`).count(), 1);
      for (const key of ['y', 'a', 'n']) {
        await card('%5').locator(`.key-shortcuts button[data-key="${key}"]`).click();
        await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .feedback').textContent === 'Key sent');
        assert.deepEqual(keyRequest, {pane: '%5', identity: 'first:%5', key});
      }
    }
    for (const plainInput of ['› fix item (a)', '› Another action (b)\n  Yes, proceed (y)']) {
      screen['%5'] = plainInput; cursorY['%5'] = 0; menu['%5'] = '\n' + plainInput;
      await page.waitForFunction(text => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith(text), plainInput);
      assert.deepEqual(await shortcuts.allTextContents(), ['Enter', 'Esc']);
      assert(await card('%5').locator('.key-buttons button[data-key="1"]').isVisible());
    }
    const genericLabels = ['1. Yes, proceed', '2. Another action', 'Enter', 'Esc'];
    for (const [cursor, footer] of [[0, ''], [3, '\n  Generic footer capture']]) {
      screen['%5'] = '› Yes, proceed (y)\n  Another action (b)\n\n  Enter to confirm' + footer; cursorY['%5'] = cursor;
      menu['%5'] = '\n' + screen['%5'];
      await page.waitForFunction(text => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith(text), screen['%5']);
      assert.deepEqual(await card('%5').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Tab', ...genericLabels]);
      for (const key of ['y', 'b']) {
        await card('%5').locator(`.key-shortcuts button[data-key="${key}"]`).click();
        await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .feedback').textContent === 'Key sent');
        assert.deepEqual(keyRequest, {pane: '%5', identity: 'first:%5', key});
      }
    }
    screen['%5'] = '› Yes, proceed (y)\n  No (n)\n\n› typed text'; cursorY['%5'] = 3;
    menu['%5'] = '\n' + screen['%5'];
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith('› typed text'));
    assert.deepEqual(await shortcuts.allTextContents(), ['Enter', 'Esc']);
    assert(await card('%5').locator('.key-buttons button[data-key="1"]').isVisible());
    cursorY['%5'] = -1;
    menu['%5'] = savedMenu;
    for (const unparsedMenu of ['Enter to confirm', '    1. Indented choice\n    2. Another choice']) {
      screen['%5'] = unparsedMenu;
      menu['%5'] += '\n' + unparsedMenu;
      await page.waitForFunction(text => document.querySelector('.pane[data-pane="%5"] .output').textContent.endsWith(text), unparsedMenu);
      await page.waitForFunction(() => document.querySelector('.pane[data-pane="%5"] .key-shortcuts').textContent === 'EnterEsc');
      assert.deepEqual(await card('%5').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Tab', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'Enter', 'Esc']);
      for (const key of ['Enter', 'Escape']) assert.equal(await card('%5').locator(`.keys button[data-key="${key}"]:visible`).count(), 1);
    }
    menu['%5'] += '\n' + 'Answered\n'.repeat(6);
    menuShown['%5'] = false;
    screen['%5'] = 'Answered\n';
    await page.waitForFunction(() => !document.querySelector('#agents [data-key="%5:first:%5"]').classList.contains('needs-answer'));
    assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('needs-answer')), false);
    assert((await card('%5').locator('.output').textContent()).includes('❯ 1. Accept'));
    assert.equal(await shortcuts.count(), 0);
    assert.deepEqual(await card('%5').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Tab', 'Enter', 'Esc', '1', '2', '3', '4', '5', '6', '7', '8', '9']);
    await paneTab('%3').click();
    menu['%3'] = '\n❯ \x1b[2m' + 'Try a hint '.repeat(10) + '\x1b[22m';
    screen['%3'] = '❯ ' + 'Try a hint '.repeat(10);
    const hintChip = card('%3').locator('.key-shortcuts button[data-key="Tab"]');
    await hintChip.waitFor();
    assert((await hintChip.textContent()).startsWith('Tab: Try a hint'));
    assert.equal((await hintChip.textContent()).length, 60);
    await card('%3').locator('.keys-toggle').click();
    assert.equal(await card('%3').locator('.keys button[data-key="Tab"]:visible').count(), 1);
    assert.deepEqual(await card('%3').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', 'Enter', 'Esc', '1', '2', '3', '4', '5', '6', '7', '8', '9', await hintChip.textContent()]);
    await hintChip.click();
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%3"] .feedback').textContent === 'Key sent');
    assert.deepEqual(keyRequest, {pane: '%3', identity: 'first:%3', key: 'Tab'});
    menu['%3'] = '\n› \x1b[38;5;242mGray hint\x1b[39m'; screen['%3'] = '› Gray hint';
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%3"] .key-shortcuts').textContent === 'Tab: Gray hint');
    menu['%3'] += '\n› typed text'; screen['%3'] = '› typed text';
    await page.waitForFunction(() => !document.querySelector('.pane[data-pane="%3"] .key-shortcuts button'));
    assert(await card('%3').locator('.key-buttons button[data-key="Tab"]').isVisible());
    menu['%3'] = ''; screen['%3'] = '';
    for (const id of ['%5', '%2', '%9', '%10']) revision[id] = 1;
    revision['%3'] = 1;
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%3"] .output').textContent.endsWith('1'));
    for (const id of ['%5', '%2']) assert.equal(await paneTab(id).evaluate(el => el.classList.contains('unread')), false);
    for (const name of ['alpha', 'zeta']) assert.equal(await sessionTab(name).evaluate(el => el.classList.contains('unread')), false);
    await sessionTab('zeta').click();
    for (const id of ['%9', '%10']) assert.equal(await paneTab(id).evaluate(el => el.classList.contains('unread')), false);
    await paneTab('%10').click(); await sessionTab('alpha').click(); await paneTab('%5').click();
    await paneTab('%3').focus(); revision['%3'] = 2; revision['%8'] = 1;
    await page.waitForSelector('#agents [data-key="%3:first:%3"].unread');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.key), '%3:first:%3');
    assert(await sessionTab('alpha').evaluate(el => el.classList.contains('unread')));
    assert(await sessionTab('zeta').evaluate(el => el.classList.contains('unread')));
    await paneTab('%3').click(); assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('unread')), false);
    await page.locator('#right-click').uncheck(); await selectFirstLine();
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    const frozen = await card('%3').locator('.output').textContent(); revision['%3'] = 3;
    await page.waitForTimeout(1400);
    assert.equal(await card('%3').locator('.output').textContent(), frozen);
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    await card('%3').locator('.output').click({button: 'right'}); assert.equal(sent.length, 0);
    await card('%3').locator('.explain').click();
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'target box busy');
    assert.deepEqual(sent[0], {pane: '%3', identity: 'first:%3', text: firstLine});
    await page.evaluate(() => Object.defineProperty(navigator, 'clipboard', {value: {writeText: () => Promise.reject(new Error('Denied'))}, configurable: true}));
    await card('%3').locator('.copy').click();
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent.includes('Ctrl + C'));
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    blocked = false; await card('%3').locator('.explain').click();
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Explained');
    assert.deepEqual(sent[1], {pane: '%3', identity: 'first:%3', text: firstLine});
    await page.locator('#right-click').check(); await selectFirstLine();
    await card('%3').locator('.output').click({button: 'right'});
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .state').textContent === 'Live');
    assert.deepEqual(sent[2], {pane: '%3', identity: 'first:%3', text: firstLine});
    explainDelay = 300;
    await selectFirstLine(); await card('%3').locator('.explain').click();
    await card('%3').locator('.output').evaluate(el => {
      const node = el.querySelector('span').firstChild; const range = document.createRange();
      range.setStart(node, 0); range.setEnd(node, 4);
      getSelection().removeAllRanges(); getSelection().addRange(range);
    });
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Explained');
    assert.equal(await page.evaluate(() => getSelection().toString()), "It's");
    assert.equal(await card('%3').locator('.state').textContent(), 'Paused');
    assert(await card('%3').locator('.explain').isEnabled());
    await card('%3').locator('.resume').click();
    async function selectRepeatedLine(second) {
      await card('%3').locator('.output').evaluate((el, second) => {
        const text = 'A line of agent output.';
        const node = [...el.querySelectorAll('span')].find(span => span.textContent.includes(text)).firstChild;
        const first = node.textContent.indexOf(text);
        const start = second ? node.textContent.indexOf(text, first + text.length) : first;
        const range = document.createRange(); range.setStart(node, start); range.setEnd(node, start + text.length);
        getSelection().removeAllRanges(); getSelection().addRange(range);
      }, second);
    }
    await selectRepeatedLine(false);
    await page.waitForFunction(() => !document.querySelector('.pane:not([hidden]) .explain').disabled);
    await card('%3').locator('.explain').click();
    await selectRepeatedLine(true);
    const repeatedStart = await page.evaluate(() => getSelection().getRangeAt(0).startOffset);
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Explained');
    assert.equal(await page.evaluate(() => getSelection().toString()), 'A line of agent output.');
    assert.equal(await page.evaluate(() => getSelection().getRangeAt(0).startOffset), repeatedStart);
    assert.equal(await card('%3').locator('.state').textContent(), 'Paused');
    await card('%3').locator('.resume').click();
    await selectFirstLine(); await card('%3').locator('.explain').click();
    await paneTab('%2').click();
    await card('%2').locator('.output').evaluate(el => {
      const node = el.querySelector('span').firstChild; const range = document.createRange();
      range.setStart(node, 0); range.setEnd(node, 4);
      getSelection().removeAllRanges(); getSelection().addRange(range);
    });
    await page.waitForFunction(() => document.querySelector('.pane[data-pane="%3"] .feedback').textContent === 'Explained');
    assert.equal(await page.evaluate(() => getSelection().toString()), "It's");
    assert.equal(await card('%2').locator('.state').textContent(), 'Paused');
    assert.equal(await card('%3').locator('.state').textContent(), 'Live');
    await card('%2').locator('.resume').click(); await paneTab('%3').click(); explainDelay = 0;
    const messageBox = card('%3').locator('textarea'); const keyboardStart = sent.length;
    assert.equal(await messageBox.getAttribute('placeholder'), 'Ask this agent something… (Shift+Enter to send)');
    await messageBox.fill('Keyboard message'); await messageBox.press('Shift+Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) textarea').value === '');
    assert.equal(sent.length, keyboardStart + 1);
    assert.deepEqual(sent[keyboardStart], {pane: '%3', identity: 'first:%3', text: 'Keyboard message', append: true});
    await messageBox.fill('First line'); await messageBox.press('Enter');
    assert.equal(await messageBox.inputValue(), 'First line\n');
    assert(await messageBox.evaluate(el => el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', shiftKey: true, isComposing: true, bubbles: true, cancelable: true}))));
    await page.waitForTimeout(350); assert.equal(sent.length, keyboardStart + 1);
    assert.equal(await page.locator('.append, .append-action').count(), 0);
    sendError = 'target input box holds typed text';
    const message = "It's `quoted`\n日本語";
    await messageBox.fill(message); await messageBox.press('Shift+Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'target input box holds typed text');
    assert.deepEqual(sent[sent.length - 1], {pane: '%3', identity: 'first:%3', text: message, append: true});
    assert.equal(await messageBox.inputValue(), message);
    sendError = null;
    await messageBox.fill('Changed append draft'); await messageBox.press('Shift+Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) textarea').value === '');
    assert.deepEqual(sent[sent.length - 1], {pane: '%3', identity: 'first:%3', text: 'Changed append draft', append: true});
    await messageBox.fill('Next message'); await messageBox.press('Shift+Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) textarea').value === '');
    assert.deepEqual(sent[sent.length - 1], {pane: '%3', identity: 'first:%3', text: 'Next message', append: true});
    const messageCount = sent.length;
    keyDelay = 300;
    await messageBox.fill(' \n\t'); await card('%3').locator('form button').click();
    assert(await card('%3').locator('form button').isDisabled());
    await messageBox.fill('Draft during Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Pressed Enter');
    assert.deepEqual(keyRequest, {pane: '%3', identity: 'first:%3', key: 'Enter'});
    assert.equal(await messageBox.inputValue(), 'Draft during Enter');
    keyDelay = 0;
    await messageBox.fill(''); await messageBox.press('Shift+Enter');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Pressed Enter');
    assert.deepEqual(keyRequest, {pane: '%3', identity: 'first:%3', key: 'Enter'});
    assert.equal(sent.length, messageCount);
    await card('%3').locator('textarea').fill('Original message'); await card('%3').locator('form button').click();
    await card('%3').locator('textarea').fill('New draft');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Message sent');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'New draft');
    await card('%3').locator('textarea').fill('Repeat'); await card('%3').locator('form button').click();
    await card('%3').locator('textarea').fill('Other'); await card('%3').locator('textarea').fill('Repeat');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Message sent');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'Repeat');
    await card('%3').locator('textarea').fill('New draft');
    await sessionTab('zeta').click(); assert(await card('%10').isVisible());
    assert.equal(await page.locator('#project-path').textContent(), 'Folder: /work/zeta project');
    assert(await paneTab('%8').evaluate(el => el.classList.contains('unread')));
    await paneTab('%8').click(); assert.equal(await sessionTab('zeta').evaluate(el => el.classList.contains('unread')), false);
    assert(await card('%8').locator('.output').evaluate(el => el.scrollTop > 0));
    await sessionTab('alpha').click(); assert(await card('%3').isVisible());
    assert.equal(await card('%3').locator('textarea').inputValue(), 'New draft');
    await paneTab('%5').click(); assert.equal(await sessionTab('alpha').evaluate(el => el.classList.contains('unread')), false);
    await paneTab('%3').click(); await selectFirstLine();
    await paneTab('%2').click(); await paneTab('%3').click();
    assert.equal(await card('%3').locator('.state').textContent(), 'Paused');
    await card('%3').locator('.resume').click();
    await card('%3').locator('.output').evaluate(el => { el.scrollTop = 0; });
    await card('%3').locator('.output').hover(); await page.mouse.wheel(0, 200);
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .output').scrollTop > 0);
    await page.screenshot({path: '/tmp/peon-code-web-desktop.png', fullPage: true});
    await page.reload(); await page.waitForSelector('.pane:not([hidden])');
    await page.locator('.brand').click(); await page.waitForSelector('.pane:not([hidden])');
    await page.setViewportSize({width: 375, height: 812});
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.screenshot({path: '/tmp/peon-code-web-mobile.png', fullPage: true});
    assert.equal(await page.locator('.top-links a').count(), 3);
    await card('%3').locator('textarea').fill('Keep this draft');
    await selectFirstLine();
    menu['%3'] = '\n❯ \x1b[2mHint\x1b[0m\n  2. Other'; screen['%3'] = '❯ Hint\n  2. Other'; menuShown['%3'] = true;
    await card('%3').locator('.key-shortcuts button[data-key="Tab"]').waitFor();
    await card('%3').locator('.keys-toggle').click();
    assert.deepEqual(await card('%3').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', '2. Other', 'Enter', 'Esc', 'Tab: Hint']);
    empty = true;
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .state').textContent === 'Closed');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'Keep this draft');
    assert(await card('%3').locator('.explain').isDisabled());
    assert(await card('%3').locator('form button').isDisabled());
    assert(await card('%3').locator('.keys button').evaluateAll(buttons => buttons.every(button => button.disabled)));
    assert.equal(await card('%3').locator('.keys-toggle').getAttribute('aria-expanded'), 'true');
    assert.deepEqual(await card('%3').locator('.keys button:visible').allTextContents(), ['Keys', 'Up', 'Down', '2. Other', 'Enter', 'Esc', 'Tab: Hint']);
    assert.equal(await paneTab('%3').textContent(), 'Boss · manager · closed');
    const deliveries = sent.length;
    await card('%3').locator('.output').click({button: 'right'});
    assert.equal(sent.length, deliveries);
    await page.evaluate(() => Object.defineProperty(navigator, 'clipboard', {value: {writeText: () => Promise.reject(new Error('Denied'))}, configurable: true}));
    await card('%3').locator('.copy').click();
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    empty = false;
    roles.splice(0, roles.length, {id: '%3', identity: 'restarted:%3', name: 'New boss', role: 'manager', session: 'alpha'});
    const oldCard = page.locator('.pane[data-key="%3:first:%3"]');
    const newCard = page.locator('.pane[data-key="%3:restarted:%3"]');
    await page.waitForSelector('.pane[data-key="%3:restarted:%3"]', {state: 'attached'});
    assert.equal(await oldCard.locator('textarea').inputValue(), 'Keep this draft');
    assert.equal(await oldCard.locator('h2').textContent(), 'Boss');
    assert(await oldCard.locator('.explain').isDisabled());
    await paneTab('%3').click();
    assert(await newCard.isVisible());
    assert.equal(await newCard.locator('textarea').inputValue(), '');
    assert(await newCard.locator('.explain').isDisabled());
    await newCard.locator('textarea').fill('New agent message');
    await newCard.locator('form button').click();
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Message sent');
    assert.deepEqual(sent[sent.length - 1], {pane: '%3', identity: 'restarted:%3', text: 'New agent message', append: true});
    await page.locator('#agents [data-key="%3:first:%3"]').click();
    await oldCard.locator('.copy').click();
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    await oldCard.locator('.discard').click();
    assert.equal(await oldCard.count(), 0);
    assert(await newCard.isVisible());
    empty = true;
    await page.waitForFunction(() => !document.querySelector('#empty').hidden);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('browser: PASS (sessions, role order, manager-only unread, focus, full width, viewport, resize, ANSI colors, waiting input text, hint exclusion, menu priority, selection, same-pane sends, digit and letter menu shortcuts, Tab hints, key deduplication, keyboard send, append sends, empty Send menu guard, explicit menu Enter, empty Send presses Enter, drafts, pane ID reuse, scroll, reload, mobile)');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
