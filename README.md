# LightBeam

Send any file from one device's **screen** to another device's **camera**.
No internet, Wi-Fi, mobile data, Bluetooth, cables or pairing. Just light.

One Flutter codebase for Android, iOS, web, Windows, macOS and Linux.

## How it works

```
file ─▶ zlib ─▶ [name | SHA-256 | size | data] ─▶ K blocks
      ─▶ LT fountain encoder (endless packets) ─▶ Base45 ─▶ QR (alphanumeric, ECC L)
      ─▶ screen ~~~ light ~~~ camera ─▶ QR scan ─▶ peeling + Gaussian decoder ─▶ verify ─▶ save
```

| Idea | Why it matters |
| --- | --- |
| **Fountain codes (LT, robust soliton)** | The sender loops forever and never needs to hear from the receiver. Any ~K + 2% distinct frames rebuild the file, in any order, starting at any moment. A missed frame costs one frame time, not a resend. |
| **Systematic first pass** | The first K packets are the plain blocks, so a receiver watching from the start needs almost no decoding. |
| **Dense coding (v2)** | Files up to 1,200 blocks send packets that each mix half the file, decoded by bit-packed GF(2) Gaussian elimination. Almost every received packet is useful whatever the receiver already holds: with 30% frame loss or a late start, a receiver needs 0–4% extra frames (v1: 13–39%). Larger files use sparse robust-soliton packets with a peeling decoder. |
| **Base45 in QR alphanumeric mode** | Base45's alphabet *is* the QR alphanumeric set: 97% bit efficiency, against 75% for base64 in byte mode. That is about 30% more data per code. |
| **Degree on the wire, integer-only PRNG** | Block choices come from a 32-bit hash PRNG that gives identical results on the Dart VM and in JavaScript, so a web sender and a native receiver always agree. |
| **Two-level integrity (v2)** | CRC-32 on every packet (every single-bit flip is caught) and SHA-256 on the whole file. If the final check ever fails, the receiver resets itself and keeps scanning. |
| **Fast frames (v2)** | QR masks rotate with the packet number instead of being searched (8x faster), and frames swap on the display refresh with the next one prebuilt. |
| **Defensive parsing (v2)** | Header sanity limits (64 MB, 2,900 B blocks), version-clash detection, safe file names, and clear hints when the camera stalls. |
| **Quad mode** | 2×2 codes per frame for 4× throughput on large sender screens. |
| **Fully offline web build** | CanvasKit and the zxing-wasm QR reader are bundled. The web app never contacts a CDN. |

Prior art that inspired this: [txqr](https://github.com/divan/txqr) (animated QR + fountain codes),
[libcimbar](https://github.com/sz3/libcimbar) (colour icon barcodes, ~100 KB/s),
Decimen (60 fps QR + LT codes).

## Using it

1. On the sending device: **Send → Choose a file** (or **Type a message**).
2. On the receiving device: **Receive**, and point the camera at the sender's screen.
3. Watch the block map fill up. When it is done, tap **Save file**.

Tuning (sender ⚙): *Density* is bytes per QR code, *Speed* is frames per second.
Start at Balanced / 10 fps. Lower them if the receiver stalls, and raise them when it keeps up.
Phone-to-phone at close range with screen brightness up is the fastest setup.

## Platforms

| Platform | Send | Receive |
| --- | --- | --- |
| Android, iOS | ✅ | ✅ native camera scanner (ML Kit / Vision) |
| macOS | ✅ | ✅ |
| Web (any modern browser) | ✅ | ✅ webcam, works offline once served |
| Windows, Linux (native) | ✅ | ➡️ use the web build in a browser (Flutter's camera plugins don't scan on these) |

## Building

```bash
flutter pub get
flutter test                                   # protocol + fountain tests
flutter run                                    # on a connected device
flutter build apk                              # Android
flutter build ios                              # iOS (needs Xcode)
flutter build web --no-web-resources-cdn       # offline web app → build/web
flutter build windows | linux | macos
```

The web app must be served over http(s), not opened as a file. Any static server works offline, for example
`cd build/web && python3 -m http.server 8080`, then open `http://<that-computer's-ip>:8080`.
Browsers allow the camera on `localhost` or https only.

`.github/workflows/build.yml` builds every platform (APK, Windows, macOS, unsigned iOS, Linux, web)
on GitHub Actions when you push this folder to a repository.

## Testing

```bash
flutter test                         # 19 unit + fault-injection tests (Dart VM)
flutter test --platform chrome       # same tests compiled to JavaScript
dart run tool/qr_bench.dart          # QR generation speed per density
dart run tool/degree_bench.dart      # fountain overhead: soliton vs dense
```

## Layout

```
lib/core/base45.dart     RFC 9285 Base45
lib/core/fountain.dart   PRNG, robust soliton, LT decoder (peeling + Gaussian)
lib/core/protocol.dart   packet format, file container, encoder, receiver
lib/ui/                  send / receive screens, QR painter
web/zxing/               bundled zxing-wasm reader (Apache-2.0)
```

## Ideas for v2

- **Colour channels:** three QR codes drawn in red, green and blue on one frame for 3× density (needs a custom channel-splitting decoder).
- **Back-channel by light:** the receiver shows a tiny QR with its missing-block count, so a phone sender can adapt speed.
- **cimbar-style symbols:** shape-plus-colour cells instead of black and white modules, for around 100 KB/s.
