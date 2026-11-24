# PineVideoKit

**Low-latency live video publishing over SRT for iOS and macOS.**
PineVideoKit captures camera and microphone, encodes H.264/HEVC + AAC with VideoToolbox, muxes MPEG-TS
and sends it over SRT — on a short, lock-based pipeline with no per-frame tasks or actor hops.
It warms the hardware encoder up before the stream starts, so receivers never lock onto a late first frame.
Measured overhead on top of the SRT buffer is about 14 ms for 1080p30 (Swift 6, iOS 17+ / macOS 14+, MIT).

```
capture queue ─► VideoEncoder (VideoToolbox) ─► [lock] TSMuxer ─► SRT send queue ─► srt_sendmsg2
audio queue   ─► AudioEncoder (AAC)          ─┘
```

PineVideoKit was written from scratch for [PineSRT](https://git.digipine.com/simon/PineSRT)
(iPhone camera → Mac over SRT), using [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift)
as a reference for the feature set. No HaishinKit code is included.

## Features

| Area | Details |
|---|---|
| Capture — `PVCaptureSource` | Camera + mic via AVCaptureSession; picks a device format for the requested size and frame rate (720p … 4K, up to 60 fps); rotation; late frames are discarded, never queued |
| Preview — `PVPreviewView`, `PVPreview` | iOS UIKit / SwiftUI view on AVCaptureVideoPreviewLayer — independent of the encoder, adds no latency |
| Video encoding | VideoToolbox H.264 (High) / HEVC (Main), real-time, no B-frames, fixed keyframe interval, low-latency rate control (H.264), live bitrate changes, encoder warm-up before publishing |
| Audio encoding | AAC-LC via AVAudioConverter with ADTS framing; re-anchors timestamps after interruptions |
| MPEG-TS | PAT/PMT repeated before every keyframe, PES, PCR on the video PID, random-access flags; output starts at the first keyframe; audio and video share one time base |
| SRT | libsrt live mode, caller and listener, latency, AES passphrase and key length, stream ID, connect timeout, statistics (`PVStats`) |

Not included: RTMP, WebRTC, playback/receiving, multi-camera, overlays/compositing, ReplayKit,
adaptive bitrate.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://git.digipine.com/simon/PineVideoKit.git", branch: "main")
],
targets: [
    .target(name: "MyApp", dependencies: ["PineVideoKit"])
]
```

In Xcode: **File → Add Package Dependencies…** and enter the URL above.

iOS apps need `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` and — to reach a Mac on the
same Wi-Fi — `NSLocalNetworkUsageDescription` in Info.plist.

## Usage

```swift
import PineVideoKit

let capture = PVCaptureSource()
try await capture.configure(.init(width: 1920, height: 1080, frameRate: 30, rotationAngle: 0))

let publisher = PVPublisher(video: .init(width: 1920, height: 1080, bitRate: 5_000_000))
publisher.attach(capture)
publisher.onStateChange = { state in print(state) }   // .connecting / .publishing / .failed(…)
await capture.startRunning()

try await publisher.start(URL(string: "srt://192.168.0.10:9000?mode=caller&latency=120")!)

let stats = publisher.stats()            // Mbps, RTT, loss, retransmits, send buffer
publisher.setVideoBitRate(8_000_000)     // takes effect immediately
publisher.stop()
```

SwiftUI preview (iOS):

```swift
PVPreview(source: capture, rotationAngle: 0, videoGravity: .resizeAspect)
```

Feeding your own frames instead of the camera (host-clock timestamps):

```swift
publisher.append(video: pixelBuffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
publisher.append(audio: pcmBuffer, presentationTime: captureTime)
```

### SRT URL options

`srt://host:port?…` — units follow libsrt.

| Option | Meaning | Default |
|---|---|---|
| `mode` | `caller` (connect) or `listener` (`srt://:port?mode=listener`) | `caller` |
| `latency` | Receiver buffer in **ms** (the larger peer value wins) | `120` |
| `passphrase` | AES encryption, 10–79 characters | off |
| `pbkeylen` | Key length in bytes: 16, 24, 32 | `16` |
| `streamid` | Stream ID passed to the listener | — |
| `conntimeo` | Connect timeout in ms | `3000` |

ffmpeg/ffplay use **microseconds** for `latency` in their SRT URLs.

## Receiving on a Mac

```bash
ffplay -fflags nobuffer -flags low_delay -framedrop -probesize 8192 -analyzeduration 100000 -sync ext \
  "srt://0.0.0.0:9000?mode=listener&latency=120000"
```

Keep `-analyzeduration` small but non-zero: `0` means "default" (5–7 s) and ffplay never catches up
on that initial buffer.

## Measured latency

`pvk-selftest` (synthetic 1080p30 pattern over loopback, SRT latency 120 ms), from each frame's
wall-clock capture time to the arrival of its bytes at the SRT receiver:

| | Delay |
|---|---|
| First frame | 145 ms |
| Steady state | 134 ms ≈ 120 ms SRT buffer + **~14 ms** encode, mux and send |

Without the encoder warm-up the first keyframe arrived ~0.9 s late, and receivers such as ffplay stay
that far behind for the whole session.

## Development

```bash
swift test       # TS muxer, CRC-32/MPEG-2, ADTS, timestamps, URL parsing
swift build
.build/debug/pvk-selftest "srt://127.0.0.1:9000?latency=120" 10 1920x1080 30   # [seconds] [WxH] [fps] [h264|hevc]
```

| Path | Contents |
|---|---|
| `Sources/PineVideoKit/PVPublisher.swift` | Public entry point; wires encoders, muxer and transport |
| `Sources/PineVideoKit/Capture/` | `PVCaptureSource` |
| `Sources/PineVideoKit/Codec/` | VideoToolbox and AAC encoders, Annex B conversion |
| `Sources/PineVideoKit/TS/` | MPEG-TS muxer, CRC-32/MPEG-2, ADTS |
| `Sources/PineVideoKit/SRT/` | libsrt transport |
| `Sources/PineVideoKit/View/` | iOS preview views |
| `Sources/pvk-selftest/` | macOS test-pattern sender |

## License

PineVideoKit is released under the MIT License — see [LICENSE](LICENSE).
It depends on the prebuilt [libsrt-xcframework](https://github.com/HaishinKit/libsrt-xcframework)
(libsrt is MPL-2.0, OpenSSL is Apache-2.0), fetched by Swift Package Manager.
