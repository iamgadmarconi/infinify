// SPDX-License-Identifier: GPL-3.0-or-later
// The Electron case of tests/e2e/scoped-windows.sh: one window whose page is a single button, reporting to
// $SCOPE_DIR/status.json the subset of native/fixture/scope-fixture.m's report that Electron's main process can know.
// `visible` is false until the window is shown: the test starts Infinify only after it, so that the window is adopted as one already open.
// Run by a generic Electron binary the test is given in INFINIFY_E2E_ELECTRON; it posts nothing and never focuses itself.
const { app, BrowserWindow, ipcMain } = require('electron');
const fs = require('fs'), path = require('path');
const dir = process.env.SCOPE_DIR, title = process.env.SCOPE_TITLE || 'Scope Electron';
const seconds = Math.min(300, Number(process.env.SCOPE_SECONDS) || 60), parent = process.ppid, began = Date.now();
const counts = { web_down: 0, web_up: 0, web_click: 0, raf: 0 }, last = {}, front = {};
let win, active = false, activations = 0;
function report() {
  if (!win || win.isDestroyed()) return;
  const b = win.getBounds(), c = win.getContentBounds();
  const status = { pid: process.pid, window: Number(win.getMediaSourceId().split(':')[1]), title: win.getTitle(),
    bounds: [b.x, b.y, b.width, b.height], controls: { web: [c.x - b.x, c.y - b.y, c.width, c.height] }, counts, last, front,
    visible: win.isVisible(), key_window: win.isFocused(), app_active: active, activations };
  // Whole or not at all, as the native fixture writes it.
  const file = path.join(dir, 'status.json');
  fs.writeFileSync(file + '.tmp', JSON.stringify(status)); fs.renameSync(file + '.tmp', file);
}
app.on('did-become-active', () => { active = true; activations++; report(); });
app.on('did-resign-active', () => { active = false; report(); });
ipcMain.on('s', (event, m) => {
  if (m.t === 'raf') { counts.raf = m.n; return; }
  const key = 'web_' + m.t; if (!(key in counts)) return;
  const b = win.getBounds(), c = win.getContentBounds();
  // Window-local, from the window's top left corner: where a forwarded event is addressed.
  counts[key]++; last[key] = [m.x + c.x - b.x, m.y + c.y - b.y];
  // As the event was handled: a later reading may find the foreground gone elsewhere.
  front[key] = { app_active: active, key_window: win.isFocused() }; report();
});
app.whenReady().then(() => {
  win = new BrowserWindow({ width: 420, height: 470, show: false, title, webPreferences: { nodeIntegration: true, contextIsolation: false } });
  // The title the test gave is the one it looks for: the page's own does not replace it.
  win.on('page-title-updated', event => event.preventDefault());
  // $SCOPE_DY points down from the centre of the screen: the test keeps a strip of this window clear of its other fixtures,
  // because Chromium stops a page's animation frames once an opaque window hides its window whole.
  const at = win.getBounds(); win.setPosition(at.x, at.y + Math.round(Number(process.env.SCOPE_DY) || 0));
  win.loadFile(path.join(__dirname, 'page.html'));
  // Shown without being made the active application: that is for the click under test to bring about.
  win.once('ready-to-show', () => { win.showInactive(); report(); });
  setInterval(() => {
    if (process.ppid !== parent || Date.now() - began > seconds * 1000) app.exit(0);
    // $SCOPE_DIR/above holding a window number puts this window directly over that one (the test names a native fixture
    // that lies directly under the canvas), without focusing it.
    const above = path.join(dir, 'above');
    if (fs.existsSync(above)) { const n = Number(fs.readFileSync(above, 'utf8')); fs.unlinkSync(above); if (n > 0) try { win.moveAbove(`window:${n}:0`); } catch (error) { console.error(String(error)); } }
    report();
  }, 50);
});
app.on('window-all-closed', () => app.exit(0));
