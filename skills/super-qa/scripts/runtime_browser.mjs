#!/usr/bin/env node
// Project-owned Playwright and scenario; no dependencies installed by Super Board.
// Two modes:
//   node runtime_browser.mjs <scenario.mjs>       timed scenario (runtime-verification.md)
//   node runtime_browser.mjs --shot --url <url> --out <png> [--viewport desktop|phone|WxH]
//        [--screen screen-<name>] [--click <selector>] [--full-page]
//                                                one screenshot for the screen match (screen-match.md)
import {createRequire} from 'node:module';
import {dirname, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {writeFile, mkdir} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';

const VIEWPORTS = {desktop: {width: 1280, height: 800}, phone: {width: 390, height: 844}};
const SCREEN = /^screen-[A-Za-z0-9_-]+$/;

function chromium() {
  const project = process.env.SB_RUNTIME_PROJECT;
  if (!project) throw new Error('SB_RUNTIME_PROJECT must point to the owning app with Playwright installed');
  const require = createRequire(resolve(project, 'package.json'));
  return require('playwright').chromium;
}

function parseShot(argv) {
  const opts = {viewport: 'desktop', fullPage: false};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--full-page') { opts.fullPage = true; continue; }
    if (!['--url', '--out', '--viewport', '--screen', '--click'].includes(flag)) throw new Error('unknown flag: ' + flag);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(flag + ' needs a value');
    opts[flag.slice(2)] = value;
    i++;
  }
  if (!opts.url) throw new Error('--url is required');
  if (!opts.out || !opts.out.endsWith('.png')) throw new Error('--out must name a .png file');
  let url;
  try { url = new URL(opts.url); } catch { throw new Error('--url is not a URL: ' + opts.url); }
  if (!['http:', 'https:', 'file:'].includes(url.protocol)) throw new Error('--url must be http, https or file');
  if (url.username || url.password) throw new Error('--url must not carry credentials');
  if (opts.screen !== undefined && !SCREEN.test(opts.screen)) throw new Error('--screen must look like screen-<name>');
  const wh = /^(\d{3,4})x(\d{3,4})$/.exec(opts.viewport);
  opts.size = VIEWPORTS[opts.viewport] || (wh && {width: Number(wh[1]), height: Number(wh[2])});
  if (!opts.size) throw new Error('--viewport must be desktop, phone or WxH');
  return opts;
}

// Make `#screen-<name>` visible: the URL hash first, then a control that targets it.
// Returns how it opened, or null. It never guesses past these: a miss is a clear failure.
async function openScreen(page, screen, click) {
  const target = page.locator('#' + screen).first();
  const shown = async () => (await target.count()) > 0 && await target.isVisible();
  if (!click && await shown()) return 'on load';
  const name = screen.slice('screen-'.length);
  const tries = click ? [click] : [
    `a[href$="#${screen}"]`, `[data-screen="${screen}"]`, `[data-screen="${name}"]`,
    `[data-tab="${screen}"]`, `[data-tab="${name}"]`, `[aria-controls="${screen}"]`,
  ];
  for (const selector of tries) {
    const control = page.locator(selector).first();
    if ((await control.count()) === 0 || !(await control.isVisible())) continue;
    await control.click();
    await page.waitForTimeout(300);
    if (await shown()) return 'click ' + selector;
  }
  if (click) return null;
  const words = name.replace(/[-_]+/g, ' ');
  const tab = page.getByRole('tab', {name: new RegExp('^\\s*' + words + '\\s*$', 'i')}).first();
  if ((await tab.count()) > 0) {
    await tab.click();
    await page.waitForTimeout(300);
    if (await shown()) return 'tab "' + words + '"';
  }
  return null;
}

async function shot(argv) {
  let browser;
  let opts = {};
  try {
    opts = parseShot(argv);
    const launcher = chromium();
    browser = await launcher.launch({headless: true});
    const context = await browser.newContext({viewport: opts.size, locale: 'en-US', timezoneId: 'UTC', reducedMotion: 'reduce'});
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.goto(opts.url, {waitUntil: 'networkidle'});
    await page.waitForTimeout(300);
    let opened = 'page';
    if (opts.screen) {
      opened = await openScreen(page, opts.screen, opts.click);
      if (!opened) throw new Error(`could not open #${opts.screen}: no visible element with that id after the URL hash, `
        + (opts.click ? `or after clicking ${opts.click}` : 'a link, data-screen, data-tab, aria-controls or a tab named after it'));
    }
    const root = opts.screen ? '#' + opts.screen : 'body';
    const classes = await page.$eval(root, el => [...new Set([el, ...el.querySelectorAll('*')]
      .flatMap(n => [...n.classList]))].sort());
    await mkdir(dirname(resolve(opts.out)), {recursive: true});
    await page.screenshot({path: resolve(opts.out), fullPage: opts.fullPage, animations: 'disabled'});
    console.log(JSON.stringify({ok: true, url: opts.url, out: opts.out, screen: opts.screen || null, opened,
      viewport: `${opts.size.width}x${opts.size.height}`, full_page: opts.fullPage, classes, page_errors: errors}));
  } catch (error) {
    console.log(JSON.stringify({ok: false, url: opts.url || null, screen: opts.screen || null, error: String(error)}));
    process.exitCode = 2;
  } finally {
    await browser?.close();
  }
}

async function measure(scenarioArg) {
  let browser;
  try {
    const launcher = chromium();
    const scenarioPath = resolve(scenarioArg);
    const {run} = await import(pathToFileURL(scenarioPath).href);
    if (typeof run !== 'function') throw new Error('scenario module must export run(page)');
    browser = await launcher.launch({headless: true});
    const context = await browser.newContext({viewport: {width: 1280, height: 720}, locale: 'en-US', timezoneId: 'UTC'});
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    page.on('console', msg => {if (msg.type() === 'error') errors.push(msg.text());});
    const cdp = await context.newCDPSession(page);
    await cdp.send('Performance.enable');
    await page.goto(process.env.SB_RUNTIME_URL, {waitUntil: 'networkidle'});
    await cdp.send('HeapProfiler.collectGarbage');
    const before = await cdp.send('Performance.getMetrics');
    // Trace/screenshot/CDP sampling never run inside the timed action.
    const started = performance.now();
    const result = await run(page);
    const duration = performance.now() - started;
    await cdp.send('HeapProfiler.collectGarbage');
    const after = await cdp.send('Performance.getMetrics');
    const memory = after.metrics.find(row => row.name === 'JSHeapUsedSize')?.value;
    const beforeMemory = before.metrics.find(row => row.name === 'JSHeapUsedSize')?.value;
    const dir = process.env.SB_RUNTIME_ARTIFACT_DIR;
    await mkdir(dir, {recursive: true});
    await writeFile(resolve(dir, 'cdp-metrics.json'), JSON.stringify({before, after, errors}, null, 2));
    await page.screenshot({path: resolve(dir, 'result.png')});
    console.log(JSON.stringify({correct: result?.correct === true && errors.length === 0,
      duration_ms: duration, memory_bytes: memory, memory_before_bytes: beforeMemory,
      environment: {browser: 'chromium', version: browser.version(), headless: true,
        viewport: '1280x720', locale: 'en-US', timezone: 'UTC', timing_scope: 'automation action, excludes launch/navigation/tracing'},
      detail: result, page_errors: errors.length}));
  } catch (error) {
    console.log(JSON.stringify({correct: false, error: String(error)}));
    process.exitCode = 2;
  } finally {
    await browser?.close();
  }
}

if (process.argv[2] === '--shot') await shot(process.argv.slice(3));
else await measure(process.argv[2] ?? '');
