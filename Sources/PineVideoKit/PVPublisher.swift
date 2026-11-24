//
//  PVPublisher.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Publishes video (and optionally audio) to an SRT endpoint as MPEG-TS.
///
/// Pipeline (no actor hops, no per-frame tasks):
///
///     capture queue ─► VideoEncoder (VideoToolbox) ─► [lock] TSMuxer ─► SRT send queue ─► srt_sendmsg2
///     audio queue   ─► AudioEncoder (AAC)          ─┘
///
/// Feed it from a `PVCaptureSource` (`attach(_:)`) or push frames yourself with
/// `append(video:presentationTime:)` and `append(audio:presentationTime:)`.
///
/// ```swift
/// let capture = PVCaptureSource()
/// try await capture.configure(.init(width: 1920, height: 1080))
/// let publisher = PVPublisher(video: .init(width: 1920, height: 1080, bitRate: 5_000_000))
/// publisher.attach(capture)
/// await capture.startRunning()
/// try await publisher.start(URL(string: "srt://192.168.0.10:9000?latency=120")!)
/// ```
public final class PVPublisher: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case publishing
        case failed(String)
    }

    /// Called (on an arbitrary queue) whenever `state` changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var videoSettings: PVVideoSettings {
        lock.lock()
        defer { lock.unlock() }
        return _videoSettings
    }

    public var audioSettings: PVAudioSettings {
        lock.lock()
        defer { lock.unlock() }
        return _audioSettings
    }

    private let lock = NSLock()
    private var _state: State = .idle
    private var _videoSettings: PVVideoSettings
    private var _audioSettings: PVAudioSettings
    private var isPublishing = false

    private let transport = SRTTransport()
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private let muxLock = NSLock()
    private var muxer: TSMuxer?

    public init(video: PVVideoSettings = .init(), audio: PVAudioSettings = .init()) {
        _videoSettings = video
        _audioSettings = audio
        transport.onDisconnect = { [weak self] reason in
            self?.handleDisconnect(reason)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Configuration

    /// Video settings take effect on the next `start`. Use `setVideoBitRate` to change the bitrate live.
    public func setVideoSettings(_ settings: PVVideoSettings) {
        lock.lock()
        _videoSettings = settings
        lock.unlock()
    }

    public func setAudioSettings(_ settings: PVAudioSettings) {
        lock.lock()
        _audioSettings = settings
        lock.unlock()
    }

    /// Changes the video bitrate immediately if publishing.
    public func setVideoBitRate(_ bitRate: Int) {
        lock.lock()
        _videoSettings.bitRate = bitRate
        let encoder = videoEncoder
        lock.unlock()
        encoder?.setBitRate(bitRate)
    }

    /// Routes a capture source's frames into this publisher.
    public func attach(_ source: PVCaptureSource) {
        source.onVideo = { [weak self] sampleBuffer in
            guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            self.append(video: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        source.onAudio = { [weak self] sampleBuffer in
            self?.appendAudio(sampleBuffer)
        }
    }

    // MARK: - Lifecycle

    /// Connects to `url` (`srt://host:port?mode=caller&latency=120&passphrase=…`) and starts publishing.
    public func start(_ url: URL) async throws {
        guard let endpoint = PVSRTEndpoint(url: url) else {
            setState(.failed(PVSRTError.invalidURL.description))
            throw PVSRTError.invalidURL
        }
        try await start(endpoint)
    }

    public func start(_ endpoint: PVSRTEndpoint) async throws {
        stop()
        setState(.connecting)
        let (video, audio) = lock.withLock { (_videoSettings, _audioSettings) }

        // Warm the hardware encoder up while SRT connects, so the stream's first keyframe is not late.
        let videoEncoder = VideoEncoder(settings: video)
        async let warmUp: Void = Self.prepare(videoEncoder)
        do {
            try await transport.open(endpoint)
        } catch {
            await warmUp
            videoEncoder.invalidate()
            setState(.failed(String(describing: error)))
            throw error
        }
        await warmUp

        let muxer = TSMuxer(videoCodec: video.codec, hasAudio: audio.isEnabled)
        muxer.onOutput = { [transport] data in transport.send(data) }

        videoEncoder.onOutput = { [weak self] frame in
            guard let self else { return }
            self.muxLock.lock()
            self.muxer?.writeVideo(frame.annexB, presentationTime: frame.presentationTime, isKeyFrame: frame.isKeyFrame)
            self.muxLock.unlock()
        }

        var audioEncoder: AudioEncoder?
        if audio.isEnabled {
            let encoder = AudioEncoder(bitRate: audio.bitRate)
            encoder.onOutput = { [weak self] frame in
                guard let self else { return }
                self.muxLock.lock()
                self.muxer?.writeAudio(frame.adts, presentationTime: frame.presentationTime)
                self.muxLock.unlock()
            }
            audioEncoder = encoder
        }

        muxLock.withLock { self.muxer = muxer }
        lock.withLock {
            self.videoEncoder = videoEncoder
            self.audioEncoder = audioEncoder
            isPublishing = true
        }
        setState(.publishing)
    }

    /// Stops publishing and closes the connection. Capture (if attached) keeps running.
    public func stop() {
        lock.lock()
        let wasActive = isPublishing || _state == .connecting
        isPublishing = false
        let videoEncoder = self.videoEncoder
        self.videoEncoder = nil
        self.audioEncoder = nil
        lock.unlock()
        videoEncoder?.invalidate()
        muxLock.lock()
        muxer = nil
        muxLock.unlock()
        transport.close()
        if wasActive {
            setState(.idle)
        }
    }

    /// Current SRT statistics while connected.
    public func stats() -> PVStats? {
        transport.stats()
    }

    // MARK: - Input

    /// Encodes a video frame captured at `presentationTime` (host clock).
    public func append(video pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        let encoder = isPublishing ? videoEncoder : nil
        lock.unlock()
        encoder?.encode(pixelBuffer, presentationTime: presentationTime)
    }

    /// Encodes PCM audio captured at `presentationTime` (host clock). Call from one queue only.
    public func append(audio buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        lock.lock()
        let encoder = isPublishing ? audioEncoder : nil
        lock.unlock()
        encoder?.encode(buffer, presentationTime: presentationTime)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let encoder = isPublishing ? audioEncoder : nil
        lock.unlock()
        encoder?.encode(sampleBuffer)
    }

    // MARK: - Private

    /// Runs the (blocking) encoder warm-up off the caller's executor.
    @concurrent
    private static func prepare(_ encoder: VideoEncoder) async {
        encoder.prepare()
    }

    private func handleDisconnect(_ reason: String) {
        lock.lock()
        let wasPublishing = isPublishing
        lock.unlock()
        guard wasPublishing else { return }
        stop()
        setState(.failed("Disconnected: \(reason)"))
    }

    private func setState(_ newState: State) {
        lock.lock()
        let changed = _state != newState
        _state = newState
        let callback = onStateChange
        lock.unlock()
        if changed {
            callback?(newState)
        }
    }
}
