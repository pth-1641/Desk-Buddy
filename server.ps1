# Desk-Buddy - dashboard server for an old phone on the LAN (PowerShell 5.1, no dependencies)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1 [-Port 8080] [-Page 02-weather.html] [-NoMenu]
# Keep this file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI (Vietnamese text would break).
# See README.md for the architecture.
param(
  [int]$Port = 8080,
  [int]$IntervalMs = 2000,
  [string]$Page = '',  # page served at "/" (file name in pages\, e.g. 02-weather.html); empty = ask
  [switch]$NoMenu      # don't ask: reuse the last page (for auto-start at logon)
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PagesDir = Join-Path $Root 'pages'

# ---------------------------------------------------------------- page menu
function Get-PageDesc($file) {
  $head = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
  if ($head -match '<meta name="menu" content="([^"]+)"') { return $matches[1] }
  return ''
}
$lastFile = Join-Path $Root 'last-page.txt'
$pages = @(Get-ChildItem $PagesDir -Filter *.html | Sort-Object Name)
if (-not $Page -and $NoMenu) {
  $Page = $pages[0].Name
  if (Test-Path $lastFile) { $l = (Get-Content $lastFile -TotalCount 1).Trim(); if ($l -and (Test-Path (Join-Path $PagesDir $l))) { $Page = $l } }
}
if (-not $Page) {
  $last = ''
  if (Test-Path $lastFile) { $last = (Get-Content $lastFile -TotalCount 1) }
  $def = 1
  Write-Host ''
  Write-Host '  CHON MAN HINH' -ForegroundColor Cyan
  for ($i = 0; $i -lt $pages.Count; $i++) {
    $isLast = ($pages[$i].Name -eq $last)
    if ($isLast) { $def = $i + 1 }
    $mark = if ($isLast) { '*' } else { ' ' }
    Write-Host ("  {0}{1,2}. {2,-20} {3}" -f $mark, ($i + 1), $pages[$i].Name, (Get-PageDesc $pages[$i].FullName))
  }
  $ans = Read-Host "  Nhap so (Enter = $def)"
  $sel = $def
  if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $pages.Count) { $sel = [int]$ans }
  $Page = $pages[$sel - 1].Name
}
$PagePath = Join-Path $PagesDir $Page
if (-not (Test-Path $PagePath)) { Write-Host "Khong tim thay pages\$Page" -ForegroundColor Red; exit 1 }
Set-Content -Path $lastFile -Value $Page -Encoding ASCII
Write-Host "  Man hinh: $Page  ($(Get-PageDesc $PagePath))" -ForegroundColor Yellow

