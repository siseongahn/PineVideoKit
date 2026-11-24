//
//  PVCaptureSource.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

@preconcurrency import AVFoundation
import Foundation

/// Camera + microphone capture with AVCaptureSession.
///
/// Frames are delivered on dedicated high-priority queues (`onVideo`, `onAudio`) straight from the
/// capture outputs; late video frames are discarded rather than queued, so capture never adds
/// latency under load.
public final class PVCaptureSource: NSObject, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var position: AVCaptureDevice.Position
        /// Capture size; should match the encoder size so nothing is scaled.
        public var width: Int32
        public var height: Int32
        public var frameRate: Double
        /// Rotation applied to captured frames and the preview, in degrees
        /// (0 = landscape with the camera on the left, i.e. UIInterfaceOrientation.landscapeRight).
        public var rotationAngle: CGFloat
        public var captureAudio: Bool

        public init(
            position: AVCaptureDevice.Position = .back,
            width: Int32 = 1920,
            height: Int32 = 1080,
            frameRate: Double = 30,
            rotationAngle: CGFloat = 0,
            captureAudio: Bool = true
        ) {
            self.position = position
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.rotationAngle = rotationAngle
            self.captureAudio = captureAudio
        }
    }

    public enum CaptureError: Error, Sendable {
        case cameraUnavailable
        case cannotAddInput
        case cannotAddOutput
    }

    /// The underlying session; use it for previews (see `PVPreviewView`).
    public let session = AVCaptureSession()

    /// Called on the video queue with each captured frame.
    var onVideo: ((CMSampleBuffer) -> Void)?
    /// Called on the audio queue with each captured PCM buffer.
    var onAudio: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.digipine.PineVideoKit.capture.session")
    private let videoQueue = DispatchQueue(label: "com.digipine.PineVideoKit.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.digipine.PineVideoKit.capture.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    public override init() {
        super.init()
    }

    /// (Re)configures camera, format, frame rate and rotation. Safe to call while running.
    public func configure(_ configuration: Configuration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async {
                do {
                    try self.configureBlocking(configuration)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func startRunning() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume()
            }
        }
    }

    public func stopRunning() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }

    // MARK: - Configuration

    private func configureBlocking(_ config: Configuration) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Camera input.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: config.position)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CaptureError.cameraUnavailable
        }
        if videoInput?.device != camera {
            if let videoInput { session.removeInput(videoInput) }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
            session.addInput(input)
            videoInput = input
        }
        try selectFormat(camera, config)

        // Video output: NV12 (what the hardware encoder consumes natively), drop late frames.
        if !session.outputs.contains(videoOutput) {
            guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(config.rotationAngle) {
            connection.videoRotationAngle = config.rotationAngle
        }

        // Microphone.
        if config.captureAudio {
            if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if audioInput != nil, !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                session.addOutput(audioOutput)
            }
        } else {
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        }
    }

    /// Picks a device format with the requested dimensions that supports the frame rate,
    /// preferring video-range 4:2:0, then locks the frame rate.
    private func selectFormat(_ device: AVCaptureDevice, _ config: Configuration) throws {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == config.width && dims.height == config.height
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= config.frameRate && config.frameRate <= $0.maxFrameRate }
        }
        let preferred = candidates.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } ?? candidates.first

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let preferred {
            device.activeFormat = preferred // switches the session to .inputPriority
        } else {
            PVLog.info("No \(config.width)x\(config.height)@\(config.frameRate) format; keeping \(device.activeFormat)")
        }
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= config.frameRate && config.frameRate <= $0.maxFrameRate
        }
        if supported {
            let duration = CMTime(value: 1000, timescale: CMTimeScale(config.frameRate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }
}

extension PVCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            onVideo?(sampleBuffer)
        } else {
            onAudio?(sampleBuffer)
        }
    }
}
