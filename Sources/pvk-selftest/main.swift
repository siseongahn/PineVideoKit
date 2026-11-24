//
//  main.swift
//  pvk-selftest
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//
//  Publishes a synthetic test pattern (moving bar) and a 1 kHz tone through PineVideoKit's
//  encoder → TS muxer → SRT path, so the pipeline can be verified on a Mac without a camera.
//
//  Usage: pvk-selftest <srt-url> [seconds=10] [WIDTHxHEIGHT=1280x720] [fps=30] [h264|hevc]
//  Example: pvk-selftest "srt://127.0.0.1:9000?latency=120" 10 1920x1080 30
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PineVideoKit

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
    print("usage: pvk-selftest <srt-url> [seconds] [WIDTHxHEIGHT] [fps] [h264|hevc]")
    exit(2)
}
let seconds = args.count > 2 ? Double(args[2]) ?? 10 : 10
let size = (args.count > 3 ? args[3] : "1280x720").split(separator: "x").compactMap { Int32($0) }
let width = size.count == 2 ? size[0] : 1280
let height = size.count == 2 ? size[1] : 720
let fps = args.count > 4 ? Double(args[4]) ?? 30 : 30
let codec = args.count > 5 ? PVVideoCodec(rawValue: args[5]) ?? .h264 : .h264

let publisher = PVPublisher(
    video: PVVideoSettings(width: width, height: height, frameRate: fps,
                           bitRate: Int(Double(width * height) * fps * 0.08), codec: codec),
    audio: PVAudioSettings(isEnabled: true, bitRate: 128_000)
)
publisher.onStateChange = { state in print("state:", state) }

final class Generator: @unchecked Sendable {
    let width: Int
    let height: Int
    let fps: Double
    let publisher: PVPublisher
    let queue = DispatchQueue(label: "pvk-selftest.generator", qos: .userInteractive)
    var timer: DispatchSourceTimer?
    var frame = 0
    var startHost = CMTime.invalid
    var audioSamplesSent: Int64 = 0
    let sampleRate = 48_000.0
    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var pool: CVPixelBufferPool?

    init(width: Int, height: Int, fps: Double, publisher: PVPublisher) {
        self.width = width
        self.height = height
        self.fps = fps
        self.publisher = publisher
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if !startHost.isValid {
            startHost = now
            // Wall-clock time of the first frame (PTS 0.1 s in the TS); lets a receiver compute
            // per-frame end-to-end delay.
            print(String(format: "first-frame-epoch %.4f", Date().timeIntervalSince1970))
        }

        // Video: background hue cycles, a white bar sweeps left to right once per second.
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let shade = UInt8((frame * 4) % 200 + 30)
        let barX = Int(Double(width - 40) * (Double(frame % Int(fps)) / fps))
        for y in 0..<height {
            let row = base + y * stride
            memset(row, Int32(shade), width * 4)
            memset(row + barX * 4, 255, 40 * 4)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        publisher.append(video: buffer, presentationTime: now)
        frame += 1

        // Audio: generate exactly the samples due since start so audio tracks the host clock.
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, startHost))
        let due = Int64(elapsed * sampleRate) - audioSamplesSent
        guard due > 0, let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(due)) else { return }
        pcm.frameLength = AVAudioFrameCount(due)
        let samples = pcm.floatChannelData![0]
        for i in 0..<Int(due) {
            let t = Double(audioSamplesSent + Int64(i)) / sampleRate
            samples[i] = Float(sin(2 * .pi * 1000 * t) * 0.2)
        }
        let pts = CMTimeAdd(startHost, CMTime(value: audioSamplesSent, timescale: 48_000))
        publisher.append(audio: pcm, presentationTime: pts)
        audioSamplesSent += due
    }
}

let generator = Generator(width: Int(width), height: Int(height), fps: fps, publisher: publisher)

Task {
    do {
        print("connecting to \(url) — \(width)x\(height)@\(fps) \(codec.rawValue)")
        try await publisher.start(url)
        generator.start()
        for second in 1...Int(seconds) {
            try await Task.sleep(for: .seconds(1))
            if let s = publisher.stats() {
                print(String(format: "t=%2ds  %.2f Mbps  rtt %.1f ms  lost %d  retrans %d  dropped %d",
                             second, s.mbpsSendRate, s.rttMs, s.packetsLost, s.packetsRetransmitted, s.packetsDropped))
            }
            if case .failed = publisher.state { break }
        }
        publisher.stop()
        print("frames sent:", generator.frame)
        exit(0)
    } catch {
        print("error:", error)
        exit(1)
    }
}
dispatchMain()