# ---------------------------------------------------------------- config
$cfg = [IO.File]::ReadAllText((Join-Path $Root 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json

# ---------------------------------------------------------------- internet data fetcher (weather, rates, crypto)
$ext = [hashtable]::Synchronized(@{ json = '{}'; running = $true; err = @{}; lastWant = [DateTime]::UtcNow })
$fetcher = {
  param($ext, $cfg)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $syms = @($cfg.crypto | ForEach-Object { ([string]$_).ToUpper() + 'USDT' })
  $curList = @('USD') + @($cfg.currencies)
  $lat = $null; $lon = $null; $cityJson = '""'; $locSrc = ''
  $loc = $null; $locDue = [DateTime]::MinValue

  # ---- location: config.city = "auto" (guess from public IP) | "<city name>" (geocoded) ; optional lat/lon override
  function Get-Utf8($url) { [Text.Encoding]::UTF8.GetString((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 15 -UserAgent 'DeskBuddy/1.0').RawContentStream.ToArray()) }
  function Find-Place($name) {
    foreach ($cc in @('&countryCode=VN', '')) {
      $j = Get-Utf8 ('https://geocoding-api.open-meteo.com/v1/search?count=1&language=vi' + $cc + '&name=' + [Uri]::EscapeDataString($name)) | ConvertFrom-Json
      if ($j.results) {
        $r = $j.results[0]
        return @{ name = ([string]$r.name -replace '^(Th\S+nh [Pp]h\S+|T\S+nh)\s+', ''); lat = [double]$r.latitude; lon = [double]$r.longitude }
      }
    }
    return $null
  }
  function Resolve-Location {
    $c = ([string]$cfg.city).Trim()
    if ($c -and $c -ne 'auto') {
      if ($cfg.lat -and $cfg.lon) { return @{ name = $c; lat = [double]$cfg.lat; lon = [double]$cfg.lon; src = 'config' } }
      $p = Find-Place $c
      if ($p) { $p.src = 'name'; return $p }
      throw "city not found: $c"
    }
    $ip = Get-Utf8 'https://ipwho.is/?fields=success,city,latitude,longitude' | ConvertFrom-Json
    if (-not $ip.success) { throw 'IP location lookup failed' }
    $name = [string]$ip.city
    try {   # nicer Vietnamese name (with diacritics) if the geocoder agrees on the place
      $p = Find-Place $name
      if ($p -and [math]::Abs($p.lat - $ip.latitude) -lt 0.5 -and [math]::Abs($p.lon - $ip.longitude) -lt 0.5) { $name = $p.name }
    } catch {}
    return @{ name = $name; lat = [double]$ip.latitude; lon = [double]$ip.longitude; src = 'ip' }
  }
  $raw = @{ weather = 'null'; aqi = 'null'; rates = 'null'; ticker = 'null'; klines = '{}' }
  $upd = @{ weather = 0; rates = 0; crypto = 0 }
  $due = @{ weather = [DateTime]::MinValue; rates = [DateTime]::MinValue; ticker = [DateTime]::MinValue; klines = [DateTime]::MinValue }

  function Get-Text($url) { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 20 -UserAgent 'DeskBuddy/1.0').Content }
  function Get-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  function To-Num($s) {
    $s = ([string]$s).Trim() -replace ',', ''
    if ($s -eq '' -or $s -eq '-') { return $null }
    return [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)
  }

  while ($ext.running) {
    # no page asked for this data in 10 minutes (phone off): pause; resumes on the next request
    if (([DateTime]::UtcNow - $ext.lastWant).TotalMinutes -gt 10) { Start-Sleep -Seconds 1; continue }
    $now = [DateTime]::UtcNow
    $changed = $false

    if ($now -ge $locDue) {
      try {
        $new = Resolve-Location
        if (-not $loc -or $new.lat -ne $loc.lat -or $new.lon -ne $loc.lon -or $new.name -ne $loc.name) { $loc = $new; $due.weather = [DateTime]::MinValue }
        $ext.err.location = $null
        $locDue = $now.AddHours(6)   # re-check (laptops move)
      } catch {
        $ext.err.location = $_.ToString(); $locDue = $now.AddMinutes(5)
        if (-not $loc) { $loc = @{ name = 'Ha Noi'; lat = 21.0285; lon = 105.8542; src = 'fallback' } }
      }
      $lat = ([double]$loc.lat).ToString($inv); $lon = ([double]$loc.lon).ToString($inv)
      $cityJson = ConvertTo-Json ([string]$loc.name); $locSrc = [string]$loc.src
      $changed = $true
    }

    if ($now -ge $due.weather) {
      try {
        $raw.weather = Get-Text ("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
          '&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,wind_direction_10m,precipitation,pressure_msl' +
          '&hourly=temperature_2m,precipitation_probability,weather_code,is_day' +
          '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max' +
          '&timezone=auto&forecast_days=7&forecast_hours=25')
        try { $raw.aqi = Get-Text "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=$lat&longitude=$lon&current=us_aqi,pm2_5,pm10&timezone=auto" } catch { $ext.err.aqi = $_.ToString() }
        $upd.weather = Get-Ms; $ext.err.weather = $null
        $due.weather = $now.AddMinutes(10)
      } catch { $ext.err.weather = $_.ToString(); $due.weather = $now.AddMinutes(1) }
      $changed = $true
    }

    if ($now -ge $due.rates) {
      try {
        $text = Get-Text 'https://portal.vietcombank.com.vn/Usercontrols/TVPortal.TyGia/pXML.aspx'
        $x = [xml]($text.Substring($text.IndexOf('<ExrateList')))
        $byCode = @{}
        foreach ($r in $x.ExrateList.Exrate) { $byCode[$r.CurrencyCode.Trim()] = $r }
        $list = @()
        foreach ($code in $curList) {
          $r = $byCode[$code]
          if ($r) {
            $list += [ordered]@{ code = $code; name = $r.CurrencyName.Trim(); buy = (To-Num $r.Buy); transfer = (To-Num $r.Transfer); sell = (To-Num $r.Sell) }
          }
        }
        $raw.rates = ConvertTo-Json @{ time = [string]$x.ExrateList.DateTime; list = $list } -Depth 4 -Compress
        $upd.rates = Get-Ms; $ext.err.rates = $null
        $due.rates = $now.AddMinutes(10)
      } catch { $ext.err.rates = $_.ToString(); $due.rates = $now.AddMinutes(2) }
      $changed = $true
    }

    if ($syms.Count -gt 0 -and $now -ge $due.ticker) {
      try {
        $q = [Uri]::EscapeDataString('["' + ($syms -join '","') + '"]')
        $raw.ticker = Get-Text "https://api.binance.com/api/v3/ticker/24hr?symbols=$q"
        $upd.crypto = Get-Ms; $ext.err.crypto = $null
        $due.ticker = $now.AddSeconds(20)
      } catch { $ext.err.crypto = $_.ToString(); $due.ticker = $now.AddMinutes(1) }
      $changed = $true
    }

    if ($syms.Count -gt 0 -and $now -ge $due.klines) {
      try {
        $parts = @()
        foreach ($s in $syms) {
          $k = Get-Text "https://api.binance.com/api/v3/klines?symbol=$s&interval=1h&limit=48" | ConvertFrom-Json
          $closes = @($k | ForEach-Object { [double]::Parse([string]$_[4], $inv) })
          $parts += ('"' + $s + '":[' + (($closes | ForEach-Object { $_.ToString($inv) }) -join ',') + ']')
        }
        $raw.klines = '{' + ($parts -join ',') + '}'
        $due.klines = $now.AddMinutes(10)
      } catch { $ext.err.klines = $_.ToString(); $due.klines = $now.AddMinutes(2) }
      $changed = $true
    }

    if ($changed) {
      $tzMin = [int][TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes
      # body without the leading '{"t":..,' - the timestamp is added per request
      $ext.json = '"tz":' + $tzMin + ',"city":' + $cityJson + ',"locSrc":"' + $locSrc + '"' +
        ',"upd":{"weather":' + $upd.weather + ',"rates":' + $upd.rates + ',"crypto":' + $upd.crypto + '}' +
        ',"weather":' + $raw.weather + ',"aqi":' + $raw.aqi + ',"rates":' + $raw.rates +
        ',"ticker":' + $raw.ticker + ',"klines":' + $raw.klines + '}'
    }
    Start-Sleep -Milliseconds 1000
  }
}
$frs = [runspacefactory]::CreateRunspace(); $frs.Open()
$fps = [powershell]::Create(); $fps.Runspace = $frs
[void]$fps.AddScript($fetcher).AddArgument($ext).AddArgument($cfg)
$fhandle = $fps.BeginInvoke()

# ---------------------------------------------------------------- browser extension: tell it which port to talk to
$extCfg = Join-Path $Root 'extension\config.js'
if (Test-Path (Split-Path $extCfg)) {
  # only created when missing (edit it by hand + reload the extension if you change the port)
  if (-not (Test-Path $extCfg)) { Set-Content -Path $extCfg -Value "var DESKBUDDY_PORT = $Port;" -Encoding ASCII }
}

# ---------------------------------------------------------------- native helpers (C#, compiled at start)
# Audio: master volume / mute via Core Audio.  Input: media keys + WM_APPCOMMAND (Spotify desktop).
Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
namespace DeskBuddy {
  [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioClient {
    int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr session);
    int GetBufferSize(out uint frames); int GetStreamLatency(out long lat); int GetCurrentPadding(out uint pad);
    int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest); int GetMixFormat(out IntPtr fmt);
    int GetDevicePeriod(out long def, out long min); int Start(); int Stop(); int Reset(); int SetEventHandle(IntPtr h);
    int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  }
  [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioCaptureClient {
    int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devPos, out ulong qpcPos);
    int ReleaseBuffer(uint frames); int GetNextPacketSize(out uint frames);
  }
  // Live spectrum of what the speakers play: WASAPI loopback capture -> 2048-point FFT -> 48 log-spaced bands (40 Hz..16 kHz).
  // Runs on its own thread, started by the first Get(), stops after 10 s without readers.
  public static class Spectrum {
    public const int BANDS = 48;
    const string ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_";
    static float[] bands = new float[BANDS];
    static volatile bool run; static DateTime lastGet;
    // 48 levels (0..63 each) packed into a 48-char string
    public static string GetEncoded() {
      lastGet = DateTime.UtcNow;
      if (!run) { run = true; Thread t = new Thread(Loop); t.IsBackground = true; t.Start(); }
      char[] s = new char[BANDS];
      lock (bands) { for (int i = 0; i < BANDS; i++) s[i] = ALPHA[Math.Max(0, Math.Min(63, (int)(bands[i] * 63 + 0.5)))]; }
      return new string(s);
    }
    static void Fft(double[] re, double[] im) {
      int n = re.Length;
      for (int i = 1, j = 0; i < n; i++) { int bit = n >> 1; for (; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
      for (int len = 2; len <= n; len <<= 1) {
        double ang = -2 * Math.PI / len, wr = Math.Cos(ang), wi = Math.Sin(ang);
        for (int i = 0; i < n; i += len) {
          double cr = 1, ci = 0;
          for (int k = 0; k < len / 2; k++) {
            int a = i + k, b = a + len / 2;
            double xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr;
            re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
            double t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
          }
        }
      }
    }
    static void Loop() {
      IAudioClient ac = null;
      try {
        IMMDevice dev; object o; Guid iid = typeof(IAudioClient).GUID;
        Marshal.ThrowExceptionForHR(((IMMDeviceEnumerator)new MMDeviceEnumeratorCom()).GetDefaultAudioEndpoint(0, 1, out dev));
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
        ac = (IAudioClient)o;
        IntPtr fmt; Marshal.ThrowExceptionForHR(ac.GetMixFormat(out fmt));
        int ch = Marshal.ReadInt16(fmt, 2), rate = Marshal.ReadInt32(fmt, 4), bits = Marshal.ReadInt16(fmt, 14);
        Marshal.ThrowExceptionForHR(ac.Initialize(0, 0x00020000 /* LOOPBACK */, 10000000, 0, fmt, IntPtr.Zero));
        Guid cid = typeof(IAudioCaptureClient).GUID; object co;
        Marshal.ThrowExceptionForHR(ac.GetService(ref cid, out co));
        IAudioCaptureClient cap = (IAudioCaptureClient)co;
        Marshal.ThrowExceptionForHR(ac.Start());
        const int N = 2048;
        float[] ring = new float[N]; int pos = 0;
        double[] win = new double[N], re = new double[N], im = new double[N];
        for (int i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (N - 1));
        int[] b0 = new int[BANDS], b1 = new int[BANDS]; double[] tilt = new double[BANDS];
        double fmin = 40, fmax = Math.Min(16000, rate / 2.0);
        for (int k = 0; k < BANDS; k++) {
          double fa = fmin * Math.Pow(fmax / fmin, (double)k / BANDS), fb = fmin * Math.Pow(fmax / fmin, (double)(k + 1) / BANDS);
          b0[k] = Math.Max(1, (int)(fa * N / rate)); b1[k] = Math.Max(b0[k], (int)(fb * N / rate));
          tilt[k] = Math.Max(0, 3.0 * Math.Log(Math.Sqrt(fa * fb) / 200.0, 2));   // +3 dB/octave above 200 Hz so treble is visible
        }
        float[] fbuf = new float[0]; short[] sbuf = new short[0];
        DateTime lastFft = DateTime.UtcNow, lastPacket = DateTime.UtcNow;
        while (run && (DateTime.UtcNow - lastGet).TotalSeconds < 10) {
          uint pk; cap.GetNextPacketSize(out pk);
          while (pk > 0) {
            IntPtr data; uint frames, flags; ulong dp, qp;
            Marshal.ThrowExceptionForHR(cap.GetBuffer(out data, out frames, out flags, out dp, out qp));
            int cnt = (int)frames * ch; bool silent = (flags & 2) != 0;
            if (!silent && bits == 32) { if (fbuf.Length < cnt) fbuf = new float[cnt]; Marshal.Copy(data, fbuf, 0, cnt); }
            else if (!silent && bits == 16) { if (sbuf.Length < cnt) sbuf = new short[cnt]; Marshal.Copy(data, sbuf, 0, cnt); }
            for (int f = 0; f < frames; f++) {
              float s = 0;
              if (!silent) for (int c = 0; c < ch; c++) s += bits == 32 ? fbuf[f * ch + c] : sbuf[f * ch + c] / 32768f;
              ring[pos] = s / ch; pos = (pos + 1) % N;
            }
            cap.ReleaseBuffer(frames); cap.GetNextPacketSize(out pk);
            lastPacket = DateTime.UtcNow;
          }
          // nothing is playing: loopback delivers no packets at all -> let the bars fall
          if ((DateTime.UtcNow - lastPacket).TotalMilliseconds > 150) Array.Clear(ring, 0, N);
          if ((DateTime.UtcNow - lastFft).TotalMilliseconds >= 30) {
            lastFft = DateTime.UtcNow;
            for (int i = 0; i < N; i++) { re[i] = ring[(pos + i) % N] * win[i]; im[i] = 0; }
            Fft(re, im);
            lock (bands) {
              for (int k = 0; k < BANDS; k++) {
                double mx = 0;
                for (int b = b0[k]; b <= b1[k]; b++) { double mg = Math.Sqrt(re[b] * re[b] + im[b] * im[b]); if (mg > mx) mx = mg; }
                double db = 20 * Math.Log10(mx / (N / 4.0) + 1e-9) + tilt[k];
                double v = Math.Max(0, Math.Min(1, (db + 66) / 58));
                bands[k] = (float)Math.Max(v, bands[k] * 0.82);   // fast rise, smooth fall
              }
            }
          }
          Thread.Sleep(10);
        }
      } catch { }
      finally {
        if (ac != null) { try { ac.Stop(); } catch { } }
        lock (bands) { Array.Clear(bands, 0, BANDS); }
        run = false;
      }
    }
  }
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int f1(IntPtr p); int f2(IntPtr p); int f3(out uint c); int f4(float l, ref Guid g);
    int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int f6(out float l);
    int GetMasterVolumeLevelScalar(out float level);
    int f8(uint c, float l, ref Guid g); int f9(uint c, float l, ref Guid g); int f10(uint c, out float l); int f11(uint c, out float l);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice { int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator { int f1(int a, int b, out IntPtr c); int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d); }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
  [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioMeterInformation {
    int GetPeakValue(out float p); int GetMeteringChannelCount(out uint n);
    int GetChannelsPeakValues(uint n, [Out, MarshalAs(UnmanagedType.LPArray)] float[] p);
  }

  public static class Audio {
    static object Activate(Guid iid) {
      IMMDevice dev; object o;
      Marshal.ThrowExceptionForHR(((IMMDeviceEnumerator)new MMDeviceEnumeratorCom()).GetDefaultAudioEndpoint(0, 1, out dev));
      Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
      return o;
    }
    static IAudioEndpointVolume Ep() { return (IAudioEndpointVolume)Activate(typeof(IAudioEndpointVolume).GUID); }
    // peak level per channel (0..1) of what is playing on the default output. Re-activated every 30 s
    // (and after errors) so a change of the default device is picked up.
    static IAudioMeterInformation meter; static DateTime meterAt;
    public static float[] Peaks() {
      try {
        if (meter == null || (DateTime.UtcNow - meterAt).TotalSeconds > 30) { meter = (IAudioMeterInformation)Activate(typeof(IAudioMeterInformation).GUID); meterAt = DateTime.UtcNow; }
        uint n; Marshal.ThrowExceptionForHR(meter.GetMeteringChannelCount(out n));
        if (n == 0) return new float[] { 0, 0 };
        float[] p = new float[n]; Marshal.ThrowExceptionForHR(meter.GetChannelsPeakValues(n, p)); return p;
      } catch { meter = null; return new float[] { 0, 0 }; }
    }
    public static int GetVolume() { float v; Marshal.ThrowExceptionForHR(Ep().GetMasterVolumeLevelScalar(out v)); return (int)Math.Round(v * 100); }
    public static void SetVolume(int pct) { Guid g = Guid.Empty; Marshal.ThrowExceptionForHR(Ep().SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, pct)) / 100f, ref g)); }
    public static bool GetMute() { bool m; Marshal.ThrowExceptionForHR(Ep().GetMute(out m)); return m; }
    public static void SetMute(bool m) { Guid g = Guid.Empty; Marshal.ThrowExceptionForHR(Ep().SetMute(m, ref g)); }
  }
  public static class Input {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    // single media key (0xB3 play/pause, 0xB0 next, 0xB1 prev), sent as an extended key
    public static void Press(byte vk) { keybd_event(vk, 0, 1, UIntPtr.Zero); keybd_event(vk, 0, 3, UIntPtr.Zero); }
    // WM_APPCOMMAND to a window: 14 play/pause, 11 next, 12 previous
    public static void AppCommand(IntPtr hwnd, int cmd) { PostMessage(hwnd, 0x0319, hwnd, (IntPtr)(cmd << 16)); }
  }
}
'@

# ---------------------------------------------------------------- now playing + media control
# Uses the Windows media session API when available; otherwise falls back to window titles
# (Spotify, YouTube / YouTube Music in a browser tab, VLC, foobar2000) + iTunes artwork lookup.
$media = [hashtable]::Synchronized(@{ running = $true; json = '{"has":false}'; art = $null; cmds = (New-Object Collections.ArrayList); err = $null; lastWant = [DateTime]::MinValue
    ext = [hashtable]::Synchronized(@{}); extQ = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); target = '' })
