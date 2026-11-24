# Desk-Buddy

Dashboard cho điện thoại cũ **Samsung Galaxy S2 HD** (Android 4.1.2, trình duyệt Samsung, 1280×720 = 640×360 CSS px)
dùng làm màn hình phụ để bàn. PC Windows chạy `server.ps1` (PowerShell 5.1, không cần cài gì). Điện thoại cùng mạng
LAN mở `http://<ip-PC>:8080`.

> File này vừa là hướng dẫn cho người dùng, vừa là ghi chú cho Claude Code (tự đọc khi mở dự án).
> Người dùng nhắn tiếng Việt kiểu thân mật: trả lời tiếng Việt. Thích làm nhanh, gọn, không thừa. Tính năng lớn thì đưa ý
> tưởng cho chọn trước.

## Các file

| File | Vai trò |
|---|---|
| `server.ps1` | Toàn bộ server: web server, đo thông số máy, lấy dữ liệu Internet, kho ảnh, nhạc, âm lượng (C# nhúng sẵn) |
| `config.json` | Cấu hình (xem dưới) |
| `README.md` | Giới thiệu tiếng Anh cho GitHub (sửa tính năng thì cập nhật cả file này) |
| `start.bat` | Chạy server có cửa sổ, mở thẳng trang lần trước (không hỏi; đổi trang trên điện thoại) |
| `tu-khoi-dong.bat` | Bấm lần 1: chạy ngầm ngay + tự chạy mỗi lần đăng nhập Windows. Bấm lần 2: tắt tự khởi động + dừng server |
| `pages/` | Các trang (HTML/JS/CSS tĩnh, đọc lại mỗi request: sửa xong chỉ cần tải lại trang trên điện thoại) |
| `extension/` | Extension Edge để điều khiển nhạc (xem dưới) |
| `last-page.txt` | Server tự ghi: trang đang chọn |

Sửa `server.ps1` / `config.json` thì phải khởi động lại server. Tham số: `server.ps1 [-Port 8080] [-Page 02-weather.html] [-NoMenu]`.

## Dùng trên điện thoại

- **Giữ màn hình 0.7 giây** hoặc **chạm 2 lần** vào chỗ trống: bảng chọn trang. Server nhớ trang đã chọn (`/` luôn mở trang đó).
- URL: `/03-finance.html` mở thẳng một trang · `?lite=1|0` ép chế độ nhẹ · `?rotate=0` không tự xoay khi cầm dọc ·
  `?nosleep=0` tắt chức năng giữ màn hình sáng.
- **Giữ màn hình sáng:** trình duyệt cũ không có Wake Lock API, nên mọi trang phát `pages/nosleep.mp4` (video đen 1 phút,
  3.4 KB, 2×2 px, gần trong suốt; đã thử trên S2: lặp mượt, không chớp tối). Đang phát video thì Android giữ màn hình sáng, không giảm độ sáng. Video bắt đầu từ **lần chạm
  đầu tiên** sau khi mở trang (trình duyệt cũ bắt buộc phải có thao tác người dùng). Trình duyệt Samsung bỏ qua `loop`, nên
  `common.js` tự tua về đầu gần lúc hết video, nạp lại nếu bị dừng, và mỗi 10 s kiểm tra một lần.
  File được tạo bằng WinRT `MediaComposition` (clip 60 s từ ảnh PNG đen, H.264 Baseline 160×90, 1 fps, 8 kbps, không có tiếng;
  danh sách clip là COM thô: thêm clip qua `[ICollection[MediaClip]].GetMethod('Add').Invoke(...)`).

## Các trang

| File | Nội dung | Dữ liệu |
|---|---|---|
| `01-system` | CPU (từng nhân, nhiệt độ, xung), RAM, GPU, mạng, ổ đĩa, top tiến trình | `/api/stats` 2 s |
| `02-weather` | Thời tiết hiện tại, 24 giờ, 7 ngày, AQI, UV | `/api/ext` (Open-Meteo) |
| `03-finance` | Tỷ giá Vietcombank, crypto Binance (biểu đồ 48 giờ) | `/api/ext` |
| `04-calendar` | Đồng hồ lớn, lịch âm Can Chi, lịch tháng (♥ ngày 22: ngày kỷ niệm), đếm ngược Tết/ngày lễ | tính tại máy + `/api/ext` |
| `05-home` | Tổng quan: thời tiết, tỷ giá, crypto, CPU/RAM/GPU/mạng | `/api/stats` + `/api/ext` |
| `07-media` | Bài đang phát trên PC: ảnh bìa, thời lượng, phát/dừng, chuyển bài, âm lượng | `/api/media`, `/api/media/cmd` |
| `08-wave` | Sóng nhạc cầu vồng: cột LED một màu (`?hue=`), đối xứng trái/phải (bass ở giữa), nhảy theo âm thanh thật của loa PC. `?debug=1` hiện số đo | `/api/meter` ~5 lần/s |
| `09-pixel` | Ảnh 8-bit toàn màn hình: GIF pixel art (đã đổi thành video) hoặc `?src=abstract` / `all`. Mỗi ảnh ~15 phút, chạm để đổi; ảnh mới nạp ở video ẩn, chạy được mới hiện | `/api/videos`, `/bgvideo?n=` |

## config.json

```jsonc
{
  "city": "auto",          // "auto" = đoán theo IP (ở VN hay sai tỉnh) | tên tỉnh, có dấu hay không: "Hải Dương", "Da Nang"
                           // có thể thêm "lat"/"lon"
  "crypto": ["BTC", "ETH", "BNB", "SOL"],      // cặp USDT Binance (hiện 4 cái đầu)
  "currencies": ["EUR", "JPY", ...]            // 8 ngoại tệ Vietcombank (USD luôn có)
}
```

## Extension (điều khiển nhạc)

Máy này **hỏng Windows Media API** ("Class not registered"): phím media ảo không tới được Edge. Nên dùng `extension/`:
- `content.js` chạy trong tab YouTube / YT Music / Spotify web / SoundCloud / Zing / NhacCuaTui: gửi tên bài, kênh, ảnh bìa,
  vị trí, thời lượng mỗi giây; nhận lệnh và bấm nút của chính trang.
- `background.js` chuyển trạng thái tới `/api/ext-media`, và **hỏi `/api/ext-cmd` mỗi giây rồi đẩy lệnh vào tab**
  (`chrome.tabs.sendMessage`): tab ẩn đang dừng nhạc bị Edge giảm timer xuống ~1 lần/phút. Lệnh hết hạn sau 4 s để không
  dồn lại rồi chạy cùng lúc (từng làm video tua về đầu).
- Cổng ở `extension/config.js` (server chỉ tạo khi chưa có; phải là `var DESKBUDDY_PORT = 8080;`; extension vẫn đọc `MINI_SCREEN_PORT` của bản cũ).
- Cài: `edge://extensions` → Developer mode → Load unpacked → chọn `extension` → F5 tab nhạc. Sửa extension xong: bấm reload.

Không có extension: vẫn đoán bài qua tên tab (UI Automation) nhưng không điều khiển được, không có thời lượng.
Spotify bản cài máy điều khiển bằng `WM_APPCOMMAND`. Âm lượng dùng Core Audio, luôn chạy được.

## Khắc phục sự cố

- Điện thoại không vào được: cùng Wi-Fi? Firewall (`netsh advfirewall firewall add rule name="Desk-Buddy" dir=in action=allow protocol=TCP localport=8080 profile=private` với quyền admin).
- Không mở được cổng 8080: server khác đang chạy (bấm `tu-khoi-dong.bat` lần 2 để dừng bản chạy ngầm).
- Thời tiết sai tỉnh: đặt `"city"` bằng tên tỉnh.
- Nhạc không điều khiển được: `/api/media` phải có `"bridge":true` (extension đang gửi dữ liệu).
- Lỗi các nguồn dữ liệu: `http://<ip>:8080/api/debug`.

---

## Ghi chú kỹ thuật

### Kiến trúc `server.ps1`

HTTP server tự viết trên `TcpListener` (1 luồng, `Connection: close`, chờ bằng `Socket.Select`, không busy-poll) + runspace chạy nền.
Kết nối chưa gửi gì (trình duyệt mở sẵn "dự phòng") nằm trong `$pending`, **không được đứng chờ nó**: trước đây chờ 600 ms
làm `/api/meter` trễ và sóng nhạc đơ cả trên PC lẫn điện thoại.

| Luồng | Việc | Chỉ chạy khi |
|---|---|---|
| sampler | WMI/CIM mỗi 2 s → `$state.json` | có ai gọi `/api/stats` trong 60 s |
| fetcher | vị trí (ipwho.is / geocoding Open-Meteo, 6 h), thời tiết + AQI (10 ph), tỷ giá VCB XML (10 ph), Binance ticker (20 s) + klines (10 ph) → `$ext.json` | có ai gọi `/api/ext` trong 10 ph |
| mediaWorker | bài đang phát (extension > Windows media API > tên tab UIA > tiêu đề cửa sổ), ảnh bìa (thumbnail JPEG YouTube / iTunes), lệnh, âm lượng | có ai gọi `/api/media` trong 30 s |
| meterWorker | ~30 lần/s: mức âm L/R (`IAudioMeterInformation`) + chuỗi phổ 48 ký tự từ `DeskBuddy.Spectrum` (C#, luồng riêng: WASAPI **loopback** → FFT 2048 → 48 dải log 40 Hz–16 kHz, +3 dB/octave trên 200 Hz, tự dừng sau 10 s không ai đọc) | có ai gọi `/api/meter` trong 10 s |
| videoWorker (STA) | ảnh động: GIF pixel art (RSS tìm kiếm DeviantArt, không cần key; chỉ lấy ảnh 16:9 (tỉ lệ 1.65–1.9, chỉ ~60 ảnh); URL có token đổi mỗi lần nên khoá theo path; gọi dồn bị 403 nên lượt nào không thêm được gì thì nghỉ 15 ph) → từng khung phóng nearest-neighbor phủ kín 640×360 (cắt mép chút ít), ghép bằng WinRT `MediaComposition` (mỗi khung 1 clip ảnh, đúng delay, lặp ~10 s); clip Mixkit (bỏ clip dọc) → H.264 Baseline 640×360. Cache `%LOCALAPPDATA%\DeskBuddy\videos` (`pf*.mp4` 24 cái, `bg*.mp4` 8 cái) | loại đó được yêu cầu trong 30 ph |

API: `/api/stats` · `/api/ext` (`t` = giờ server gắn lúc trả response, `tz`, `city`, `locSrc`) · `/api/media`, `/api/media/art`,
`POST /api/media/cmd?c=play|next|prev|volup|voldown|mute|volNN` · `POST /api/ext-media?d=<json>`, `/api/ext-cmd` (chỉ 127.0.0.1) ·
`/api/meter?since=<seq>` (`{"seq":N,"s":[[L,R,"48 ký tự phổ"],…]}`) · `/api/videos?src=pixel|abstract|all`, `/bgvideo?n=` (hỗ trợ Range) ·
`/api/pages`, `POST /api/page?p=<file>` · `/api/debug`.

### Quy tắc bắt buộc (mỗi cái là một lỗi đã gặp)

- **`server.ps1` chỉ ký tự ASCII** (PS 5.1 đọc file không BOM theo ANSI). Công cụ Edit biến `\u2013` thành ký tự thật:
  dùng `\p{Pd}` cho dấu gạch. Kiểm tra: `Select-String server.ps1 -Pattern '[^\x00-\x7F]'` phải ra 0 dòng.
- Hàm PowerShell trả `byte[]`: `return , $bytes` (không thì bị trải thành `Object[]`).
- Trong `switch`, `$matches` của khối điều kiện không sang phần xử lý: `-match` lại trong phần xử lý.
- JS trong `pages/`: **ES5** (không let/const/arrow/template/fetch/classList), dùng XHR.
- Bố cục: khung `64rem × 36rem` (1rem = 10 CSS px trên điện thoại). Header `#hdr` ở top 1rem, card bắt đầu top 6.4rem,
  đáy 34.8rem, lề 1.2rem, khe 0.8rem. Canvas khai báo `data-w`/`data-h` (rem), vẽ theo `devicePixelRatio`.
- **Chế độ lite** (`html.lite`, Android ≤ 4): không `transform` trên `#app`, không `overflow:hidden` trên card
  (trình duyệt cũ để lại "bóng ma" canvas: biểu đồ nhân đôi). Biểu đồ sát đáy card bo góc bằng `MS.clipBottom`. Xoá canvas
  bằng `c.width = c.width`. Không animation vô hạn. Không đặt GIF trên lớp GPU (GIF vẫn hay đứng trên S2: tránh dùng GIF).
- `touchstart` của document bị `preventDefault` (chặn menu nhấn giữ của trình duyệt), nên **không có `click` trên điện thoại**:
  nút dùng `MS.tap(el, fn)`, chạm chỗ trống dùng `MS.onTap(fn)`.
- Ảnh gửi cho điện thoại phải là JPEG/PNG (ảnh bìa YouTube là AVIF, server đổi sang JPEG).
- Video cho điện thoại: H.264 **Baseline**. Server có hỗ trợ `Range` (206), vì trình phát video của Android xin từng đoạn.
  Thân video gửi ở luồng nền (`DeskBuddy.BgSend`): trình phát xin `bytes=N-` rồi ngừng đọc khi đệm đầy, gửi chặn thì
  server 1 luồng kẹt vài giây và video đơ theo chu kỳ.

### Viết trang mới

Tạo `pages/NN-ten.html` (bảng chọn trang và menu tự nhận). Tên tiếng Việt cho bảng chọn: `PAGE_INFO` trong `common.js`.
Mô tả cho menu chọn trang của server (chỉ hiện khi chạy `server.ps1` không có `-Page`/`-NoMenu`) và `/api/pages`: `<meta name="menu" content="...">` (không dấu). Khung trang:

```html
<link rel="stylesheet" href="common.css"> … <div id="app"><div id="hdr">(#live .title #hsub .clock #dow #dmy #time)</div> …cards… </div>
<script src="common.js"></script>
<script>MS.init(); MS.poll('/api/ext', 30000, function (d) { MS.live(true); MS.setServerTime(d.t, d.tz); /* vẽ */ }, function () { MS.live(false); });</script>
```

`MS` có sẵn: `html` (chỉ ghi khi đổi), `esc`, `fmt` (số kiểu VN), `ctx2d`, `ring`, `sparkline`, `drawWx`, `icon`,
`solar2lunar`/`lunar2solar`/`ccYear`, `wx`, `aqiInfo`, `now`/`utcNow` (giờ server), `post`, `store`, `tap`, `onTap`.

### Test mà không làm phiền người dùng

Server thật thường đang chạy ở **cổng 8080** (có thể chạy ngầm). Không tắt khi chưa được hỏi.
- Server test ở **8099**: `Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','d:\VSCode\mini-screen\server.ps1','-Port','8099','-Page','05-home.html' -WindowStyle Hidden -RedirectStandardOutput <scratch>\s.log -RedirectStandardError <scratch>\s.err -PassThru`, xong thì dừng theo PID.
- `-Page` ghi đè `last-page.txt`: lưu lại rồi khôi phục sau khi test.
- Kiểm tra cú pháp: `[Management.Automation.Language.Parser]::ParseFile('server.ps1',[ref]$null,[ref]$errs)`.
- Chụp màn hình: `msedge --headless=new --disable-gpu --hide-scrollbars --window-size=1280,720 --virtual-time-budget=8000 --screenshot=<png> http://127.0.0.1:8099/<trang>.html` (chạy bằng `Start-Process -PassThru` + `WaitForExit`). Giả lập S2 (bật lite):
  `--user-agent="Mozilla/5.0 (Linux; U; Android 4.1.2; ko-kr; SHV-E120S Build/JZO54K) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"`.
- Lệnh đụng WinRT/UIA/tiến trình khác có thể cần `dangerouslyDisableSandbox: true`.

### Hạn chế đã biết

Định vị IP ở VN không đáng tin · giá vàng (SJC/BTMC) chặn truy cập tự động · Giphy/Tenor cần key ·
GIF đứng trên S2 (luôn đổi sang video) · trình duyệt cũ chỉ phát 1 video một lúc (trang có video nền đặt
`<body data-nosleep="0">`) · server 1 luồng (đủ cho 1–2 thiết bị) · mọi máy trong LAN chỉnh được nhạc/âm lượng.
Đã bỏ: trang Tin tức, Đồng hồ thế giới, Mạng/ping, Bàn phím tắt, Khung ảnh/tranh/meme, Lịch vạn sự phong thuỷ (người dùng thấy không cần).

### Ý tưởng chưa làm

Lời bài hát karaoke (LRCLIB, khớp thời lượng từ extension) · Pomodoro · Đồng hồ ambient đổi màu theo giờ · Nhắc nghỉ/uống nước ·
Việc cần làm từ `todo.txt`.

### Vì sao không dùng Tailwind

Trình duyệt Android 4.1 không hỗ trợ CSS variables, `flex`/`grid` bản mới, `:is()`… mà Tailwind 2/3/4 dựa vào (biến `--tw-*`);
bản CDN cần JS hiện đại; muốn build thì cần Node (máy không cài). Bố cục bằng `position:absolute` + `rem` trên khung 64×36
chạy được cả trên S2 lẫn trình duyệt mới.
