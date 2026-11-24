// Runs inside music/video sites. Every second: report the player state (only once this tab has played
// something), and execute commands (play/pause, next, prev) sent back by the Desk-Buddy server.
(() => {
  const ID = Math.random().toString(36).slice(2);
  let lastPlay = 0;

  function mediaEl() {
    const els = Array.from(document.querySelectorAll('video, audio')).filter(e => e.currentSrc || e.src);
    return els.find(e => !e.paused) || els.sort((a, b) => b.currentTime - a.currentTime)[0] || null;
  }

  function state() {
    const m = mediaEl();
    if (!m) return null;
    if (!m.paused) lastPlay = Date.now();
    if (!lastPlay) return null; // this tab never played anything: stay quiet
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    let art = '';
    if (md && md.artwork && md.artwork.length) art = md.artwork[md.artwork.length - 1].src || '';
    if (!art && /youtube\.com$/.test(location.hostname)) {
      const v = new URLSearchParams(location.search).get('v');
      if (v) art = 'https://i.ytimg.com/vi/' + v + '/hqdefault.jpg';
    }
    return {
      id: ID,
      site: location.hostname,
      title: (md && md.title) || document.title,
      artist: (md && md.artist) || '',
      album: (md && md.album) || '',
      art: art,
      playing: !m.paused,
      pos: m.currentTime || 0,
      dur: isFinite(m.duration) ? m.duration : 0,
      lastPlay: lastPlay
    };
  }

  function click(selectors) {
    for (const s of selectors) {
      const b = document.querySelector(s);
      if (b && !b.disabled) { b.click(); return true; }
    }
    return false;
  }
  const NEXT = ['.ytp-next-button', 'ytmusic-player-bar .next-button', '[data-testid="control-button-skip-forward"]',
    '.skipControl__next', '.zm-player-controls .btn-next', 'button[title="Next"]', 'button[aria-label="Next"]'];
  const PREV = ['ytmusic-player-bar .previous-button', '[data-testid="control-button-skip-back"]',
    '.skipControl__previous', '.zm-player-controls .btn-pre', '.ytp-prev-button', 'button[title="Previous"]', 'button[aria-label="Previous"]'];

  function run(c) {
    const m = mediaEl();
    if (c === 'play') {
      if (!m) return;
      // prefer the site's own button (keeps its UI in sync), else the media element
      if (!click(['.ytp-play-button', 'ytmusic-player-bar #play-pause-button', '[data-testid="control-button-playpause"]', '.playControl'])) {
        if (m.paused) m.play(); else m.pause();
      }
    } else if (c === 'next') {
      if (!click(NEXT)) document.dispatchEvent(new KeyboardEvent('keydown', { key: 'N', shiftKey: true, bubbles: true }));
    } else if (c === 'prev') {
      if (!click(PREV) && m) m.currentTime = 0;
    }
  }

  function report() {
    const s = state();
    if (!s) return;
    try {
      chrome.runtime.sendMessage({ type: 'state', s: s }, r => {
        if (chrome.runtime.lastError || !r || !r.cmds) return;
        r.cmds.forEach(c => { run(c); setTimeout(report, 300); });
      });
    } catch (e) { /* extension reloaded: page needs a refresh */ }
  }
  // commands pushed by the background worker (arrive immediately even when this tab is hidden and throttled)
  chrome.runtime.onMessage.addListener(msg => {
    if (msg && msg.type === 'cmd') { run(msg.c); setTimeout(report, 300); }
  });
  setInterval(report, 1000);
})();
