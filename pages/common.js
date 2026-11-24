/* Desk-Buddy shared helpers - plain ES5 so it runs on old Android browsers */
var MS = (function () {
  'use strict';
  var DW = 640, DH = 360;
  var dpr = window.devicePixelRatio || 1;
  var unit = 10, sx = 0, sy = 0, app = null, hooks = [];
  var allowRotate = !/[?&]rotate=0/.test(location.search);
  var UA = navigator.userAgent || '';

  // "lite" mode for old/slow devices (Galaxy S2 HD = Android 4.x stock browser):
  // no never-ending CSS animations, no CSS transform on #app (canvas "ghost" bug), no overflow:hidden
  // on cards, fewer repaints. Short transitions stay on. Force with ?lite=1 / ?lite=0
  var lite = /[?&]lite=1/.test(location.search) ? true : /[?&]lite=0/.test(location.search) ? false :
    (/Android [1-4]\./.test(UA) || !(window.requestAnimationFrame || window.webkitRequestAnimationFrame));
  if (lite) document.documentElement.className += ' lite';

  // Old Android browsers: hide the address bar by scrolling 1px (page must be taller than the viewport)
  function hideBar() {
    if (!/Android/.test(UA)) return;
    var b = document.body, h = document.documentElement;
    h.style.overflow = b.style.overflow = 'visible';
    b.style.height = (window.innerHeight + 200) + 'px';
    window.scrollTo(0, 1);
    setTimeout(function () {
      b.style.height = (window.innerHeight + 1) + 'px';
      window.scrollTo(0, 1);
    }, 120);
  }
  if (/Android/.test(UA)) {
    window.addEventListener('load', function () { setTimeout(hideBar, 50); }, false);
    window.addEventListener('orientationchange', function () { setTimeout(hideBar, 400); }, false);
  }

  function $(id) { return document.getElementById(id); }
  var cache = {};
  function html(id, v) { if (cache[id] === v) return; cache[id] = v; var el = $(id); if (el) el.innerHTML = v; }
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function hexA(hex, a) {
    var n = parseInt(hex.slice(1), 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
  }
  // fmt(1234567.8, 1) -> "1.234.567,8" (VN);  fmt(x, 2, ',', '.') -> US style
  function fmt(n, dec, sep, point) {
    if (n == null || isNaN(n)) return '–';
    var p = Math.abs(n).toFixed(dec || 0).split('.');
    var i = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, sep || '.');
    return (n < 0 ? '-' : '') + i + (p[1] ? (point || ',') + p[1] : '');
  }

  // ------------------------------------------------------------ layout / scaling
  function sizeCanvases() {
    var cs = document.getElementsByTagName('canvas');
    for (var i = 0; i < cs.length; i++) {
      var c = cs[i], dw = c.getAttribute('data-w');
      if (!dw) continue;
      var w = parseFloat(dw) * unit, h = parseFloat(c.getAttribute('data-h')) * unit;
      c.style.width = w + 'px'; c.style.height = h + 'px';
      c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
    }
  }
  function layout() {
    var W = window.innerWidth, H = window.innerHeight;
    var rot = allowRotate && H > W * 1.15;
    var aw = rot ? H : W, ah = rot ? W : H;
    var s = Math.min(aw / DW, ah / DH);
    unit = s * 10;
    document.documentElement.style.fontSize = unit + 'px';
    var w = DW * s, h = DH * s, tf;
    if (lite && !rot) {
      // no CSS transform in lite mode: old Android browsers leave "ghost" copies of canvases inside transformed parents
      app.style.webkitTransform = app.style.transform = 'none';
      app.style.left = Math.round((W - w) / 2 + sx) + 'px';
      app.style.top = Math.round((H - h) / 2 + sy) + 'px';
    } else {
      app.style.left = app.style.top = '0';
      if (rot) tf = 'translate(' + Math.round((W + h) / 2 + sy) + 'px,' + Math.round((H - w) / 2 + sx) + 'px) rotate(90deg)';
      else tf = 'translate(' + Math.round((W - w) / 2 + sx) + 'px,' + Math.round((H - h) / 2 + sy) + 'px)';
      app.style.webkitTransform = tf; app.style.transform = tf;
    }
    sizeCanvases();
    for (var i = 0; i < hooks.length; i++) hooks[i]();
  }
  function onLayout(f) { hooks.push(f); }
  function ctx2d(c) {
    if (typeof c === 'string') c = $(c);
    // re-assigning width wipes the bitmap; old Android browsers don't fully clear with clearRect
    // when the canvas sits inside a CSS-transformed element, leaving ghost/overlapping drawings
    c.width = c.width;
    var x = c.getContext('2d'), w = c.width / dpr, h = c.height / dpr;
    x.setTransform(dpr, 0, 0, dpr, 0, 0); x.clearRect(0, 0, w, h);
    return { c: x, w: w, h: h };
  }
  function font(px, weight) { return (weight || 400) + ' ' + Math.round(px * 10) / 10 + 'px Roboto,"Segoe UI",Arial,sans-serif'; }

  // ------------------------------------------------------------ polling
  function poll(url, every, ok, bad) {
    var lastOk = 0;
    function go() {
      var done = false, x = new XMLHttpRequest();
      var to = setTimeout(function () { if (!done) x.abort(); }, 8000);
      x.onreadystatechange = function () {
        if (x.readyState !== 4 || done) return;
        done = true; clearTimeout(to);
        var d = null;
        if (x.status === 200) { try { d = JSON.parse(x.responseText); } catch (e) {} }
        if (d) { lastOk = +new Date(); try { ok(d); } catch (e2) { if (window.console) console.log(e2); } }
        else if (bad && +new Date() - lastOk > Math.max(6000, every * 2.5)) bad();
        setTimeout(go, every);
      };
      x.open('GET', url + (url.indexOf('?') < 0 ? '?' : '&') + '_=' + (+new Date()), true);
      x.send(null);
    }
    go();
  }
  function live(ok, msg) {
    var l = $('live');
    if (l) l.className = 'dot ' + (ok ? 'on' : 'bad');
    if (app) app.className = ok ? '' : 'off';
    if (!ok && $('hsub')) { $('hsub').innerHTML = msg || 'Mất kết nối tới máy chủ – đang thử lại…'; cache.hsub = null; $('hsub').className = 'hsub err'; }
    else if (ok && $('hsub')) $('hsub').className = 'hsub';
  }

  // ------------------------------------------------------------ time (server clock)
  var off = 0, tz = null;
  function setServerTime(t, tzMin) { if (t) { off = t - (+new Date()); tz = tzMin; } }
  function now() {
    var d;
    if (tz === null) {
      d = new Date();
      return { h: d.getHours(), m: d.getMinutes(), s: d.getSeconds(), ms: d.getMilliseconds(), w: d.getDay(), D: d.getDate(), M: d.getMonth() + 1, Y: d.getFullYear() };
    }
    d = new Date(+new Date() + off + tz * 60000);
    return { h: d.getUTCHours(), m: d.getUTCMinutes(), s: d.getUTCSeconds(), ms: d.getUTCMilliseconds(), w: d.getUTCDay(), D: d.getUTCDate(), M: d.getUTCMonth() + 1, Y: d.getUTCFullYear() };
  }
  var DOW = ['CHỦ NHẬT', 'THỨ HAI', 'THỨ BA', 'THỨ TƯ', 'THỨ NĂM', 'THỨ SÁU', 'THỨ BẢY'];
  var DOWS = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
  function clockTick() {
    var n = now();
    html('time', pad(n.h) + ':' + pad(n.m) + '<span id="sec">' + pad(n.s) + '</span>');
    html('dow', DOW[n.w]);
    html('dmy', pad(n.D) + '.' + pad(n.M) + '.' + n.Y);
  }
  // "HH:MM" from an ISO local time string "2026-11-22T21:00"
  function hhmm(iso) { return iso ? iso.substr(11, 5) : ''; }

  // ------------------------------------------------------------ lunar calendar (Ho Ngoc Duc's algorithm, UTC+7)
  var INT = Math.floor, TZ = 7;
  function jdFromDate(dd, mm, yy) {
    var a = INT((14 - mm) / 12), y = yy + 4800 - a, m = mm + 12 * a - 3;
    var jd = dd + INT((153 * m + 2) / 5) + 365 * y + INT(y / 4) - INT(y / 100) + INT(y / 400) - 32045;
    if (jd < 2299161) jd = dd + INT((153 * m + 2) / 5) + 365 * y + INT(y / 4) - 32083;
    return jd;
  }
  function jdToDate(jd) {
    var a, b, c;
    if (jd > 2299160) { a = jd + 32044; b = INT((4 * a + 3) / 146097); c = a - INT((b * 146097) / 4); }
    else { b = 0; c = jd + 32082; }
    var d = INT((4 * c + 3) / 1461), e = c - INT((1461 * d) / 4), m = INT((5 * e + 2) / 153);
    return [e - INT((153 * m + 2) / 5) + 1, m + 3 - 12 * INT(m / 10), b * 100 + d - 4800 + INT(m / 10)];
  }
  function newMoon(k) {
    var T = k / 1236.85, T2 = T * T, T3 = T2 * T, dr = Math.PI / 180;
    var Jd1 = 2415020.75933 + 29.53058868 * k + 0.0001178 * T2 - 0.000000155 * T3;
    Jd1 = Jd1 + 0.00033 * Math.sin((166.56 + 132.87 * T - 0.009173 * T2) * dr);
    var M = 359.2242 + 29.10535608 * k - 0.0000333 * T2 - 0.00000347 * T3;
    var Mpr = 306.0253 + 385.81691806 * k + 0.0107306 * T2 + 0.00001236 * T3;
    var F = 21.2964 + 390.67050646 * k - 0.0016528 * T2 - 0.00000239 * T3;
    var C1 = (0.1734 - 0.000393 * T) * Math.sin(M * dr) + 0.0021 * Math.sin(2 * dr * M);
    C1 = C1 - 0.4068 * Math.sin(Mpr * dr) + 0.0161 * Math.sin(dr * 2 * Mpr);
    C1 = C1 - 0.0004 * Math.sin(dr * 3 * Mpr);
    C1 = C1 + 0.0104 * Math.sin(dr * 2 * F) - 0.0051 * Math.sin(dr * (M + Mpr));
    C1 = C1 - 0.0074 * Math.sin(dr * (M - Mpr)) + 0.0004 * Math.sin(dr * (2 * F + M));
    C1 = C1 - 0.0004 * Math.sin(dr * (2 * F - M)) - 0.0006 * Math.sin(dr * (2 * F + Mpr));
    C1 = C1 + 0.0010 * Math.sin(dr * (2 * F - Mpr)) + 0.0005 * Math.sin(dr * (2 * Mpr + M));
    var deltat = T < -11
      ? 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3
      : -0.000278 + 0.000265 * T + 0.000262 * T2;
    return Jd1 + C1 - deltat;
  }
  function sunLongitude(jdn) {
    var T = (jdn - 2451545.0) / 36525, T2 = T * T, dr = Math.PI / 180;
    var M = 357.52910 + 35999.05030 * T - 0.0001559 * T2 - 0.00000048 * T * T2;
    var L0 = 280.46645 + 36000.76983 * T + 0.0003032 * T2;
    var DL = (1.914600 - 0.004817 * T - 0.000014 * T2) * Math.sin(dr * M);
    DL = DL + (0.019993 - 0.000101 * T) * Math.sin(dr * 2 * M) + 0.000290 * Math.sin(dr * 3 * M);
    var L = (L0 + DL) * dr;
    return L - Math.PI * 2 * INT(L / (Math.PI * 2));
  }
  function getSunLong(dayNumber) { return INT(sunLongitude(dayNumber - 0.5 - TZ / 24) / Math.PI * 6); }
  function getNewMoonDay(k) { return INT(newMoon(k) + 0.5 + TZ / 24); }
  function getLunarMonth11(yy) {
    var off = jdFromDate(31, 12, yy) - 2415021, k = INT(off / 29.530588853);
    var nm = getNewMoonDay(k);
    if (getSunLong(nm) >= 9) nm = getNewMoonDay(k - 1);
    return nm;
  }
  function getLeapMonthOffset(a11) {
    var k = INT((a11 - 2415021.076998695) / 29.530588853 + 0.5), last, i = 1;
    var arc = getSunLong(getNewMoonDay(k + i));
    do { last = arc; i++; arc = getSunLong(getNewMoonDay(k + i)); } while (arc !== last && i < 14);
    return i - 1;
  }
  function solar2lunar(dd, mm, yy) {
    var dayNumber = jdFromDate(dd, mm, yy);
    var k = INT((dayNumber - 2415021.076998695) / 29.530588853);
    var monthStart = getNewMoonDay(k + 1);
    if (monthStart > dayNumber) monthStart = getNewMoonDay(k);
    var a11 = getLunarMonth11(yy), b11 = a11, lunarYear;
    if (a11 >= monthStart) { lunarYear = yy; a11 = getLunarMonth11(yy - 1); }
    else { lunarYear = yy + 1; b11 = getLunarMonth11(yy + 1); }
    var lunarDay = dayNumber - monthStart + 1, diff = INT((monthStart - a11) / 29), leap = 0, lunarMonth = diff + 11;
    if (b11 - a11 > 365) {
      var leapDiff = getLeapMonthOffset(a11);
      if (diff >= leapDiff) { lunarMonth = diff + 10; if (diff === leapDiff) leap = 1; }
    }
    if (lunarMonth > 12) lunarMonth -= 12;
    if (lunarMonth >= 11 && diff < 4) lunarYear -= 1;
    return { d: lunarDay, m: lunarMonth, y: lunarYear, leap: leap, jd: dayNumber };
  }
  function lunar2solar(ld, lm, ly, leap) {
    var a11, b11;
    if (lm < 11) { a11 = getLunarMonth11(ly - 1); b11 = getLunarMonth11(ly); }
    else { a11 = getLunarMonth11(ly); b11 = getLunarMonth11(ly + 1); }
    var k = INT(0.5 + (a11 - 2415021.076998695) / 29.530588853), off = lm - 11;
    if (off < 0) off += 12;
    if (b11 - a11 > 365) {
      var leapOff = getLeapMonthOffset(a11), leapMonth = leapOff - 2;
      if (leapMonth < 0) leapMonth += 12;
      if (leap && lm !== leapMonth) return null;
      else if (leap || off >= leapOff) off += 1;
    }
    return jdToDate(getNewMoonDay(k + off) + ld - 1); // [d, m, y]
  }
  var CAN = ['Giáp', 'Ất', 'Bính', 'Đinh', 'Mậu', 'Kỷ', 'Canh', 'Tân', 'Nhâm', 'Quý'];
  var CHI = ['Tý', 'Sửu', 'Dần', 'Mão', 'Thìn', 'Tỵ', 'Ngọ', 'Mùi', 'Thân', 'Dậu', 'Tuất', 'Hợi'];
  function ccYear(y) { return CAN[(y + 6) % 10] + ' ' + CHI[(y + 8) % 12]; }
  function ccMonth(m, y) { return CAN[(y * 12 + m + 3) % 10] + ' ' + CHI[(m + 1) % 12]; }
  function ccDay(jd) { return CAN[(jd + 9) % 10] + ' ' + CHI[(jd + 1) % 12]; }
  function lunarMonthName(m) { return m === 1 ? 'Giêng' : m === 12 ? 'Chạp' : String(m); }
  function lunarDayName(d) { return d <= 10 ? 'Mùng ' + d : d === 15 ? 'Rằm' : 'Ngày ' + d; }

  // ------------------------------------------------------------ weather helpers
  // returns [text, kind]  kind: clear partly cloudy fog drizzle rain storm snow
  function wx(code) {
    var c = +code;
    if (c === 0) return ['Trời quang', 'clear'];
    if (c === 1) return ['Ít mây', 'partly'];
    if (c === 2) return ['Có mây', 'partly'];
    if (c === 3) return ['Nhiều mây', 'cloudy'];
    if (c === 45 || c === 48) return ['Sương mù', 'fog'];
    if (c >= 51 && c <= 57) return ['Mưa phùn', 'drizzle'];
    if (c === 61) return ['Mưa nhỏ', 'rain'];
    if (c === 63) return ['Mưa vừa', 'rain'];
    if (c === 65) return ['Mưa to', 'rain'];
    if (c === 66 || c === 67) return ['Mưa lạnh', 'rain'];
    if (c >= 71 && c <= 77) return ['Tuyết', 'snow'];
    if (c === 80) return ['Mưa rào nhẹ', 'rain'];
    if (c === 81) return ['Mưa rào', 'rain'];
    if (c === 82) return ['Mưa rào rất to', 'rain'];
    if (c === 85 || c === 86) return ['Mưa tuyết', 'snow'];
    if (c === 95) return ['Dông', 'storm'];
    if (c >= 96) return ['Dông, mưa đá', 'storm'];
    return ['–', 'cloudy'];
  }
  var CARD = '#0c1016';
  function circ(c, x, y, r, col) { c.fillStyle = col; c.beginPath(); c.arc(x, y, r, 0, Math.PI * 2, false); c.fill(); }
  function sun(c, x, y, r) {
    c.strokeStyle = '#fbbf24'; c.lineWidth = Math.max(1, r * 0.2); c.lineCap = 'round';
    for (var i = 0; i < 8; i++) {
      var a = i * Math.PI / 4;
      c.beginPath(); c.moveTo(x + Math.cos(a) * r * 1.4, y + Math.sin(a) * r * 1.4);
      c.lineTo(x + Math.cos(a) * r * 1.8, y + Math.sin(a) * r * 1.8); c.stroke();
    }
    circ(c, x, y, r, '#fbbf24');
  }
  // crescent drawn on a scratch canvas with a transparent "bite", so it works on any background (photos too)
  function moon(c, x, y, r) {
    var pad = 2, size = Math.ceil((r + pad) * 2), oc = document.createElement('canvas');
    oc.width = oc.height = Math.ceil(size * dpr);
    var o = oc.getContext('2d');
    o.scale(dpr, dpr);
    circ(o, size / 2, size / 2, r, '#e2e8f0');
    o.globalCompositeOperation = 'destination-out';
    circ(o, size / 2 + r * 0.5, size / 2 - r * 0.35, r * 0.82, '#000');
    c.drawImage(oc, x - size / 2, y - size / 2, size, size);
  }
  function cloud(c, x, y, w, col) {
    circ(c, x - w * 0.25, y + w * 0.05, w * 0.17, col);
    circ(c, x - w * 0.02, y - w * 0.08, w * 0.24, col);
    circ(c, x + w * 0.24, y + w * 0.04, w * 0.18, col);
    c.fillStyle = col; c.fillRect(x - w * 0.25, y + w * 0.04, w * 0.49, w * 0.18);
  }
  function drawWx(c, x, y, s, code, day, bg) {
    var k = wx(code)[1], i;
    c.save();
    if (k === 'clear') { if (day) sun(c, x, y, s * 0.2); else moon(c, x, y, s * 0.27, bg); }
    else if (k === 'partly') {
      if (day) sun(c, x + s * 0.13, y - s * 0.12, s * 0.15); else moon(c, x + s * 0.14, y - s * 0.12, s * 0.19, bg);
      cloud(c, x - s * 0.05, y + s * 0.07, s * 0.72, '#cbd5e1');
    } else if (k === 'cloudy') {
      cloud(c, x + s * 0.13, y - s * 0.1, s * 0.58, '#64748b');
      cloud(c, x - s * 0.06, y + s * 0.06, s * 0.74, '#cbd5e1');
    } else if (k === 'fog') {
      cloud(c, x, y - s * 0.1, s * 0.74, '#94a3b8');
      c.strokeStyle = '#cbd5e1'; c.lineWidth = Math.max(1, s * 0.05); c.lineCap = 'round';
      for (i = 0; i < 2; i++) { c.beginPath(); c.moveTo(x - s * 0.3 + i * s * 0.08, y + s * 0.2 + i * s * 0.11); c.lineTo(x + s * 0.3 - i * s * 0.04, y + s * 0.2 + i * s * 0.11); c.stroke(); }
    } else {
      var dark = k === 'storm' ? '#64748b' : '#94a3b8';
      cloud(c, x, y - s * 0.12, s * 0.78, dark);
      c.lineCap = 'round';
      if (k === 'snow') {
        for (i = 0; i < 3; i++) circ(c, x - s * 0.2 + i * s * 0.2, y + s * 0.24 + (i % 2) * s * 0.08, s * 0.045, '#f1f5f9');
      } else if (k === 'storm') {
        c.fillStyle = '#facc15'; c.beginPath();
        c.moveTo(x + s * 0.02, y + s * 0.06); c.lineTo(x - s * 0.12, y + s * 0.28); c.lineTo(x, y + s * 0.28);
        c.lineTo(x - s * 0.06, y + s * 0.45); c.lineTo(x + s * 0.14, y + s * 0.2); c.lineTo(x + s * 0.02, y + s * 0.2);
        c.lineTo(x + s * 0.1, y + s * 0.06); c.closePath(); c.fill();
      } else {
        c.strokeStyle = '#38bdf8'; c.lineWidth = Math.max(1, s * 0.055);
        var n = k === 'drizzle' ? 3 : 3, len = k === 'drizzle' ? s * 0.07 : s * 0.15;
        for (i = 0; i < n; i++) {
          var dx = x - s * 0.18 + i * s * 0.18, dy = y + s * 0.18 + (i % 2) * s * 0.06;
          c.beginPath(); c.moveTo(dx, dy); c.lineTo(dx - len * 0.35, dy + len); c.stroke();
        }
      }
    }
    c.restore();
  }
  var AQI = [[50, 'Tốt', '#34d399'], [100, 'Trung bình', '#facc15'], [150, 'Kém', '#fb923c'], [200, 'Xấu', '#f87171'], [300, 'Rất xấu', '#c084fc'], [9999, 'Nguy hại', '#be123c']];
  function aqiInfo(v) { for (var i = 0; i < AQI.length; i++) if (v <= AQI[i][0]) return AQI[i]; return AQI[5]; }
  var DIRS = ['Bắc', 'Đông Bắc', 'Đông', 'Đông Nam', 'Nam', 'Tây Nam', 'Tây', 'Tây Bắc'];
  var DIRS_S = ['B', 'ĐB', 'Đ', 'ĐN', 'N', 'TN', 'T', 'TB'];
  function windDir(deg, short) { var i = Math.round(deg / 45) % 8; return (short ? DIRS_S : DIRS)[i]; }

  // ------------------------------------------------------------ small drawing helpers
  function ring(cv, v, c1, c2, opts) {
    opts = opts || {};
    var o = ctx2d(cv), c = o.c, w = o.w, h = o.h;
    var lw = w * (opts.lw || 0.09), r = Math.min(w, h) / 2 - lw / 2 - 2, cx = w / 2, cy = h / 2;
    var a0 = Math.PI * 0.75, span = Math.PI * 1.5;
    v = Math.max(0, Math.min(100, v || 0));
    c.lineCap = 'round'; c.lineWidth = lw;
    c.strokeStyle = '#161d28'; c.beginPath(); c.arc(cx, cy, r, a0, a0 + span, false); c.stroke();
    if (v > 0.3) {
      var g = c.createLinearGradient(0, h, w, 0);
      g.addColorStop(0, v >= 90 ? '#dc2626' : c1); g.addColorStop(1, v >= 90 ? '#f87171' : c2);
      c.strokeStyle = g; c.beginPath(); c.arc(cx, cy, r, a0, a0 + span * v / 100, false); c.stroke();
    }
  }
  // clip to a shape with rounded bottom corners, so a chart sitting at the bottom of a card
  // follows the card's border-radius without needing overflow:hidden on the card
  function clipBottom(c, w, h, r) {
    c.beginPath(); c.moveTo(0, 0); c.lineTo(w, 0); c.lineTo(w, h - r);
    c.arcTo(w, h, w - r, h, r); c.lineTo(r, h); c.arcTo(0, h, 0, h - r, r); c.closePath();
    c.clip();
  }
  function sparkline(cv, data, color, opts) {
    opts = opts || {};
    var o = ctx2d(cv), c = o.c, w = o.w, h = o.h;
    if (!data || data.length < 2) return;
    var mn = Infinity, mx = -Infinity, i;
    for (i = 0; i < data.length; i++) { mn = Math.min(mn, data[i]); mx = Math.max(mx, data[i]); }
    if (opts.zero) mn = 0;
    if (mx === mn) { mx += 1; mn -= 1; }
    if (opts.round) clipBottom(c, w, h, unit * 1.2 - 1);
    var pt = opts.padTop || 4, pb = opts.padBottom || 2;
    function X(i) { return i / (data.length - 1) * w; }
    function Y(v) { return pt + (1 - (v - mn) / (mx - mn)) * (h - pt - pb); }
    c.beginPath();
    for (i = 0; i < data.length; i++) { if (i) c.lineTo(X(i), Y(data[i])); else c.moveTo(X(i), Y(data[i])); }
    c.lineTo(w, h); c.lineTo(0, h); c.closePath();
    var g = c.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, hexA(color, 0.3)); g.addColorStop(1, hexA(color, 0));
    c.fillStyle = g; c.fill();
    c.beginPath();
    for (i = 0; i < data.length; i++) { if (i) c.lineTo(X(i), Y(data[i])); else c.moveTo(X(i), Y(data[i])); }
    c.strokeStyle = color; c.lineWidth = opts.lw || 1.6; c.lineJoin = 'round'; c.stroke();
    if (opts.dot) circ(c, w - 2, Y(data[data.length - 1]), 2.5, color);
  }

  // ------------------------------------------------------------ icons (canvas, no emoji fonts on old Android)
  function icon(c, name, x, y, s, col) {
    var u = s / 24, i;
    function P(px, py) { return [x + (px - 12) * u, y + (py - 12) * u]; }
    function poly(pts, fill) {
      c.beginPath();
      for (i = 0; i < pts.length; i++) { var p = P(pts[i][0], pts[i][1]); if (i) c.lineTo(p[0], p[1]); else c.moveTo(p[0], p[1]); }
      c.closePath();
      if (fill) c.fill(); else c.stroke();
    }
    function line(a, b, cc, d) { var p = P(a, b), q = P(cc, d); c.beginPath(); c.moveTo(p[0], p[1]); c.lineTo(q[0], q[1]); c.stroke(); }
    function rect(a, b, w, h, fill) { var p = P(a, b); if (fill) c.fillRect(p[0], p[1], w * u, h * u); else c.strokeRect(p[0], p[1], w * u, h * u); }
    function arc(a, b, r, s0, s1) { var p = P(a, b); c.beginPath(); c.arc(p[0], p[1], r * u, s0, s1, false); c.stroke(); }
    function speaker() { poly([[3, 9], [7, 9], [12, 4], [12, 20], [7, 15], [3, 15]], true); }
    c.save();
    c.fillStyle = c.strokeStyle = col; c.lineWidth = Math.max(1.5, 2 * u); c.lineCap = 'round'; c.lineJoin = 'round';
    var PI = Math.PI;
    switch (name) {
      case 'play': poly([[7, 4], [20, 12], [7, 20]], true); break;
      case 'pause': rect(6, 4, 4, 16, true); rect(14, 4, 4, 16, true); break;
      case 'next': poly([[4, 5], [15, 12], [4, 19]], true); rect(16, 5, 3, 14, true); break;
      case 'prev': poly([[20, 5], [9, 12], [20, 19]], true); rect(5, 5, 3, 14, true); break;
      case 'mute': speaker(); line(15, 9, 21, 15); line(21, 9, 15, 15); break;
      case 'voldown': speaker(); arc(12, 12, 4.5, -PI / 4, PI / 4); break;
      case 'volup': speaker(); arc(12, 12, 4.5, -PI / 4, PI / 4); arc(12, 12, 8.5, -PI / 4, PI / 4); break;
      case 'desktop': rect(3, 4, 18, 12, false); line(12, 16, 12, 20); line(8, 20, 16, 20); break;
      case 'monitor': rect(3, 4, 18, 12, false); line(12, 16, 12, 20); line(8, 20, 16, 20); line(7, 7, 17, 13); break;
      case 'screenshot':
        line(3, 8, 3, 3); line(3, 3, 8, 3); line(16, 3, 21, 3); line(21, 3, 21, 8);
        line(21, 16, 21, 21); line(21, 21, 16, 21); line(8, 21, 3, 21); line(3, 21, 3, 16);
        circ(c, x, y, 3.5 * u, col); break;
      case 'lock': rect(5, 11, 14, 10, true); arc(12, 11, 4.5, PI, 2 * PI); line(7.5, 11, 7.5, 9); line(16.5, 11, 16.5, 9); break;
      case 'web': arc(12, 12, 9, 0, 2 * PI); line(3, 12, 21, 12);
        c.beginPath(); var p0 = P(12, 3), p1 = P(12, 21);
        c.moveTo(p0[0], p0[1]); c.quadraticCurveTo(x + 8 * u, y, p1[0], p1[1]); c.quadraticCurveTo(x - 8 * u, y, p0[0], p0[1]); c.stroke(); break;
      case 'app': rect(4, 4, 7, 7, true); rect(13, 4, 7, 7, true); rect(4, 13, 7, 7, true); rect(13, 13, 7, 7, true); break;
      case 'power': arc(12, 13, 8, -PI * 0.3, PI * 1.3); line(12, 3, 12, 12); break;
      case 'mic': rect(9, 3, 6, 11, true); arc(12, 10, 6.5, 0, PI); line(12, 16.5, 12, 21); line(8, 21, 16, 21); break;
      case 'folder': poly([[3, 6], [10, 6], [12, 8], [21, 8], [21, 19], [3, 19]], true); break;
      case 'note': rect(9, 4, 2.5, 13, true); rect(9, 4, 9, 2.5, true); rect(15.5, 4, 2.5, 11, true);
        circ(c, x - 4.5 * u, y + 5 * u, 3 * u, col); circ(c, x + 2 * u, y + 3 * u, 3 * u, col); break;
      default: // star
        var pts = [];
        for (i = 0; i < 10; i++) { var r = i % 2 ? 4 : 9.5, a = -PI / 2 + i * PI / 5; pts.push([12 + Math.cos(a) * r, 12.5 + Math.sin(a) * r]); }
        poly(pts, true);
    }
    c.restore();
  }

  // fast tap: fires on touchstart (old Android delays click by 300ms), falls back to click on desktop
  function tap(el, fn) {
    var lastTouch = 0;
    el.setAttribute('data-tap', '1');   // the page switcher ignores double-taps on interactive elements
    el.addEventListener('touchstart', function (e) { lastTouch = +new Date(); e.preventDefault(); fn(e); }, false);
    el.addEventListener('click', function (e) { if (+new Date() - lastTouch > 600) fn(e); }, false);
  }
  function post(url, cb) {
    var x = new XMLHttpRequest(), done = false;
    var to = setTimeout(function () { if (!done) x.abort(); }, 6000);
    x.onreadystatechange = function () {
      if (x.readyState !== 4 || done) return;
      done = true; clearTimeout(to);
      var d = null; try { d = JSON.parse(x.responseText); } catch (e) {}
      if (cb) cb(x.status, d);
    };
    x.open('POST', url + (url.indexOf('?') < 0 ? '?' : '&') + '_=' + (+new Date()), true);
    x.send('');
  }
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { return null; } }

  // ------------------------------------------------------------ page switcher: long-press (0.7s) or double-tap
  var PAGE_INFO = {
    '01-system': ['Hệ thống', 'CPU, RAM, GPU, mạng, ổ đĩa', '#38bdf8'],
    '02-weather': ['Thời tiết', 'Hiện tại, 24 giờ, 7 ngày', '#fbbf24'],
    '03-finance': ['Tài chính', 'Tỷ giá, crypto', '#34d399'],
    '04-calendar': ['Lịch', 'Đồng hồ lớn, lịch âm, ngày lễ', '#f87171'],
    '05-home': ['Tổng quan', 'Mỗi thứ một ít', '#a78bfa'],
    '07-media': ['Đang phát', 'Nhạc trên máy tính', '#22d3ee'],
    '08-wave': ['Sóng nhạc', 'Phổ cầu vồng theo nhạc', '#f472b6'],
    '09-pixel': ['Ảnh 8-bit', 'Pixel art động, toàn màn hình', '#34d399']
  };
  // single short tap anywhere that is not a button (pages register with MS.onTap)
  var tapFns = [];
  function onTap(f) { tapFns.push(f); }
  function fireTap(e) { for (var i = 0; i < tapFns.length; i++) { try { tapFns[i](e); } catch (er) {} } }
  function switcher() {
    var appEl = $('app');
    if (!appEl) return;
    var ov = null, timer = null, x0 = 0, y0 = 0, lastTapAt = 0, lastTapX = 0, lastTapY = 0;
    var openedDuringTouch = false, suppressUntil = 0, lastTouchAt = 0;

    function isInteractive(el) { while (el && el !== document) { if (el.getAttribute && el.getAttribute('data-tap')) return true; el = el.parentNode; } return false; }
    function close() { cancel(); if (ov) { ov.parentNode.removeChild(ov); ov = null; } }
    function go(file, current) {
      if (file === current) { close(); return; }
      post('/api/page?p=' + file, function (status) { location.href = status === 200 ? '/' : '/' + file; });
    }
    function open() {
      if (ov) return;
      openedDuringTouch = true;
      ov = document.createElement('div');
      ov.style.cssText = 'position:absolute;left:0;top:0;width:64rem;height:36rem;background:rgba(5,7,10,0.95);z-index:50;font-family:Roboto,"Segoe UI",Arial,sans-serif;color:#e6ebf2;';
      ov.innerHTML = '<div style="position:absolute;left:0;right:0;top:2.6rem;text-align:center;font-size:1.7rem;font-weight:700;letter-spacing:.2rem">CHỌN MÀN HÌNH</div>' +
        '<div style="position:absolute;left:0;right:0;top:5.2rem;text-align:center;font-size:1.05rem;color:#7b8799">Chạm vào trang muốn xem · chạm ra ngoài để đóng</div>' +
        '<div id="psw-list" style="position:absolute;left:0;top:0"></div>';
      appEl.appendChild(ov);
      tap(ov, function (e) { if ((e.target || e.srcElement) === ov) close(); });
      var x = new XMLHttpRequest();
      x.onreadystatechange = function () {
        if (x.readyState !== 4 || !ov) return;
        var d = null; try { d = JSON.parse(x.responseText); } catch (er) {}
        if (!d || !d.pages) { $('psw-list').innerHTML = '<div style="position:absolute;left:20rem;top:15rem;width:24rem;text-align:center;color:#f87171">Không tải được danh sách trang</div>'; return; }
        var path = location.pathname.replace(/^\//, ''), current = path && /\.html$/.test(path) ? path : d.current;
        var n = d.pages.length, cols = n > 8 ? 5 : 4, w = cols === 5 ? 11.4 : 14.2, gap = 0.9, h = 10.2;
        var left0 = (64 - (cols * w + (cols - 1) * gap)) / 2, s = '', i;
        for (i = 0; i < n; i++) {
          var f = d.pages[i].file, key = f.replace(/\.html$/, ''), info = PAGE_INFO[key] || [key, d.pages[i].desc || '', '#9aa5b6'];
          var cur = f === current, col = i % cols, row = Math.floor(i / cols);
          s += '<div id="psw' + i + '" style="position:absolute;left:' + (left0 + col * (w + gap)).toFixed(2) + 'rem;top:' + (8 + row * (h + gap)).toFixed(2) + 'rem;width:' + w + 'rem;height:' + h + 'rem;' +
            'background:#0e131b;border:' + (cur ? '2px solid ' + info[2] : '1px solid #1f2835') + ';-webkit-border-radius:1.2rem;border-radius:1.2rem;cursor:pointer">' +
            '<div style="position:absolute;left:1.3rem;top:1.3rem;width:2.4rem;height:.4rem;background:' + info[2] + ';-webkit-border-radius:.2rem;border-radius:.2rem"></div>' +
            '<div style="position:absolute;left:1.3rem;right:1rem;top:2.6rem;font-size:1.65rem;font-weight:700;white-space:nowrap;overflow:hidden">' + esc(info[0]) + '</div>' +
            '<div style="position:absolute;left:1.3rem;right:1rem;top:5.1rem;font-size:1rem;line-height:1.35rem;color:#7b8799;height:2.7rem;overflow:hidden">' + esc(info[1]) + '</div>' +
            (cur ? '<div style="position:absolute;left:1.3rem;bottom:1rem;font-size:.85rem;font-weight:700;letter-spacing:.1rem;color:' + info[2] + '">ĐANG XEM</div>' : '') + '</div>';
        }
        $('psw-list').innerHTML = s;
        for (i = 0; i < n; i++) (function (f) { tap($('psw' + i), function () { go(f, current); }); })(d.pages[i].file);
      };
      x.open('GET', '/api/pages?_=' + (+new Date()), true); x.send(null);
    }

    function start(x, y) { clearTimeout(timer); x0 = x; y0 = y; timer = setTimeout(open, 700); }
    function cancel() { clearTimeout(timer); timer = null; }
    function moved(x, y) { if (Math.abs(x - x0) > 12 || Math.abs(y - y0) > 12) cancel(); }
    function doubleTap(x, y, target) {
      var now = +new Date();
      if (!ov && !isInteractive(target) && now - lastTapAt < 380 && Math.abs(x - lastTapX) < 40 && Math.abs(y - lastTapY) < 40) { lastTapAt = 0; open(); openedDuringTouch = true; return; }
      lastTapAt = now; lastTapX = x; lastTapY = y;
    }

    // touchstart must be non-passive so preventDefault works: it stops the browser's own long-press
    // menu ("save image", text selection...) so holding shows OUR page picker instead
    // capture phase: this runs BEFORE the picker tiles' own handlers. A tile tap closes the picker and removes the tile;
    // the touchend of that touch then never reaches the document, so a long-press timer started here would never be
    // cancelled and the picker would pop up again. Running first, we still see `ov` open and skip the timer.
    var passiveOff = true;
    try { window.addEventListener('test', null, Object.defineProperty({}, 'passive', { get: function () { passiveOff = { passive: false, capture: true }; return true; } })); } catch (er) {}
    var downAt = 0, movedFar = false;
    document.addEventListener('touchstart', function (e) {
      lastTouchAt = downAt = +new Date(); movedFar = false;
      if (e.cancelable && e.preventDefault) e.preventDefault();
      if (ov || e.touches.length > 1) { cancel(); return; }
      openedDuringTouch = false;
      var t = e.touches[0];
      start(t.clientX, t.clientY);
      doubleTap(t.clientX, t.clientY, e.target);
    }, passiveOff);
    document.addEventListener('touchmove', function (e) {
      if (e.touches[0]) { moved(e.touches[0].clientX, e.touches[0].clientY); if (!timer) movedFar = true; }
    }, false);
    function touchEnd(e) {
      cancel();
      var wasOpen = openedDuringTouch;
      if (openedDuringTouch) { suppressUntil = +new Date() + 500; openedDuringTouch = false; }
      // short single tap on a non-button area -> page's own tap handler (e.g. next photo)
      if (e && e.type === 'touchend' && !wasOpen && !ov && !movedFar && +new Date() - downAt < 350 && !isInteractive(e.target)) fireTap(e);
    }
    document.addEventListener('touchend', touchEnd, false);
    document.addEventListener('contextmenu', function (e) { if (e.preventDefault) e.preventDefault(); return false; }, false);
    // desktop mouse click -> same single-tap handlers
    document.addEventListener('click', function (e) {
      if (+new Date() - lastTouchAt < 1000 || ov || +new Date() < suppressUntil || isInteractive(e.target)) return;
      fireTap(e);
    }, false);
    document.addEventListener('touchcancel', touchEnd, false);
    // mouse (desktop testing)
    document.addEventListener('mousedown', function (e) { if (+new Date() - lastTouchAt < 1000 || ov) return; openedDuringTouch = false; start(e.clientX, e.clientY); }, false);
    document.addEventListener('mousemove', function (e) { if (timer) moved(e.clientX, e.clientY); }, false);
    document.addEventListener('mouseup', function () { if (+new Date() - lastTouchAt < 1000) return; touchEnd(); }, false);
    document.addEventListener('dblclick', function (e) { if (!ov && !isInteractive(e.target)) open(); }, false);
    // the click that follows the long-press release must not hit anything (e.g. "next photo" or a tile)
    document.addEventListener('click', function (e) { if (+new Date() < suppressUntil) { e.stopPropagation(); if (e.preventDefault) e.preventDefault(); } }, true);
    // no text selection / callout menu on long-press
    document.body.style.webkitTouchCallout = 'none';
    document.body.style.webkitUserSelect = 'none';

    // one-time hint
    if (!store('ms-hint')) {
      store('ms-hint', '1');
      var h = document.createElement('div');
      h.style.cssText = 'position:absolute;left:18rem;top:31.6rem;width:28rem;padding:.7rem 0;text-align:center;font-size:1.05rem;color:#e6ebf2;background:rgba(14,19,27,0.92);border:1px solid #38bdf8;-webkit-border-radius:2rem;border-radius:2rem;z-index:40;font-family:Roboto,Arial,sans-serif;';
      h.innerHTML = 'Giữ màn hình hoặc chạm 2 lần để đổi trang';
      appEl.appendChild(h);
      setTimeout(function () { if (h.parentNode) h.parentNode.removeChild(h); }, 5000);
    }
  }
  if (document.body) switcher(); else window.addEventListener('load', switcher, false);

  // ------------------------------------------------------------ keep the phone screen bright
  // Old Android browsers have no Wake Lock API. A playing <video> makes Android hold a full screen wake lock
  // (stays bright even when the display timeout / "stay awake" would dim it). nosleep.mp4 = 1-minute black
  // H.264 Baseline clip (3.4 KB), muted, 2x2 px, almost transparent. Video playback needs a user gesture on
  // old browsers, so it starts on the first touch. Disable with ?nosleep=0
  // Play a muted <video> forever on old Android browsers: they ignore `loop` and need a user gesture for the first
  // play(). Rewinds just before the end (or calls onNearEnd, e.g. to switch clips), reloads if it stops, starts on the
  // first touch, and a watchdog restarts it every 10 s if it stalled. Later play() calls need no new touch.
  function loopVideo(v, onNearEnd) {
    v.setAttribute('muted', ''); v.muted = true;
    v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', '');
    v.setAttribute('preload', 'auto');
    function play() { try { var p = v.play(); if (p && p['catch']) p['catch'](function () {}); } catch (e) {} }
    function restart() { try { v.currentTime = 0.1; } catch (e) {} play(); }
    function reloadPlay() { try { v.load(); } catch (e) {} play(); }
    var nearEndAt = -1;
    v.addEventListener('ended', function () { if (onNearEnd) onNearEnd(); else restart(); setTimeout(function () { if (v.paused || v.ended) reloadPlay(); }, 1500); }, false);
    v.addEventListener('timeupdate', function () {
      if (!v.duration || v.currentTime <= v.duration - 1.5) { nearEndAt = -1; return; }
      if (nearEndAt === v.currentSrc) return;   // only once per pass
      nearEndAt = v.currentSrc;
      if (onNearEnd) onNearEnd(); else restart();
    }, false);
    var started = false;
    v.addEventListener('playing', function () { started = true; }, false);
    function kick() { if (v.paused) play(); }        // every touch retries until it really plays
    document.addEventListener('touchstart', kick, true);
    document.addEventListener('click', kick, true);
    play();   // works right away where autoplay of muted video is allowed
    setInterval(function () { if (started) { if (v.ended) reloadPlay(); else if (v.paused) play(); } }, 10000);
    return { play: play, restart: restart };
  }

  function keepAwake() {
    // pages with their own background video set <body data-nosleep="0"> (old browsers play one video at a time)
    if (/[?&]nosleep=0/.test(location.search) || document.body.getAttribute('data-nosleep') === '0' || !document.createElement('video').canPlayType) return;
    var v = document.createElement('video');
    v.style.cssText = 'position:fixed;left:0;bottom:0;width:2px;height:2px;opacity:0.01;pointer-events:none;z-index:0;';
    v.src = '/nosleep.mp4';
    document.body.appendChild(v);
    loopVideo(v);
  }
  if (document.body) keepAwake(); else window.addEventListener('load', keepAwake, false);

  // 24 solar terms (tiet khi): index 0 = Xuan phan (sun longitude 0 deg), each 15 deg, at the start of the local day
  var TIET_KHI = ['Xuân phân', 'Thanh minh', 'Cốc vũ', 'Lập hạ', 'Tiểu mãn', 'Mang chủng', 'Hạ chí', 'Tiểu thử', 'Đại thử',
    'Lập thu', 'Xử thử', 'Bạch lộ', 'Thu phân', 'Hàn lộ', 'Sương giáng', 'Lập đông', 'Tiểu tuyết', 'Đại tuyết', 'Đông chí',
    'Tiểu hàn', 'Đại hàn', 'Lập xuân', 'Vũ thủy', 'Kinh trập'];
  function sunDeg(jd) { return sunLongitude(jd - 0.5 - TZ / 24) * 180 / Math.PI; }
  function solarTerm(jd) { var i = Math.floor(sunDeg(jd) / 15) % 24; return { i: i, name: TIET_KHI[i], deg: sunDeg(jd) }; }

  // ------------------------------------------------------------ init
  function init() {
    app = $('app');
    var rt;
    function relayout() { clearTimeout(rt); rt = setTimeout(layout, 120); }
    window.addEventListener('resize', relayout, false);
    window.addEventListener('orientationchange', relayout, false);
    // AMOLED burn-in protection: nudge a few px every 2 minutes
    setInterval(function () { sx = Math.round(Math.random() * 6 - 3); sy = Math.round(Math.random() * 6 - 3); layout(); }, 120000);
    layout();
    if ($('time')) { clockTick(); setInterval(clockTick, 500); }
  }

  return {
    lite: lite, hideBar: hideBar, clipBottom: clipBottom, icon: icon, tap: tap, post: post, store: store, onTap: onTap,
    loopVideo: loopVideo, solarTerm: solarTerm, CAN: CAN, CHI: CHI,
    utcNow: function () { return +new Date() + off; },
    $: $, html: html, esc: esc, pad: pad, hexA: hexA, fmt: fmt, font: font,
    init: init, layout: layout, onLayout: onLayout, ctx2d: ctx2d, unit: function () { return unit; },
    poll: poll, live: live, setServerTime: setServerTime, now: now, DOW: DOW, DOWS: DOWS, hhmm: hhmm,
    solar2lunar: solar2lunar, lunar2solar: lunar2solar, jd: jdFromDate,
    ccYear: ccYear, ccMonth: ccMonth, ccDay: ccDay, lunarMonthName: lunarMonthName, lunarDayName: lunarDayName,
    wx: wx, drawWx: drawWx, aqiInfo: aqiInfo, windDir: windDir, ring: ring, sparkline: sparkline, circ: circ
  };
})();
