// Page driver of tools/idb_probe.sh: per trial a fresh browser context (an empty IndexedDB), page 1 writes a burst of
// user:// files and is closed the moment it reports WROTE, page 2 of the same context counts what survived.
//   node check.mjs URL MODE TRIALS [N] [KB] [TAIL]     prints one "TRIAL mode i count" per trial and a "SUMMARY" line
// PW_CORE: a node_modules directory holding playwright-core; CHROMIUM: the browser binary.
import { createRequire } from 'node:module';
const require = createRequire((process.env.PW_CORE ?? '/home/christian/games-cursor/node_modules').replace(/\/?$/, '/') + 'x.js');
const pw = require('playwright-core');
const [url, mode, trials = '5', n = '400', kb = '24', tail = '0'] = process.argv.slice(2);
const browser = await pw.chromium.launch({ headless: true, executablePath: process.env.CHROMIUM ?? '/usr/bin/chromium',
  args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
function waitLine(page, prefix, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout waiting for ' + prefix)), ms);
    page.on('console', m => { const s = m.text(); if (s.startsWith(prefix)) { clearTimeout(t); resolve(s); } });
  });
}
const counts = [];
for (let i = 0; i < Number(trials); i++) {
  const ctx = await browser.newContext();
  const w = await ctx.newPage();
  // Which unload listeners the page registered (fd70f43 adds pagehide, beforeunload and visibilitychange once it syncs).
  await w.addInitScript(() => { window.__hooks = []; const add = window.addEventListener; window.addEventListener = function (t, ...a) { if (/pagehide|beforeunload|visibilitychange/.test(t)) window.__hooks.push(t); return add.call(this, t, ...a); }; });
  const wrote = waitLine(w, 'IDB WROTE', 120000);
  await w.goto(`${url}?phase=write&mode=${mode}&n=${n}&kb=${kb}&tail=${tail}`);
  await wrote;
  await new Promise(r => setTimeout(r, Number(process.env.WAIT_MS ?? 0)));
  console.log('HOOKS', mode, JSON.stringify(await w.evaluate(() => window.__hooks)));
  // CLOSE: close (default), beforeunload (close running the unload handlers) or nav (navigate away, then close).
  if (process.env.CLOSE === 'nav') { await w.goto('about:blank'); await w.close(); }
  else await w.close({ runBeforeUnload: process.env.CLOSE === 'beforeunload' });
  const r = await ctx.newPage();
  const got = waitLine(r, 'IDB COUNT', 120000);
  await r.goto(`${url}?phase=count`);
  const c = Number((await got).split(' ')[2]);
  counts.push(c);
  console.log('TRIAL', mode, i, c);
  await ctx.close();
}
const lost = counts.map(c => Number(n) + Number(tail) - c);
console.log('SUMMARY', mode, 'written', Number(n) + Number(tail), 'kept', JSON.stringify(counts), 'lost-mean', (lost.reduce((a, b) => a + b, 0) / lost.length).toFixed(1), 'lost-max', Math.max(...lost));
await browser.close();
