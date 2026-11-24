// Relays player state from content scripts to the Desk-Buddy server, and delivers commands to the right tab.
// config.js is created by server.ps1 when missing (holds the port).
try { importScripts('config.js'); } catch (e) {}
const PORT = (typeof DESKBUDDY_PORT !== 'undefined') ? DESKBUDDY_PORT : (typeof MINI_SCREEN_PORT !== 'undefined') ? MINI_SCREEN_PORT : 8080;   // MINI_SCREEN_PORT: config.js from before the rename
const BASE = 'http://127.0.0.1:' + PORT;

const tabOf = {};      // content-script id -> { tabId, seen }

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.type !== 'state') return;
  if (sender.tab) tabOf[msg.s.id] = { tabId: sender.tab.id, seen: Date.now() };
  fetch(BASE + '/api/ext-media?d=' + encodeURIComponent(JSON.stringify(msg.s)), { method: 'POST' })
    .then(r => r.json())
    .then(j => sendResponse(j))
    .catch(() => sendResponse({}));
  return true; // async sendResponse
});

// Hidden, paused tabs only run timers about once a minute, so they can't poll for commands themselves.
// The service worker polls instead and pushes commands into the tab with a message (delivered immediately).
function anyRecentTab() {
  const now = Date.now();
  for (const k in tabOf) { if (now - tabOf[k].seen < 10 * 60 * 1000) return true; delete tabOf[k]; }
  return false;
}
function pollCommands() {
  const next = () => {
    chrome.runtime.getPlatformInfo(() => {});   // calling an extension API keeps the service worker alive
    setTimeout(pollCommands, 1000);
  };
  if (!anyRecentTab()) { next(); return; }
  fetch(BASE + '/api/ext-cmd', { cache: 'no-store' })
    .then(r => r.json())
    .then(j => {
      (j.cmds || []).forEach(x => {
        const t = tabOf[x.id];
        if (t) chrome.tabs.sendMessage(t.tabId, { type: 'cmd', c: x.c }).catch(() => {});
      });
    })
    .catch(() => {})
    .finally(next);
}
pollCommands();
