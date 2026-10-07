// Optional: NODE_PATH=<installed Playwright directory> node tests/test_web_browser.cjs <launch-url>
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
(async () => {
  const url = process.argv[2]; assert(url, 'Pass a running peon-code-web launch URL');
  const token = new URL(url).hash.slice(1);
  const browser = await chromium.launch({headless: true, chromiumSandbox: false});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 950}});
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
    let empty = false, blocked = true, explainDelay = 0;
    const revision = Object.fromEntries(roles.map(pane => [pane.id, 0]));
    const sent = [];
    const firstLine = "It's quoted 日本語 <script>alert('x')</script>.";
    const output = "\x1b[38;2;200;30;40mIt's \x1b[38;5;46;48;2;10;20;30mquoted 日本語 <script>alert('x')</script>.\x1b[0m\n" +
      '\x1b[91mBright\x1b[48;5;17mBlue bg\x1b[38:2::1:2:3mColon RGB\x1b[1;3;4mStyle\x1b[0mAfter\n' + 'A line of agent output.\n'.repeat(70);
    await page.route('**/api/panes', route => {
      assert.equal(route.request().headers()['x-peon-token'], token);
      return route.fulfill({json: {panes: empty ? [] : roles.map(pane => ({...pane, projectDir: '/work/' + pane.session + ' project', command: 'codex', output: output + revision[pane.id], defaultStyle: 'fg=#abcdef,bg=#123456'}))}});
    });
    await page.route('**/api/explain', async route => {
      sent.push(route.request().postDataJSON());
      if (explainDelay) await new Promise(resolve => setTimeout(resolve, explainDelay));
      return route.fulfill({status: blocked ? 409 : 200, json: blocked ? {error: 'target box busy'} : {message: 'Explained'}});
    });
    await page.route('**/api/send', async route => {
      sent.push(route.request().postDataJSON());
      await new Promise(resolve => setTimeout(resolve, 300));
      await route.fulfill({json: {message: 'Message sent'}});
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
    await paneTab('%5').focus(); revision['%5'] = 1; revision['%10'] = 1;
    await page.waitForSelector('#agents [data-key="%5:first:%5"].unread');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.key), '%5:first:%5');
    assert(await sessionTab('alpha').evaluate(el => el.classList.contains('unread')));
    assert(await sessionTab('zeta').evaluate(el => el.classList.contains('unread')));
    await page.locator('#right-click').uncheck(); await selectFirstLine();
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    const frozen = await card('%3').locator('.output').textContent(); revision['%3'] = 1;
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
    await card('%3').locator('textarea').fill('Original message'); await card('%3').locator('form button').click();
    await card('%3').locator('textarea').fill('New draft');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Message sent');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'New draft');
    await card('%3').locator('textarea').fill('Repeat'); await card('%3').locator('form button').click();
    await card('%3').locator('textarea').fill('Other'); await card('%3').locator('textarea').fill('Repeat');
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .feedback').textContent === 'Message sent');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'Repeat');
    await card('%3').locator('textarea').fill('New draft');
    await sessionTab('zeta').click(); assert(await card('%8').isVisible());
    assert.equal(await page.locator('#project-path').textContent(), 'Folder: /work/zeta project');
    assert(await paneTab('%10').evaluate(el => el.classList.contains('unread')));
    await paneTab('%10').click(); assert.equal(await sessionTab('zeta').evaluate(el => el.classList.contains('unread')), false);
    assert(await card('%10').locator('.output').evaluate(el => el.scrollTop > 0));
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
    assert.equal(await page.locator('footer a').count(), 3);
    await card('%3').locator('textarea').fill('Keep this draft');
    await selectFirstLine();
    empty = true;
    await page.waitForFunction(() => document.querySelector('.pane:not([hidden]) .state').textContent === 'Closed');
    assert.equal(await card('%3').locator('textarea').inputValue(), 'Keep this draft');
    assert(await card('%3').locator('.explain').isDisabled());
    assert(await card('%3').locator('form button').isDisabled());
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
    assert.deepEqual(sent[sent.length - 1], {pane: '%3', identity: 'restarted:%3', text: 'New agent message'});
    await page.locator('#agents [data-key="%3:first:%3"]').click();
    await oldCard.locator('.copy').click();
    assert.equal(await page.evaluate(() => getSelection().toString()), firstLine);
    await oldCard.locator('.discard').click();
    assert.equal(await oldCard.count(), 0);
    assert(await newCard.isVisible());
    empty = true;
    await page.waitForFunction(() => !document.querySelector('#empty').hidden);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('browser: PASS (sessions, role order, unread, focus, full width, ANSI colors, selection, same-pane sends, drafts, pane ID reuse, scroll, reload, mobile)');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
