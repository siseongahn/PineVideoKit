//
//  VideoEncoder.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import CoreMedia
import Foundation
import VideoToolbox

/// One encoded video access unit, already converted to Annex B (start codes, parameter sets and
/// access unit delimiter in front of keyframes) for MPEG-TS.
struct EncodedVideoFrame {
    let annexB: Data
    let presentationTime: CMTime
    let isKeyFrame: Bool
}

/// Hardware H.264/HEVC encoder built on VTCompressionSession, configured for live streaming:
/// real-time, no frame reordering (no B-frames), fixed keyframe interval, and optionally
/// VideoToolbox's low-latency rate control.
///
/// `encode` may be called from any single thread (the capture queue); the output handler is called
/// on a VideoToolbox thread as soon as each frame is compressed.
final class VideoEncoder: @unchecked Sendable {
    var onOutput: ((EncodedVideoFrame) -> Void)?

    private let lock = NSLock()
    private var settings: PVVideoSettings
    private var session: VTCompressionSession?
    private var forceKeyFrame = true

    init(settings: PVVideoSettings) {
        self.settings = settings
    }

    deinit {
        invalidate()
    }

    /// Changes the average bitrate on the fly without restarting the session.
    func setBitRate(_ bitRate: Int) {
        lock.lock()
        settings.bitRate = bitRate
        let session = self.session
        lock.unlock()
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        }
    }

    /// Creates the compression session and pushes one blank frame through it, discarding the output.
    ///
    /// The first frame a fresh VTCompressionSession encodes takes ~0.5–0.9 s (hardware encoder
    /// spin-up) and the frames behind it are dropped. If that late first keyframe started the stream,
    /// a receiver would anchor its playback clock to it and stay that far behind for the whole
    /// session. Warming up before publishing makes the first real keyframe arrive on time.
    func prepare() {
        lock.lock()
        if session == nil {
            session = makeSession()
        }
        let session = self.session
        let width = Int(settings.width)
        let height = Int(settings.height)
        lock.unlock()
        guard let session else { return }

        var blank: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &blank) == kCVReturnSuccess,
              let blank else { return }
        CVPixelBufferLockBaseAddress(blank, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(blank) {
            let fill: Int32 = plane == 0 ? 16 : 128 // video-range black
            memset(CVPixelBufferGetBaseAddressOfPlane(blank, plane), fill,
                   CVPixelBufferGetBytesPerRowOfPlane(blank, plane) * CVPixelBufferGetHeightOfPlane(blank, plane))
        }
        CVPixelBufferUnlockBaseAddress(blank, [])

        let start = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(session, imageBuffer: blank, presentationTimeStamp: start, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.withLock { forceKeyFrame = true }
        PVLog.info(String(format: "Video encoder warmed up in %.0f ms",
                          CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start)) * 1000))
    }

    /// Makes the next encoded frame a keyframe (e.g. when a receiver (re)connects).
    func requestKeyFrame() {
        lock.lock()
        forceKeyFrame = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        if session == nil {
            session = makeSession()
        }
        let session = self.session
        let keyFrame = forceKeyFrame
        forceKeyFrame = false
        let codec = settings.codec
        lock.unlock()
        guard let session else { return }

        let properties: CFDictionary? = keyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            guard let frame = AnnexB.frame(from: sampleBuffer, codec: codec) else { return }
            self.onOutput?(frame)
        }
    }

    func invalidate() {
        lock.lock()
        let session = self.session
        self.session = nil
        forceKeyFrame = true
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Session

    /// Must be called with `lock` held.
    private func makeSession() -> VTCompressionSession? {
        let isH264 = settings.codec == .h264
        var specification: [CFString: Any] = [:]
        if settings.lowLatency && isH264 {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = kCFBooleanTrue
        }
        #if os(macOS)
        specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
        #endif

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width,
            height: settings.height,
            codecType: isH264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: specification.isEmpty ? nil : specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            PVLog.error("VTCompressionSessionCreate failed: \(status)")
            return nil
        }

        let frameInterval = max(1, Int((settings.frameRate * settings.keyFrameInterval).rounded()))
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_ProfileLevel: isH264
                ? kVTProfileLevel_H264_High_AutoLevel
                : kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: settings.bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameInterval,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: settings.keyFrameInterval
        ]
        if isH264 {
            properties[kVTCompressionPropertyKey_H264EntropyMode] = kVTH264EntropyMode_CABAC
        }
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if result != noErr {
                PVLog.info("VTSessionSetProperty(\(key)) not applied: \(result)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}

/// Converts VideoToolbox output (length-prefixed AVCC/HVCC) to Annex B for MPEG-TS.
enum AnnexB {
    static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    static func frame(from sampleBuffer: CMSampleBuffer, codec: PVVideoCodec) -> EncodedVideoFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let isKeyFrame = Self.isKeyFrame(sampleBuffer)

        var out = Data()
        // Access unit delimiter: recommended in front of every access unit in a transport stream.
        out.append(contentsOf: startCode + (codec == .hevc ? [0x46, 0x01, 0x50] : [0x09, 0xF0]))
        if isKeyFrame {
            for set in parameterSets(format, codec: codec) {
                out.append(contentsOf: startCode)
                out.append(set)
            }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let lengthSize = nalLengthSize(format, codec: codec)
        var offset = 0
        while offset + lengthSize <= avcc.count {
            var nalLength = 0
            for i in 0..<lengthSize {
                nalLength = (nalLength << 8) | Int(avcc[offset + i])
            }
            offset += lengthSize
            guard nalLength > 0, offset + nalLength <= avcc.count else { break }
            out.append(contentsOf: startCode)
            out.append(avcc[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return EncodedVideoFrame(
            annexB: out,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyFrame: isKeyFrame
        )
    }

    static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else {
            return true
        }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) from the format description.
    static func parameterSets(_ format: CMFormatDescription, codec: PVVideoCodec) -> [Data] {
        var count = 0
        var sets: [Data] = []
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return sets
    }

    static func nalLengthSize(_ format: CMFormatDescription, codec: PVVideoCodec) -> Int {
        var length: Int32 = 4
        switch codec {
        case .h264:
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &length)
        case .hevc:
            _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &length)
        }
        return (1...4).contains(Int(length)) ? Int(length) : 4
    }
}
