# Desk-Buddy

Give your old phone a second life as a desk companion.

Desk-Buddy turns an old Android phone into a second screen for your desk. It shows PC stats, weather, exchange rates,
what's playing, a live audio visualizer and animated pixel art. The PC side is a single PowerShell script with nothing
to install. The phone side is a browser.

It was built for a **Samsung Galaxy S2 HD** (Android 4.1.2, stock browser, 640×360 CSS px), so every page runs on
very old browsers: plain ES5, XHR, no CSS variables, no flex or grid. It also works in any modern browser.

## Pages

| Page | What it shows |
|---|---|
| **System** | CPU per core, temperature and clock, RAM, GPU, network, disks, top processes |
| **Weather** | Current conditions, next 24 hours, 7 days, AQI and UV (Open-Meteo) |
| **Finance** | Vietcombank exchange rates and Binance crypto with 48-hour charts |
| **Calendar** | Big clock, lunar calendar (Can Chi), month view, countdowns to Tết and holidays, a heart on a monthly anniversary day |
| **Home** | A bit of everything: weather, rates, crypto, CPU, RAM, GPU, network |
| **Now playing** | Song playing on the PC: cover art, progress, play/pause, next/previous, volume |
| **Wave** | Mirrored LED-style spectrum that follows the PC's real audio output (WASAPI loopback + FFT), with a slowly drifting colour |
| **8-bit** | Full-screen animated pixel art. GIFs are converted to H.264 video so the old phone plays them smoothly. Each one stays about 15 minutes; tap to skip |

## Requirements

- A Windows 10 or 11 PC. It uses the built-in Windows PowerShell 5.1, nothing else.
- A phone or tablet with a browser on the same Wi-Fi.
- Optional: Microsoft Edge with the bundled extension, to control music in the browser.

## Quick start

1. Download or clone this repo onto the PC.
2. Double-click **`start.bat`**. The window shows the address, for example `http://192.168.1.10:8080`.
3. Open that address on the phone.
4. To switch pages, **hold the screen for 0.7 s** or **double-tap** an empty area. The server remembers the last page.

To run it in the background at every Windows sign-in, double-click **`tu-khoi-dong.bat`**. Double-click it again to
turn autostart off and stop the server.

If the phone cannot connect, allow the port through the firewall (run as administrator):

```
netsh advfirewall firewall add rule name="Desk-Buddy" dir=in action=allow protocol=TCP localport=8080 profile=private
```

## Options

Server: `server.ps1 [-Port 8080] [-Page 02-weather.html] [-NoMenu]`

URL parameters on the phone:

| Parameter | Effect |
|---|---|
| `/03-finance.html` | Open a page directly |
| `?lite=1` / `?lite=0` | Force light mode on or off. Light mode is used automatically on Android 4 and older |
| `?rotate=0` | Do not auto-rotate when the phone is held upright |
| `?nosleep=0` | Do not keep the screen awake |
| `?hue=190` | Wave page: keep a single colour |
| `?src=abstract` / `?src=all` | 8-bit page: abstract video loops instead of, or as well as, pixel art |

`config.json`:

```jsonc
{
  "city": "auto",                          // "auto" guesses from your IP, or a city name: "Hanoi", "Da Nang"
  "crypto": ["BTC", "ETH", "BNB", "SOL"],  // Binance USDT pairs (the first 4 are shown)
  "currencies": ["EUR", "JPY", "CNY", "KRW", "GBP", "AUD", "SGD", "THB"]
}
```

Restart the server after editing `server.ps1` or `config.json`. Pages in `pages/` are read on every request, so just
reload the page.

## Music control (Edge extension)

The **Now playing** page can read and control YouTube, YouTube Music, Spotify Web, SoundCloud, Zing MP3 and
NhacCuaTui playing in Edge:

1. Open `edge://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose the `extension` folder.
3. Reload the music tab.

Without the extension, the song title is still guessed from the window or tab title, but there is no control and no
progress bar. The desktop Spotify app and the system volume work either way.

## How it works

- `server.ps1` is a small single-threaded HTTP server on `TcpListener`, plus background runspaces for system stats,
  web data, media, the audio meter and video conversion. They only run while a page is asking for them.
- Native bits such as Core Audio, WASAPI loopback, FFT and background socket sends are C# compiled at startup with
  `Add-Type`.
- Pixel-art GIFs come from DeviantArt RSS search. They are upscaled nearest-neighbour to 640×360 and encoded to H.264
  Baseline with the WinRT `MediaComposition` API, then cached in `%LOCALAPPDATA%\DeskBuddy\videos`.
- Old browsers have no Wake Lock API, so a tiny looping black video keeps the phone screen on.
- Layout is `position:absolute` plus `rem` on a fixed 64×36 rem frame, scaled to fit any screen.

Debug info for every data source: `http://<pc-ip>:8080/api/debug`.

## Limitations

- IP geolocation is often wrong in Vietnam, so set `"city"` in that case.
- The server is single-threaded, which is fine for one or two devices.
- Anyone on the LAN can change the music and volume.