$mediaWorker = {
  param($media)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $mgr = $null; $asTaskGeneric = $null
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $mt = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $task = $asTaskGeneric.MakeGenericMethod($mt).Invoke($null, @($mt::RequestAsync()))
    [void]$task.Wait(5000); $mgr = $task.Result
  } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $media.err = 'media session API unavailable: ' + $e.Message }
  function Wait-Op($op, [Type]$t) { $tk = $asTaskGeneric.MakeGenericMethod($t).Invoke($null, @($op)); [void]$tk.Wait(3000); return $tk.Result }

  # drop "(Official MV)", "[Lyrics]", "/ Audio Lyrics", "| Official Music Video" ...
  function Get-CleanTitle([string]$t2) {
    $t2 = $t2 -replace '\s*[\(\[][^\)\]]*(?i:official|lyric|m/?v|audio|video|visuali[sz]er)[^\)\]]*[\)\]]', ''
    $t2 = $t2 -replace '\s*[/|]\s*[^/|]*(?i:official|lyric|\bm/?v\b|audio|video|visuali[sz]er)[^/|]*', ''
    # trailing "| Some Channel Music / Records / TV"
    $t2 = $t2 -replace '\s*\|\s*[^|]*(?i:music|records|entertainment|channel|\btv\b|studio|official)[^|]*$', ''
    # trailing " - Official MV" / " - Lyrics Video"
    $t2 = $t2 -replace '\s+\p{Pd}\s+[^\p{Pd}|]*(?i:official|lyric|\bm/?v\b|audio|video|visuali[sz]er)[^\p{Pd}|]*$', ''
    # leftovers like "Title -  |" or "Title -"
    $t2 = ($t2 -replace '\s+\p{Pd}\s+\|', ' |') -replace '(\s*[\p{Pd}|]\s*)+$', '' -replace '\s{2,}', ' '
    return $t2.Trim()
  }

  # square cover from raw image bytes (JPEG out). $yt: YouTube 4:3 thumbnails contain a 16:9 picture between black bars
  Add-Type -AssemblyName System.Drawing
  $jpg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  function Convert-SquareArt([byte[]]$bytes, [bool]$yt) {
    $in = New-Object IO.MemoryStream (, $bytes)
    $img = [Drawing.Image]::FromStream($in)
    try {
      $w = $img.Width; $h = $img.Height; $ch = $h
      if ($yt -and ($w / $h) -lt 1.5) { $ch = [math]::Min($h, $w * 9 / 16) }
      $side = [math]::Min($ch, $w); $x0 = ($w - $side) / 2; $y0 = ($h - $side) / 2
      $out = [int][math]::Min(600, $side)
      $bmp = New-Object Drawing.Bitmap $out, $out
      $g = [Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'
      $g.DrawImage($img, (New-Object Drawing.RectangleF 0, 0, $out, $out), (New-Object Drawing.RectangleF ([single]$x0), ([single]$y0), ([single]$side), ([single]$side)), [Drawing.GraphicsUnit]::Pixel)
      $ep = New-Object Drawing.Imaging.EncoderParameters 1
      $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]88)
      $ms = New-Object IO.MemoryStream; $bmp.Save($ms, $jpg, $ep); $g.Dispose(); $bmp.Dispose()
      return , $ms.ToArray()
    } finally { $img.Dispose(); $in.Dispose() }
  }
  # JPEG / PNG / GIF only (old browsers can't show WebP/AVIF, System.Drawing can't read them either)
  function Test-WebImage([byte[]]$b) { return ($b -and $b.Length -gt 4 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xD8) -or ($b[0] -eq 0x89 -and $b[1] -eq 0x50) -or ($b[0] -eq 0x47 -and $b[1] -eq 0x49))) }
  function Get-ArtFromUrl([string]$url) {
    if ($url -match 'ytimg\.com/vi(?:_webp)?/([\w-]{11})/') {
      # YouTube: use the JPEG thumbnails (best available first)
      foreach ($q in 'maxresdefault', 'sddefault', 'hqdefault') {
        try {
          $b = [byte[]](Invoke-WebRequest "https://i.ytimg.com/vi/$($matches[1])/$q.jpg" -UseBasicParsing -TimeoutSec 10).Content
          if (Test-WebImage $b) { return , (Convert-SquareArt $b ($q -ne 'maxresdefault')) }
        } catch {}
      }
      return $null
    }
    $b = [byte[]](Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10).Content
    if (Test-WebImage $b) { return , (Convert-SquareArt $b $false) }
    return $null
  }
  # music site tab title -> @{app; artist; title} (YouTube titles are kept whole: their "A - B" order is unreliable)
  function Get-MediaFromTab([string]$t2) {
    $t2 = $t2 -replace '^\(\d+\)\s*', ''
    $app = $null
    if ($t2 -match '^(.+?) - YouTube Music$') { $app = 'YouTube Music'; $t2 = $matches[1] }
    elseif ($t2 -match '^(.+?) - YouTube$') { $app = 'YouTube'; $t2 = $matches[1] }
    elseif ($t2 -match '^(.+?)\s*[|\-]\s*(Zing MP3|NhacCuaTui|SoundCloud|Spotify)\b') { $app = $matches[2]; $t2 = $matches[1] }
    if (-not $app) { return $null }
    $t2 = Get-CleanTitle $t2
    if ($app -ne 'YouTube' -and $t2 -match '^(.+?) - (.+)$') { return @{ app = $app; artist = $matches[1].Trim(); title = $matches[2].Trim() } }
    return @{ app = $app; artist = ''; title = $t2 }
  }

  # Read the names of ALL browser tabs via UI Automation (window titles only show the active tab).
  # Chromium tab names look like: "<title> - YouTube - Audio playing - Memory usage - 562 MB"
  try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes } catch {}
  $tabCond = $null
  try { $tabCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem) } catch {}
  function Find-BrowserTab {
    if (-not $tabCond) { return $null }
    $playingSite = $null; $playingAny = $null; $pausedSite = $null
    $browsers = @{}
    foreach ($p in (Get-Process msedge, chrome, brave, opera, browser, coccoc, vivaldi -ErrorAction SilentlyContinue)) { $browsers[$p.Id] = $p.ProcessName }
    if ($browsers.Count -eq 0) { return $null }
    $wc = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'Chrome_WidgetWin_1')
    foreach ($win in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $wc)) {
      try {
        if (-not $browsers.ContainsKey($win.Current.ProcessId)) { continue }
        foreach ($tab in $win.FindAll([Windows.Automation.TreeScope]::Descendants, $tabCond)) {
          $n = [string]$tab.Current.Name
          $isPlaying = $n -match '\s+-\s+(Audio playing|Playing audio)\b'
          $n2 = $n -replace '\s+-\s+Memory usage\s+-\s+[\d.,]+\s*[KMG]B\s*$', ''
          $n2 = ($n2 -replace '\s+-\s+(Audio playing|Playing audio|Audio muted|Tab muted|Muted)\b.*$', '').Trim()
          $info = Get-MediaFromTab $n2
          if ($info) {
            if ($isPlaying -and -not $playingSite) { $info.status = 'playing'; $playingSite = $info }
            elseif (-not $isPlaying -and -not $pausedSite) { $info.status = 'paused'; $pausedSite = $info }
          } elseif ($isPlaying -and -not $playingAny) {
            $playingAny = @{ app = $browsers[$win.Current.ProcessId]; artist = ''; title = $n2; status = 'playing' }
          }
        }
      } catch {}
    }
    if ($playingSite) { return $playingSite }
    if ($playingAny) { return $playingAny }
    return $pausedSite
  }

  function Find-ByTitle {
    $paused = $null
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle })) {
      $n = $p.ProcessName.ToLower(); $t = $p.MainWindowTitle
      if ($n -eq 'spotify') {
        if ($t -match '^(.+?) - (.+)$' -and $t -notmatch '^Spotify') { return @{ app = 'Spotify'; artist = $matches[1]; title = $matches[2]; status = 'playing' } }
        $paused = @{ app = 'Spotify'; artist = ''; title = ''; status = 'paused' }
      } elseif ($n -eq 'firefox') {
        # Firefox tabs aren't readable this way; use the active tab title
        $info = Get-MediaFromTab ($t -replace '\s+\p{Pd}\s+Mozilla Firefox\s*$', '')
        if ($info) { $info.status = 'unknown'; return $info }
      } elseif ($n -eq 'vlc' -and $t -match '^(.+?) - VLC media player$') {
        return @{ app = 'VLC'; artist = ''; title = $matches[1]; status = 'unknown' }
      } elseif ($n -eq 'foobar2000' -and $t -match '^(.+?) - (.+?)\s+\[foobar2000\]$') {
        return @{ app = 'foobar2000'; artist = $matches[1]; title = $matches[2]; status = 'playing' }
      }
    }
    return $paused
  }
  function Get-ItunesArt($artist, $title) {
    $q = (($artist + ' ' + $title) -replace '\(.*?\)|\[.*?\]', ' ' -replace '[|/]', ' ' -replace '(?i)\b(official|mv|m/v|lyrics?|video|audio|visualizer|hd|4k)\b', ' ' -replace '\s+', ' ').Trim()
    if ($q.Length -lt 3) { return $null }
    $qw = @((Get-Plain $q).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    # iTunes needs every word to match, so long artist lists fail: also try "<song> <first artist>" and "<song>"
    $tries = @($q)
    if ($q -match '^(.+?) - (.+)$') {
      $a = $matches[1].Trim(); $b = ($matches[2] -split ',|&|\bx\b|\bft\.?|\bfeat\.?', 2)[0].Trim()
      $tries += "$a $b"; $tries += "$b $a"
      if ($a.Length -ge 4) { $tries += $a }
    }
    foreach ($term in ($tries | Select-Object -Unique)) {
      $j = (Invoke-WebRequest ('https://itunes.apple.com/search?entity=song&limit=5&term=' + [Uri]::EscapeDataString($term)) -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
      foreach ($r in $j.results) {
        # accept only if most words of the found track name appear in what is playing (avoid wrong covers)
        $tw = @((Get-Plain ([string]$r.trackName -replace '\(.*?\)|\[.*?\]', ' ')).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
        if ($tw.Count -eq 0) { continue }
        $hit = @($tw | Where-Object { $qw -contains $_ }).Count
        if ($hit / $tw.Count -ge 0.6) {
          $u = ([string]$r.artworkUrl100) -replace '100x100bb', '600x600bb'
          return , [byte[]](Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 10).Content
        }
      }
    }
    return $null
  }
  # lower-case, no Vietnamese diacritics, letters/digits only
  function Get-Plain([string]$s) {
    $d = $s.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $d = $d.Replace([string][char]0x111, 'd').Replace([string][char]0x110, 'D')
    return (($d.ToLower() -replace '[^a-z0-9]+', ' ').Trim())
  }

  $sess = $null; $lastKey = $null; $artId = 0; $last = [DateTime]::MinValue
  while ($media.running) {
    $force = $false
    while ($media.cmds.Count -gt 0) {
      $c = [string]$media.cmds[0]; $media.cmds.RemoveAt(0); $force = $true
      try {
        if ($c -eq 'play' -or $c -eq 'next' -or $c -eq 'prev') {
          $tgt = [string]$media.target
          if ($tgt -and $media.ext.ContainsKey($tgt) -and ([DateTime]::UtcNow - $media.ext[$tgt].ts).TotalSeconds -lt 90) {
            # browser extension executes it inside the tab. Timestamped: commands older than 4 s are dropped,
            # so nothing piles up and fires in a burst later (that used to restart videos)
            [void]$media.extQ.Add("$tgt|$c|" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
          } elseif ($sess) {
            if ($c -eq 'play') { [void](Wait-Op ($sess.TryTogglePlayPauseAsync()) ([bool])) }
            elseif ($c -eq 'next') { [void](Wait-Op ($sess.TrySkipNextAsync()) ([bool])) }
            else { [void](Wait-Op ($sess.TrySkipPreviousAsync()) ([bool])) }
          } else {
            $sp = Get-Process spotify -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($sp -and $lastApp -eq 'Spotify') {
              # Spotify desktop accepts WM_APPCOMMAND directly (works even when global media keys are broken)
              [DeskBuddy.Input]::AppCommand($sp.MainWindowHandle, @{ play = 14; next = 11; prev = 12 }[$c])
            } else {
              [DeskBuddy.Input]::Press([byte]@{ play = 0xB3; next = 0xB0; prev = 0xB1 }[$c])
            }
          }
        }
        elseif ($c -eq 'volup') { [DeskBuddy.Audio]::SetMute($false); [DeskBuddy.Audio]::SetVolume([DeskBuddy.Audio]::GetVolume() + 5) }
        elseif ($c -eq 'voldown') { [DeskBuddy.Audio]::SetVolume([DeskBuddy.Audio]::GetVolume() - 5) }
        elseif ($c -eq 'mute') { [DeskBuddy.Audio]::SetMute(-not [DeskBuddy.Audio]::GetMute()) }
        elseif ($c -match '^vol(\d{1,3})$') { [DeskBuddy.Audio]::SetMute($false); [DeskBuddy.Audio]::SetVolume([int]$matches[1]) }
      } catch {}
    }
    # only poll while someone is looking at the media page (or right after a command)
    if (-not $force -and (([DateTime]::UtcNow - $media.lastWant).TotalSeconds -gt 30 -or ([DateTime]::UtcNow - $last).TotalMilliseconds -lt 1000)) { Start-Sleep -Milliseconds 150; continue }
    if ($force) { Start-Sleep -Milliseconds 350 }   # give the player a moment to react
    $last = [DateTime]::UtcNow
    $info = $null; $thumb = $null; $sess = $null; $artUrl = $null
    # 1) browser extension (exact title / channel / artwork / position): pick the playing tab, else the most recent
    $best = $null
    foreach ($k in @($media.ext.Keys)) {
      $e = $media.ext[$k]
      # hidden + paused tabs are throttled by the browser (report ~1/min): keep them 90 s so they stay controllable
      if (([DateTime]::UtcNow - $e.ts).TotalSeconds -gt 90) { $media.ext.Remove($k); continue }
      if (-not $best -or ($e.s.playing -and -not $best.s.playing) -or ($e.s.playing -eq $best.s.playing -and $e.s.lastPlay -gt $best.s.lastPlay)) { $best = $e }
    }
    if ($best) {
      $sx = $best.s; $media.target = [string]$sx.id; $site = [string]$sx.site
      $app = if ($site -match 'music\.youtube') { 'YouTube Music' } elseif ($site -match 'youtube') { 'YouTube' } elseif ($site -match 'spotify') { 'Spotify' } elseif ($site -match 'soundcloud') { 'SoundCloud' } elseif ($site -match 'zingmp3') { 'Zing MP3' } elseif ($site -match 'nhaccuatui') { 'NhacCuaTui' } else { $site }
      $ttl = Get-CleanTitle (([string]$sx.title) -replace '^\(\d+\)\s*', '' -replace '\s+\p{Pd}\s+(YouTube Music|YouTube|Spotify|SoundCloud)\s*$', '')
      $info = @{ app = $app; artist = [string]$sx.artist; title = $ttl; album = [string]$sx.album
        status = $(if ($sx.playing) { 'playing' } else { 'paused' }); pos = [double]$sx.pos; dur = [double]$sx.dur; at = [long]$best.ms }
      if ([string]$sx.art -match '^https?://') { $artUrl = [string]$sx.art }
    } else { $media.target = '' }
    if (-not $info -and $mgr) {
      try {
        $sess = $mgr.GetCurrentSession()
        if ($sess) {
          $pr = Wait-Op ($sess.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
          $pb = $sess.GetPlaybackInfo(); $tl = $sess.GetTimelineProperties()
          $st = ([string]$pb.PlaybackStatus).ToLower()
          $info = @{ app = ($sess.SourceAppUserModelId -replace '\.exe$', '' -replace '^.*!', ''); artist = [string]$pr.Artist; title = [string]$pr.Title; album = [string]$pr.AlbumTitle
            status = $(if ($st -eq 'playing' -or $st -eq 'paused') { $st } else { 'unknown' })
            pos = $tl.Position.TotalSeconds; dur = $tl.EndTime.TotalSeconds; at = ([DateTimeOffset]$tl.LastUpdatedTime).ToUnixTimeMilliseconds() }
          $thumb = $pr.Thumbnail
        }
      } catch { $sess = $null }
    }
    if (-not $info) {
      $tabInfo = $null; $winInfo = $null
      try { $tabInfo = Find-BrowserTab } catch {}
      try { $winInfo = Find-ByTitle } catch {}
      # something actually playing wins; otherwise a paused/unknown source
      if ($tabInfo -and $tabInfo.status -eq 'playing') { $info = $tabInfo }
      elseif ($winInfo -and $winInfo.status -eq 'playing') { $info = $winInfo }
      elseif ($winInfo -and $winInfo.title) { $info = $winInfo }
      elseif ($tabInfo) { $info = $tabInfo }
      else { $info = $winInfo }
    }

    $vol = -1; $muted = $false
    try { $vol = [DeskBuddy.Audio]::GetVolume(); $muted = [DeskBuddy.Audio]::GetMute() } catch {}

    $key = if ($info) { $info.app + '|' + $info.artist + '|' + $info.title } else { '' }
    if ($key -ne $lastKey) {
      $lastKey = $key; $media.art = $null
      if ($info -and $info.title) {
        try {
          if ($artUrl) {
            $media.art = Get-ArtFromUrl $artUrl
            if (-not $media.art) { $media.art = Get-ItunesArt $info.artist $info.title }
          } elseif ($thumb) {
            $rs = Wait-Op ($thumb.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
            $ns = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($rs); $mm = New-Object IO.MemoryStream; $ns.CopyTo($mm)
            $media.art = $mm.ToArray()
          } else { $media.art = Get-ItunesArt $info.artist $info.title }
        } catch {}
      }
      $artId++
    }
    $o = [ordered]@{ has = [bool]($info -and ($info.title -or $info.status -eq 'paused')); session = [bool]$mgr; vol = $vol; muted = $muted; art = $(if ($media.art) { $artId } else { 0 }) }
    if ($info) { foreach ($k in 'app', 'artist', 'title', 'album', 'status', 'pos', 'dur', 'at') { if ($info.ContainsKey($k)) { $o[$k] = $info[$k] } } }
    $o.bridge = [bool]$best
    $lastApp = if ($info) { $info.app } else { '' }
    $media.json = ConvertTo-Json $o -Compress
  }
}
$mrs = [runspacefactory]::CreateRunspace(); $mrs.Open()
$mps = [powershell]::Create(); $mps.Runspace = $mrs
[void]$mps.AddScript($mediaWorker).AddArgument($media)
$mhandle = $mps.BeginInvoke()


# ---------------------------------------------------------------- VU meter: peak level of the default output (L/R), ~25-30 samples/s
# Only runs while /api/meter was requested in the last 10 s. Samples are queued with a sequence number; the phone polls
# 4x/s and animates them (smooth needles without hammering the single-threaded HTTP server).
$meter = [hashtable]::Synchronized(@{ running = $true; lastWant = [DateTime]::MinValue; seq = 0; buf = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)) })
$meterWorker = {
  param($meter)
  $clock = [Diagnostics.Stopwatch]::StartNew(); $nextAt = 0.0
  while ($meter.running) {
    if (([DateTime]::UtcNow - $meter.lastWant).TotalSeconds -gt 10) { Start-Sleep -Milliseconds 300; $nextAt = $clock.Elapsed.TotalMilliseconds; continue }
    # steady 30 samples/s (Start-Sleep alone drifts to ~22/s because of the 15.6 ms Windows timer)
    $wait = $nextAt - $clock.Elapsed.TotalMilliseconds
    if ($wait -gt 1) { Start-Sleep -Milliseconds ([int]$wait) }
    $nextAt = [math]::Max($nextAt + 33.3, $clock.Elapsed.TotalMilliseconds - 100)
    $p = [DeskBuddy.Audio]::Peaks()
    $l = [math]::Round([double]$p[0], 3); $r = if ($p.Count -gt 1) { [math]::Round([double]$p[1], 3) } else { $l }
    $sp = ''
    try { $sp = [DeskBuddy.Spectrum]::GetEncoded() } catch { $meter.err = $_.ToString() }   # 48 spectrum bands, one char each (0..63)
    $meter.seq++
    [void]$meter.buf.Add(@($meter.seq, $l, $r, $sp))
    while ($meter.buf.Count -gt 120) { $meter.buf.RemoveAt(0) }
  }
}
$vrs1 = [runspacefactory]::CreateRunspace(); $vrs1.Open()
$vps1 = [powershell]::Create(); $vps1.Runspace = $vrs1
[void]$vps1.AddScript($meterWorker).AddArgument($meter)
$vh1 = $vps1.BeginInvoke()

# ---------------------------------------------------------------- animated wallpapers for 09-anime
# pixel    = 8-bit / pixel art GIFs (DeviantArt search RSS, no key; landscape or square only). GIFs freeze on the old
#            phone, so each GIF is turned into a ~10 s H.264 video: frames scaled up nearest-neighbour (crisp pixels)
#            to fill 640x360 (cover, edges cropped a little), each kept for its own GIF delay.
# abstract = free Mixkit loops (abstract / liquid / particles...), landscape clips only.
# Encoded once with Windows' own encoder (WinRT MediaComposition, H.264 Baseline 640x360 = what the phone decodes) and
# cached in %LOCALAPPDATA%\DeskBuddy\videos (pf*.mp4 / bg*.mp4). A kind is only filled while a page asked for it.
$VideoDir = Join-Path $env:LOCALAPPDATA 'DeskBuddy\videos'
$oldDir = Join-Path $env:LOCALAPPDATA 'MiniScreen'   # cache folder from before the rename: move it over
if ((Test-Path $oldDir) -and -not (Test-Path (Join-Path $env:LOCALAPPDATA 'DeskBuddy'))) { try { Move-Item $oldDir (Join-Path $env:LOCALAPPDATA 'DeskBuddy') -ErrorAction Stop } catch {} }
if (-not (Test-Path $VideoDir)) { New-Item -ItemType Directory -Force $VideoDir | Out-Null }
$vid = [hashtable]::Synchronized(@{ running = $true; want = [hashtable]::Synchronized(@{}); err = $null; busy = $false })
$videoWorker = {
  param($vid, $dir)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.Drawing
  $jpg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  # prefer ffmpeg (reliable); fall back to WinRT MediaComposition
  $ffmpeg = $null
  foreach ($p in 'ffmpeg', 'D:\ffmpeg\bin\ffmpeg.exe') { try { $ffmpeg = (Get-Command $p -ErrorAction Stop).Source; break } catch {} }
  $useWinRT = -not $ffmpeg
  if ($useWinRT) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $asOp = ($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $asOpP = ($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperationWithProgress`2' })[0]
    function Wait-Op($op, [Type]$t) { $tk = $asOp.MakeGenericMethod($t).Invoke($null, @($op)); [void]$tk.Wait(120000); $tk.Result }
    function Wait-OpP($op, [Type]$t, [Type]$p) { $tk = $asOpP.MakeGenericMethod($t, $p).Invoke($null, @($op)); [void]$tk.Wait(600000); $tk.Result }
    $tClip = [Windows.Media.Editing.MediaClip, Windows.Media.Editing, ContentType = WindowsRuntime]
    $tProf = [Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
    $tFile = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $tFolder = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
    $addClip = [System.Collections.Generic.ICollection`1].MakeGenericType($tClip).GetMethod('Add')
  }
  function Run-Ff([string[]]$a) {
    $pi = New-Object Diagnostics.ProcessStartInfo $ffmpeg, ($a -join ' ')
    $pi.UseShellExecute = $false; $pi.CreateNoWindow = $true
    $pi.RedirectStandardError = $true; $pi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($pi); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit(600000)
    if ($p.ExitCode -ne 0) { throw "ffmpeg exit $($p.ExitCode): $err" }
  }

  function Save-Composition($comp, [string]$out) {
    $prof = $tProf::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::Vga)
    $prof.Video.Width = 640; $prof.Video.Height = 360; $prof.Video.Bitrate = 700000
    $prof.Video.FrameRate.Numerator = 25; $prof.Video.FrameRate.Denominator = 1
    $prof.Video.ProfileId = 66   # H.264 Baseline
    $prof.Audio = $null
    $folder = Wait-Op ($tFolder::GetFolderFromPathAsync((Split-Path $out))) $tFolder
    $file = Wait-Op ($folder.CreateFileAsync((Split-Path $out -Leaf), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) $tFile
    [void](Wait-OpP ($comp.RenderToFileAsync($file, [Windows.Media.Editing.MediaTrimmingPreference]::Fast, $prof)) ([Windows.Media.Transcoding.TranscodeFailureReason]) ([double]))
  }
  function Convert-Video([string]$src, [string]$out) {
    if ($ffmpeg) {
      # probe dimensions, skip portrait
      $pi = New-Object Diagnostics.ProcessStartInfo $ffmpeg, "-i `"$src`" -hide_banner"
      $pi.UseShellExecute = $false; $pi.CreateNoWindow = $true; $pi.RedirectStandardError = $true; $pi.RedirectStandardOutput = $true
      $p = [Diagnostics.Process]::Start($pi); $info = $p.StandardError.ReadToEnd(); $p.WaitForExit(30000)
      if ($info -match '(\d{2,5})x(\d{2,5})') { $vw = [int]$Matches[1]; $vh = [int]$Matches[2]; if ($vh -gt $vw * 0.75) { throw "skip portrait clip ${vw}x${vh}" } }
      Run-Ff @('-y', '-i', "`"$src`"", '-vf', '"scale=640:360:force_original_aspect_ratio=increase,crop=640:360"', '-c:v', 'libx264', '-profile:v', 'baseline', '-level', '3.0', '-pix_fmt', 'yuv420p', '-preset', 'fast', '-crf', '23', '-an', '-movflags', '+faststart', "`"$out`"")
    } else {
      $clip = Wait-Op ($tClip::CreateFromFileAsync((Wait-Op ($tFile::GetFileFromPathAsync($src)) $tFile))) $tClip
      $vp = $clip.GetVideoEncodingProperties()
      if ($vp -and $vp.Height -gt $vp.Width * 0.75) { throw "skip portrait clip $($vp.Width)x$($vp.Height)" }
      $comp = New-Object Windows.Media.Editing.MediaComposition
      [void]$addClip.Invoke($comp.Clips, @($clip))
      Save-Composition $comp $out
    }
  }
  # GIF -> video: frames scaled to fill 640x360 (nearest-neighbour for crisp pixels), looped ~10 s
  function Convert-Gif([string]$gifPath, [string]$out) {
    $img = [Drawing.Image]::FromFile($gifPath)
    try {
      $fd = New-Object Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
      $n = $img.GetFrameCount($fd)
      if ($n -lt 2) { throw 'not animated' }
      $ar = $img.Width / $img.Height; if ($ar -lt 1.6 -or $ar -gt 1.95) { throw "skip: not 16:9 ($($img.Width)x$($img.Height))" }
    } finally { $img.Dispose() }
    if ($ffmpeg) {
      # get GIF duration to calculate loop count
      $pi = New-Object Diagnostics.ProcessStartInfo $ffmpeg, "-i `"$gifPath`" -hide_banner"
      $pi.UseShellExecute = $false; $pi.CreateNoWindow = $true; $pi.RedirectStandardError = $true; $pi.RedirectStandardOutput = $true
      $p = [Diagnostics.Process]::Start($pi); $info = $p.StandardError.ReadToEnd(); $p.WaitForExit(30000)
      $durMs = 5000
      if ($info -match 'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)') { $durMs = ([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]) * 1000 + [int]$Matches[4] * 10 }
      $loops = [math]::Max(1, [math]::Min(40, [math]::Ceiling(10000 / [math]::Max(1, $durMs))))
      $loopF = if ($loops -gt 1) { "-stream_loop $($loops - 1)" } else { '' }
      # nearest-neighbour scale (crisp pixels), cover-crop to 640x360, H.264 Baseline for old Android
      Run-Ff @('-y', $loopF, '-i', "`"$gifPath`"", '-vf', '"scale=640:360:force_original_aspect_ratio=increase:flags=neighbor,crop=640:360"', '-c:v', 'libx264', '-profile:v', 'baseline', '-level', '3.0', '-pix_fmt', 'yuv420p', '-preset', 'fast', '-crf', '20', '-an', '-movflags', '+faststart', "`"$out`"")
    } else {
      # WinRT path: render each frame as JPEG, compose with MediaComposition
      $img = [Drawing.Image]::FromFile($gifPath)
      $tmp = Join-Path $env:TEMP ('ms-gif-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory $tmp | Out-Null
      try {
        $fd = New-Object Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        $n = $img.GetFrameCount($fd)
        $delays = @(); try { $raw = $img.GetPropertyItem(0x5100).Value } catch { $raw = $null }
        $W = 640; $H = 360; $s = [math]::Max($W / $img.Width, $H / $img.Height)
        $dw = [math]::Round($img.Width * $s); $dh = [math]::Round($img.Height * $s)
        $ep = New-Object Drawing.Imaging.EncoderParameters 1
        $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]92)
        $files = @()
        for ($i = 0; $i -lt $n; $i++) {
          [void]$img.SelectActiveFrame($fd, $i)
          $d = if ($raw -and $raw.Length -ge ($i + 1) * 4) { [BitConverter]::ToInt32($raw, $i * 4) * 10 } else { 100 }
          if ($d -lt 40) { $d = 100 }
          $delays += $d
          $bmp = New-Object Drawing.Bitmap $W, $H
          $g = [Drawing.Graphics]::FromImage($bmp)
          $tiny = New-Object Drawing.Bitmap 24, 14
          $tg = [Drawing.Graphics]::FromImage($tiny); $tg.InterpolationMode = 'HighQualityBilinear'; $tg.DrawImage($img, 0, 0, 24, 14); $tg.Dispose()
          $g.InterpolationMode = 'HighQualityBilinear'; $g.DrawImage($tiny, -40, -40, $W + 80, $H + 80); $tiny.Dispose()
          $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(110, 0, 0, 0))), 0, 0, $W, $H)
          if ($s -ge 1) { $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half' } else { $g.InterpolationMode = 'HighQualityBicubic' }
          $g.DrawImage($img, (New-Object Drawing.RectangleF ([single][math]::Floor(($W - $dw) / 2)), ([single][math]::Floor(($H - $dh) / 2)), ([single]$dw), ([single]$dh)))
          $g.Dispose()
          $f = Join-Path $tmp ('f{0:D4}.jpg' -f $i); $bmp.Save($f, $jpg, $ep); $bmp.Dispose()
          $files += $f
        }
        $img.Dispose(); $img = $null
        $loopMs = ($delays | Measure-Object -Sum).Sum
        $reps = [math]::Max(1, [math]::Min(40, [math]::Ceiling(10000 / [math]::Max(1, $loopMs))))
        $base = @()
        for ($i = 0; $i -lt $n; $i++) {
          $sf = Wait-Op ($tFile::GetFileFromPathAsync($files[$i])) $tFile
          $base += , (Wait-Op ($tClip::CreateFromImageFileAsync($sf, [TimeSpan]::FromMilliseconds($delays[$i]))) $tClip)
        }
        $comp = New-Object Windows.Media.Editing.MediaComposition
        for ($r = 0; $r -lt $reps; $r++) { for ($i = 0; $i -lt $n; $i++) { [void]$addClip.Invoke($comp.Clips, @($(if ($r -eq 0) { $base[$i] } else { $base[$i].Clone() }))) } }
        Save-Composition $comp $out
      } finally {
        if ($img) { $img.Dispose() }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
  function Get-Html($u) { (Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0').Content }
  function Get-Key([string]$s) { $s = ($s -split '\?')[0]; $md5 = [Security.Cryptography.MD5]::Create(); (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }) -join '') }

  # old cache formats: remove
  Get-ChildItem $dir -Filter 'mk*.mp4' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  foreach ($old in 'an', 'px', 'pw') {   # old anime set, pixel sets before the 16:9 / full-screen rules
    Get-ChildItem $dir -Filter "$old*.mp4" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }
  $skip = @{}
  $TARGET = @{ pixel = 24; abstract = 8 }
  $notBefore = @{}   # kind -> UTC time: after a round that added nothing, wait (DeviantArt answers 403 to bursts)
  while ($vid.running) {
    $did = $false
    foreach ($kind in 'pixel', 'abstract') {
      $w = $vid.want[$kind]
      if (-not $w -or ([DateTime]::UtcNow - $w).TotalMinutes -gt 30) { continue }
      if ($notBefore[$kind] -and [DateTime]::UtcNow -lt $notBefore[$kind]) { continue }
      $prefix = if ($kind -eq 'pixel') { 'pf' } else { 'bg' }
      $have = @(Get-ChildItem $dir -Filter "$prefix*.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 30KB })
      if ($have.Count -ge $TARGET[$kind]) { continue }
      $vid.busy = $true; $did = $true; $before = $have.Count
      $haveKeys = @($have | ForEach-Object { $_.BaseName.Substring(2) })
      try {
        $cand = @()   # urls
        if ($kind -eq 'pixel') {
          # the signed token in the url changes per request: dedupe / key on the path (Get-Key strips the query)
          # 16:9-ish only (fills the 640x360 screen, no side bars)
          $qs = @('pixel scene gif', 'pixel art animation', 'pixel art gif', 'pixel art wallpaper gif', 'pixel art city animated', 'pixel art landscape animated', '8bit animation') | Get-Random -Count 4
          foreach ($q in $qs) {
            try {
              $rss = Get-Html ('https://backend.deviantart.com/rss.xml?type=deviation&q=' + [uri]::EscapeDataString($q) + '&offset=' + (60 * (Get-Random -Maximum 3)))
              foreach ($mm in [regex]::Matches($rss, '<media:content url="([^"]+)" height="(\d+)" width="(\d+)" medium="image"')) {
                $u = $mm.Groups[1].Value -replace '&amp;', '&'; $h = [double]$mm.Groups[2].Value; $wd = [double]$mm.Groups[3].Value
                if (($u -split '\?')[0] -match '\.gif$' -and $wd -ge 160 -and $h -gt 0 -and ($wd / $h) -ge 1.65 -and ($wd / $h) -le 1.9) { $cand += $u }
              }
            } catch {}
            Start-Sleep -Seconds 2
          }
        } else {
          foreach ($cat in 'abstract', 'liquid', 'particles', 'neon', 'space', 'galaxy') {
            try { $cand += @([regex]::Matches((Get-Html "https://mixkit.co/free-stock-video/$cat/"), 'https://assets\.mixkit\.co/[^"''\s]+?-360\.mp4') | ForEach-Object { $_.Value }) } catch {}
          }
        }
        $todo = @($cand | Select-Object -Unique | Where-Object { $_ -and ($haveKeys -notcontains (Get-Key $_)) -and -not $skip.ContainsKey((Get-Key $_)) })
        foreach ($u in ($todo | Get-Random -Count ([math]::Min($TARGET[$kind] - $have.Count, $todo.Count)))) {
          if (-not $vid.running) { break }
          $key = Get-Key $u; $out = Join-Path $dir "$prefix$key.mp4"
          $src = Join-Path $env:TEMP ("ms-src-$key" + [IO.Path]::GetExtension(($u -split '\?')[0]))
          try {
            Invoke-WebRequest $u -OutFile $src -UseBasicParsing -TimeoutSec 60 -UserAgent 'DeskBuddy/1.0 (personal dashboard)'
            if ($kind -eq 'pixel') { if ((Get-Item $src).Length -gt 8MB) { throw 'skip: gif too big' }; Convert-Gif $src $out } else { Convert-Video $src $out }
          } catch {
            if (Test-Path $out) { Remove-Item $out -ErrorAction SilentlyContinue }
            if ($_.ToString() -match 'skip|not animated') { $skip[$key] = 1 } else { $vid.err = "$kind $key : " + $_.ToString() }
          }
          Remove-Item $src -ErrorAction SilentlyContinue
        }
      } catch { $vid.err = "$kind : " + $_.ToString() }
      $now = @(Get-ChildItem $dir -Filter "$prefix*.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 30KB }).Count
      if ($now -le $before) { $notBefore[$kind] = [DateTime]::UtcNow.AddMinutes(15) }   # nothing new: try later
    }
    $vid.busy = $false
    Start-Sleep -Seconds $(if ($did) { 3 } else { 5 })
  }
}
$vrs2 = [runspacefactory]::CreateRunspace(); $vrs2.ApartmentState = 'STA'; $vrs2.Open()
$vps2 = [powershell]::Create(); $vps2.Runspace = $vrs2
[void]$vps2.AddScript($videoWorker).AddArgument($vid).AddArgument($VideoDir)
$vh2 = $vps2.BeginInvoke()

# serve a file with HTTP Range support (Android's media player asks for byte ranges)
# The body is written on a thread-pool thread (DeskBuddy.BgSend) and the connection is closed there: Android's player
# asks for "bytes=N-" (rest of the file) but stops reading once its buffer is full, so a blocking write would stall
# our single request loop for seconds and the player's next range request would wait -> video freezes every few s.
Add-Type -TypeDefinition @'
using System; using System.Threading; using System.Net.Sockets;
namespace DeskBuddy {
  public static class BgSend {
    public static void Start(TcpClient c, byte[] head, byte[] body) {
      ThreadPool.QueueUserWorkItem(delegate {
        try { c.SendTimeout = 30000; NetworkStream s = c.GetStream(); s.Write(head, 0, head.Length); if (body.Length > 0) s.Write(body, 0, body.Length); s.Flush(); }
        catch { }
        finally { try { c.Close(); } catch { } }
      });
    }
  }
}
'@
function Send-FileRange($client, [string]$file, [string]$type, [string]$range) {
  $fs = [IO.File]::OpenRead($file)
  try {
    $len = $fs.Length; $a = 0; $z = $len - 1; $code = 200; $extra = ''
    if ($range -match 'bytes=(\d*)-(\d*)') {
      if ($matches[1]) { $a = [long]$matches[1] }
      if ($matches[2]) { $z = [math]::Min([long]$matches[2], $len - 1) }
      $code = 206; $extra = "Content-Range: bytes $a-$z/$len`r`n"
    }
    $part = New-Object byte[] ([math]::Max(0, $z - $a + 1))
    [void]$fs.Seek($a, 'Begin'); $got = 0
    while ($got -lt $part.Length) { $n = $fs.Read($part, $got, $part.Length - $got); if ($n -le 0) { break }; $got += $n }
  } finally { $fs.Dispose() }
  $reason = if ($code -eq 206) { 'Partial Content' } else { 'OK' }
  $hdr = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($part.Length)`r`nAccept-Ranges: bytes`r`n$($extra)Cache-Control: no-store`r`nConnection: close`r`n`r`n"
  [DeskBuddy.BgSend]::Start($client, [Text.Encoding]::ASCII.GetBytes($hdr), $part)
  $script:handedOff = $true   # the request loop must not close this client
}

$state = [hashtable]::Synchronized(@{ json = '{}'; running = $true; err = $null; ms = 0; lastWant = [DateTime]::UtcNow })

# ---------------------------------------------------------------- sampler
$sampler = {
  param($state, $IntervalMs)
  $ErrorActionPreference = 'Stop'
  $cs = New-CimSession
  $nCpu = [Environment]::ProcessorCount

  $p0 = Get-CimInstance -CimSession $cs Win32_Processor | Select-Object -First 1
  $cpuName = (($p0.Name -replace '\(R\)|\(TM\)|CPU|@.*$|Intel|AMD|Core|Processor', '') -replace '\s+', ' ').Trim()
  $baseMhz = [double]$p0.MaxClockSpeed
  $osName = ((Get-CimInstance -CimSession $cs Win32_OperatingSystem).Caption -replace 'Microsoft ', '').Trim()
  $gpuName = ((Get-CimInstance -CimSession $cs Win32_VideoController | ForEach-Object {
        (($_.Name -replace '\(R\)|\(TM\)|Intel|NVIDIA|GeForce|AMD|Radeon\(TM\)|Graphics', '') -replace '\s+', ' ').Trim()
      }) -join ' + ')

  $prevProc = @{}
  $prevT = $null
  $iter = 0
  $slow = @{ drives = @(); bat = $null; ip = ''; iface = ''; ssid = '' }

  while ($state.running) {
    # nobody asked for stats in the last minute (phone screen off / other page): don't hammer WMI
    if (([DateTime]::UtcNow - $state.lastWant).TotalSeconds -gt 60) { Start-Sleep -Milliseconds 500; continue }
    $t0 = [DateTime]::UtcNow
    try {
      # ---- slow-changing info (every ~30s)
      if (($iter % 15) -eq 0) {
        $slow.drives = @(Get-CimInstance -CimSession $cs Win32_LogicalDisk -Filter 'DriveType=3' -Property DeviceID, Size, FreeSpace |
          Where-Object { $_.Size -gt 0 } | Sort-Object DeviceID | ForEach-Object {
            [ordered]@{ id = $_.DeviceID; size = [double]$_.Size; free = [double]$_.FreeSpace }
          })
        $b = Get-CimInstance -CimSession $cs Win32_Battery | Select-Object -First 1
        if ($b) { $slow.bat = [ordered]@{ pct = [int]$b.EstimatedChargeRemaining; ac = ($b.BatteryStatus -ne 1) } } else { $slow.bat = $null }
        try {
          $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
          if ($route) {
            $slow.iface = $route.InterfaceAlias
            $slow.ip = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress
          }
        } catch {}
        try {
          $ssidLine = netsh wlan show interfaces | Where-Object { $_ -match '^\s*SSID\s*:' } | Select-Object -First 1
          if ($ssidLine) { $slow.ssid = ($ssidLine -replace '^\s*SSID\s*:\s*', '').Trim() } else { $slow.ssid = '' }
        } catch {}
      }
      $iter++

      $d = [ordered]@{}
      $d.t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $d.tz = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes
      $d.host = $env:COMPUTERNAME
      $d.os = $osName
      $d.ip = $slow.ip
      $d.iface = $slow.iface
      $d.ssid = $slow.ssid
      $d.bat = $slow.bat

      # ---- CPU
      $pi = @(Get-CimInstance -CimSession $cs Win32_PerfFormattedData_Counters_ProcessorInformation -Property Name, PercentProcessorTime, PercentProcessorPerformance)
      $tot = $pi | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
      $cores = @($pi | Where-Object { $_.Name -notlike '*_Total*' } |
        Sort-Object { $x = $_.Name -split ','; [int]$x[0] * 1000 + [int]$x[1] } |
        ForEach-Object { [int]$_.PercentProcessorTime })
      $temp = $null
      try {
        $tz = @(Get-CimInstance -CimSession $cs -Namespace root/wmi MSAcpi_ThermalZoneTemperature)
        if ($tz.Count -gt 0) {
          $temp = [math]::Round((($tz | Measure-Object CurrentTemperature -Maximum).Maximum) / 10 - 273.15)
          if ($temp -le 0 -or $temp -gt 125) { $temp = $null }
        }
      } catch {}
      $d.cpu = [ordered]@{
        load  = [int]$tot.PercentProcessorTime
        cores = $cores
        ghz   = [math]::Round($baseMhz * [double]$tot.PercentProcessorPerformance / 100 / 1000, 2)
        name  = $cpuName
        temp  = $temp
      }

      # ---- RAM
      $os = Get-CimInstance -CimSession $cs Win32_OperatingSystem -Property FreePhysicalMemory, TotalVisibleMemorySize, LastBootUpTime
      $mem = Get-CimInstance -CimSession $cs Win32_PerfFormattedData_PerfOS_Memory -Property CommittedBytes, CommitLimit
      $total = [double]$os.TotalVisibleMemorySize * 1024
      $free = [double]$os.FreePhysicalMemory * 1024
      $d.ram = [ordered]@{
        total       = $total
        used        = $total - $free
        free        = $free
        commit      = [double]$mem.CommittedBytes
        commitLimit = [double]$mem.CommitLimit
      }
      $d.uptime = [int]([DateTime]::Now - $os.LastBootUpTime).TotalSeconds

      # ---- GPU (max utilisation per engine type across adapters)
      $g = @{}
      $ge = @(Get-CimInstance -CimSession $cs Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Property Name, UtilizationPercentage)
      $acc = @{}
      foreach ($e in $ge) {
        if ($e.Name -match 'luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+).*engtype_(.+)$') {
          $k = $matches[1] + '|' + ($matches[2] -replace '\s', '')
          $acc[$k] = [double]$acc[$k] + [double]$e.UtilizationPercentage
        }
      }
      foreach ($k in $acc.Keys) {
        $type = $k.Split('|')[1]
        $v = [math]::Min(100, $acc[$k])
        if ($v -gt [double]$g[$type]) { $g[$type] = $v }
      }
      $gm = 0.0
      try {
        Get-CimInstance -CimSession $cs Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -Property DedicatedUsage, SharedUsage |
          ForEach-Object { $gm += [double]$_.DedicatedUsage + [double]$_.SharedUsage }
      } catch {}
      $d.gpu = [ordered]@{
        load   = [int][double]$g['3D']
        decode = [int][double]$g['VideoDecode']
        copy   = [int][double]$g['Copy']
        mem    = $gm
        name   = $gpuName
      }

      # ---- Network
      $down = 0.0; $up = 0.0
      Get-CimInstance -CimSession $cs Win32_PerfFormattedData_Tcpip_NetworkInterface -Property BytesReceivedPersec, BytesSentPersec |
        ForEach-Object { $down += [double]$_.BytesReceivedPersec; $up += [double]$_.BytesSentPersec }
      $d.net = [ordered]@{ down = $down; up = $up }

      # ---- Disk
      $pd = Get-CimInstance -CimSession $cs Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -Property PercentDiskTime, DiskReadBytesPersec, DiskWriteBytesPersec
      $d.disk = [ordered]@{
        busy   = [int][math]::Min(100, [double]$pd.PercentDiskTime)
        read   = [double]$pd.DiskReadBytesPersec
        write  = [double]$pd.DiskWriteBytesPersec
        drives = $slow.drives
      }

      # ---- Top processes (CPU delta between samples, grouped by name)
      $now = [DateTime]::UtcNow
      $cur = @{}; $agg = @{}
      $all = [Diagnostics.Process]::GetProcesses()
      foreach ($p in $all) {
        if ($p.Id -eq 0) { continue }
        try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch { continue }
        $cur[$p.Id] = $ms
        if ($prevT -and $prevProc.ContainsKey($p.Id)) {
          $n = $p.ProcessName
          if (-not $agg.ContainsKey($n)) { $agg[$n] = @(0.0, 0.0) }
          $agg[$n][0] += [math]::Max(0, $ms - $prevProc[$p.Id])
          $agg[$n][1] += [double]$p.WorkingSet64
        }
      }
      $top = @()
      if ($prevT) {
        $elapsed = ($now - $prevT).TotalMilliseconds * $nCpu
        $top = @($agg.GetEnumerator() | Sort-Object { $_.Value[0] } -Descending | Select-Object -First 5 | ForEach-Object {
            [ordered]@{ n = $_.Key; c = [math]::Round($_.Value[0] / $elapsed * 100, 1); m = $_.Value[1] }
          })
      }
      $prevProc = $cur; $prevT = $now
      $d.procs = $all.Count
      $d.top = $top

      $state.json = ($d | ConvertTo-Json -Depth 5 -Compress)
      $state.err = $null
    } catch {
      $state.err = $_.ToString()
    }
    $el = ([DateTime]::UtcNow - $t0).TotalMilliseconds
    $state.ms = [int]$el
    $wait = [int]($IntervalMs - $el)
    if ($wait -gt 50) { Start-Sleep -Milliseconds $wait }
  }
}

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript($sampler).AddArgument($state).AddArgument($IntervalMs)
$handle = $ps.BeginInvoke()

# ---------------------------------------------------------------- http
function Send-Response($stream, [int]$code, [string]$type, [byte[]]$body, [string]$extra = '') {
  $reason = @{ 200 = 'OK'; 206 = 'Partial Content'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Server Error' }[$code]
  $hdr = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n$extra`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch {
  Write-Host "Khong mo duoc port $Port : $($_.Exception.Message)" -ForegroundColor Red
  $state.running = $false; $ext.running = $false; $media.running = $false; $meter.running = $false; $vid.running = $false
  $ps.Stop(); $fps.Stop(); $mps.Stop(); $vps1.Stop(); $vps2.Stop(); exit 1
}

Write-Host ''
Write-Host '  DESK-BUDDY dang chay' -ForegroundColor Cyan
Write-Host "  May nay : http://localhost:$Port"
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  ForEach-Object { Write-Host "  LAN     : http://$($_.IPAddress):$Port   ($($_.InterfaceAlias))" -ForegroundColor Green }
Write-Host '  Mo truc tiep trang khac: http://<ip>:' -NoNewline; Write-Host "$Port/<ten-file>.html  (vd /02-weather.html)"
Write-Host '  Ctrl+C de dung.'
Write-Host ''

$empty = New-Object byte[] 0
# Browsers (Chrome, the old Android one) open speculative sockets that send nothing for a while. Waiting on such a
# socket used to block the single request loop for 600 ms -> /api/meter replies came late and the wave froze.
# Now accepted sockets wait in $pending; we serve whichever has a request first and drop idle ones after 10 s.
$pending = New-Object Collections.ArrayList
try {
  while ($true) {
    # Socket.Select sleeps until the listener has a new connection or a pending socket has data / closed
    # (no busy-polling; wakes at least every 500 ms so Ctrl+C still works)
    $rd = New-Object Collections.ArrayList
    [void]$rd.Add($listener.Server)
    foreach ($e in $pending) { [void]$rd.Add($e[0].Client) }
    try { [Net.Sockets.Socket]::Select($rd, $null, $null, 500000) } catch { }
    if ($rd.Contains($listener.Server)) { [void]$pending.Add(@($listener.AcceptTcpClient(), [DateTime]::UtcNow)) }
    $client = $null
    for ($pi = 0; $pi -lt $pending.Count; $pi++) {
      $pc = $pending[$pi][0]
      $gone = $false; try { $gone = ($pc.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $pc.Available -eq 0) } catch { $gone = $true }
      if ($pc.Available -gt 0) { $client = $pc; $pending.RemoveAt($pi); break }
      if ($gone -or ([DateTime]::UtcNow - $pending[$pi][1]).TotalSeconds -gt 10) { try { $pc.Close() } catch {}; $pending.RemoveAt($pi); $pi-- }
    }
    if (-not $client) { continue }
    $script:handedOff = $false
    try {
      $client.ReceiveTimeout = 1500
      $client.SendTimeout = 3000
      $s = $client.GetStream()
      $reader = New-Object IO.StreamReader($s, [Text.Encoding]::ASCII, $false, 4096, $true)
      $line = $reader.ReadLine()
      $range = ''
      while ($true) { $h = $reader.ReadLine(); if ($null -eq $h -or $h -eq '') { break }; if ($h -match '^Range:\s*(.+)$') { $range = $matches[1] } }
      $path = '/'; $query = ''; $method = 'GET'
      if ($line -match '^(\w+)\s+(\S+)') {
        $method = $matches[1].ToUpper()
        $target = $matches[2]; $qi = $target.IndexOf('?')
        if ($qi -ge 0) { $path = $target.Substring(0, $qi); $query = $target.Substring($qi + 1) } else { $path = $target }
      }
      switch ($path) {
        '/api/stats' {
          $state.lastWant = [DateTime]::UtcNow
          Send-Response $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($state.json))
        }
        '/api/ext' {
          $ext.lastWant = [DateTime]::UtcNow
          $body = if ($ext.json -eq '{}') { '{"t":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}' } else { '{"t":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ',' + $ext.json }
          Send-Response $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($body))
        }
        '/api/media' {
          $media.lastWant = [DateTime]::UtcNow
          $mj = '{"t":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ',' + $media.json.Substring(1)
          Send-Response $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($mj))
        }
        '/api/pages' {
          # page list for the on-screen switcher (long-press)
          $items = @(Get-ChildItem $PagesDir -Filter *.html | Sort-Object Name | ForEach-Object { [ordered]@{ file = $_.Name; desc = (Get-PageDesc $_.FullName) } })
          $pj = ConvertTo-Json @{ current = (Split-Path $PagePath -Leaf); pages = $items } -Depth 3 -Compress
          Send-Response $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($pj))
        }
        '/api/page' {
          # switch the page served at "/" (and remember it for the next start)
          $ok = $false
          if ($method -eq 'POST' -and $query -match '(?:^|&)p=([\w-]+\.html)(?:&|$)') {
            $np = Join-Path $PagesDir $matches[1]
            if (Test-Path $np) { $PagePath = $np; Set-Content -Path $lastFile -Value $matches[1] -Encoding ASCII; $ok = $true }
          }
          Send-Response $s $(if ($ok) { 200 } else { 400 }) 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":' + $ok.ToString().ToLower() + '}'))
        }
        '/api/ext-media' {
          # browser extension bridge: state in, queued commands out. Only accepted from this PC.
          $body = '{"cmds":[]}'
          $isLocal = [Net.IPAddress]::IsLoopback($client.Client.RemoteEndPoint.Address)
          if ($method -eq 'POST' -and $isLocal -and $query -match '(?:^|&)d=([^&]*)') {
            try {
              $st = [Uri]::UnescapeDataString($matches[1]) | ConvertFrom-Json
              $id = [string]$st.id
              if ($id -match '^[a-z0-9]{1,20}$') {
                $media.ext[$id] = @{ s = $st; ts = [DateTime]::UtcNow; ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                $mine = @(); $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                foreach ($q in @($media.extQ)) {
                  $qp = $q.Split('|')
                  if ($nowMs - [long]$qp[2] -gt 4000) { $media.extQ.Remove($q); continue }   # stale: drop
                  if ($qp[0] -eq $id) { $mine += $qp[1]; $media.extQ.Remove($q) }
                }
                $body = '{"cmds":[' + (($mine | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']}'
              }
            } catch {}
          }
          Send-Response $s 200 'application/json' ([Text.Encoding]::UTF8.GetBytes($body))
        }
        '/api/ext-cmd' {
          # polled by the extension's background worker (not throttled like hidden tabs): fresh commands with their tab id
          $out = @()
          if ([Net.IPAddress]::IsLoopback($client.Client.RemoteEndPoint.Address)) {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            foreach ($q in @($media.extQ)) {
              $qp = $q.Split('|'); $media.extQ.Remove($q)
              if ($nowMs - [long]$qp[2] -le 4000) { $out += ('{"id":"' + $qp[0] + '","c":"' + $qp[1] + '"}') }
            }
          }
          Send-Response $s 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"cmds":[' + ($out -join ',') + ']}'))
        }
        '/api/media/art' {
          $ab = $media.art
          if ($ab) { Send-Response $s 200 $(if ($ab[0] -eq 0x89) { 'image/png' } else { 'image/jpeg' }) $ab } else { Send-Response $s 404 'text/plain' $empty }
        }
        '/api/media/cmd' {
          $ok = $false
          if ($method -eq 'POST' -and $query -match '(?:^|&)c=(play|next|prev|volup|voldown|mute|vol\d{1,3})(?:&|$)') { [void]$media.cmds.Add($matches[1]); $ok = $true }
          Send-Response $s $(if ($ok) { 200 } else { 400 }) 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":' + $ok.ToString().ToLower() + '}'))
        }
        '/api/meter' {
          # VU meter samples newer than ?since=<seq>: {"seq":N,"s":[[l,r],...]}
          $meter.lastWant = [DateTime]::UtcNow
          $since = 0; if ($query -match '(?:^|&)since=(\d+)') { $since = [long]$matches[1] }
          $parts = @(); foreach ($e in @($meter.buf)) { if ($e[0] -gt $since) { $parts += ('[' + $e[1] + ',' + $e[2] + ',"' + $e[3] + '"]') } }
          if ($parts.Count -gt 60) { $parts = $parts[-60..-1] }
          Send-Response $s 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"seq":' + $meter.seq + ',"s":[' + ($parts -join ',') + ']}'))
        }
        '/api/videos' {
          # ?src=pixel (default) | abstract | all
          $src = 'pixel'; if ($query -match '(?:^|&)src=(pixel|abstract|all)') { $src = $matches[1] }
          $kinds = if ($src -eq 'all') { @('pixel', 'abstract') } else { @($src) }
          $names = @()
          foreach ($k in $kinds) {
            $vid.want[$k] = [DateTime]::UtcNow
            $px = if ($k -eq 'pixel') { 'pf' } else { 'bg' }
            $names += @(Get-ChildItem $VideoDir -Filter "$px*.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 30KB } | ForEach-Object { '"' + $_.Name + '"' })
          }
          Send-Response $s 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"busy":' + ([string]$vid.busy).ToLower() + ',"items":[' + ($names -join ',') + ']}'))
        }
        '/bgvideo' {
          $n = ''; if ($query -match '(?:^|&)n=((?:pf|bg)[0-9a-f]+\.mp4)(?:&|$)') { $n = $matches[1] }
          $f = if ($n) { Join-Path $VideoDir $n } else { '' }
          if ($f -and (Test-Path $f)) { Send-FileRange $client $f 'video/mp4' $range } else { Send-Response $s 404 'text/plain' $empty }
        }
        '/api/debug' {
          $dbg = @{ err = $state.err; sampleMs = $state.ms; ext = $ext.err; media = $media.err; video = $vid.err; meter = $meter.err } | ConvertTo-Json -Compress
          Send-Response $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($dbg))
        }
        '/' {
          Send-Response $s 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($PagePath))
        }
        { $_ -match '^/[\w-]+\.mp4$' } {
          # keep-awake video for the phone. Android's media player asks for byte ranges, so support Range.
          $f = Join-Path $PagesDir $_.TrimStart('/')
          if (Test-Path $f) { Send-FileRange $client $f 'video/mp4' $range } else { Send-Response $s 404 'text/plain' $empty }
        }
        { $_ -match '^/[\w-]+\.(html|js|css)$' } {
          $f = Join-Path $PagesDir $_.TrimStart('/')
          $types = @{ html = 'text/html; charset=utf-8'; js = 'application/javascript; charset=utf-8'; css = 'text/css; charset=utf-8' }
          $extName = [IO.Path]::GetExtension($f).TrimStart('.')
          if (Test-Path $f) { Send-Response $s 200 $types[$extName] ([IO.File]::ReadAllBytes($f)) }
          else { Send-Response $s 404 'text/plain' $empty }
        }
        default { Send-Response $s 404 'text/plain' $empty }
      }
    } catch {
    } finally {
      if (-not $script:handedOff) { $client.Close() }
    }
  }
} finally {
  $state.running = $false; $ext.running = $false; $media.running = $false; $meter.running = $false; $vid.running = $false
  $listener.Stop()
  $vps1.Stop(); $vps1.Dispose(); $vrs1.Close()
  $vps2.Stop(); $vps2.Dispose(); $vrs2.Close()
  $mps.Stop(); $mps.Dispose(); $mrs.Close()
  $ps.Stop(); $ps.Dispose(); $rs.Close()
  $fps.Stop(); $fps.Dispose(); $frs.Close()
}
