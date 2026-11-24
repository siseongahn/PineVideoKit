//
//  AudioEncoder.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import AVFoundation
import CoreMedia
import Foundation

/// One AAC-LC frame with its ADTS header, ready for the TS muxer.
struct EncodedAudioFrame {
    let adts: Data
    let presentationTime: CMTime
}

/// PCM → AAC-LC encoder built on AVAudioConverter.
///
/// Timestamps: AAC frames are 1024 samples, so frame `n` gets `start + n * 1024 / sampleRate`,
/// where `start` is the capture time of the first PCM sample. If input timestamps jump (e.g. after
/// an audio interruption), the encoder resets and re-anchors to the new capture time.
///
/// Not thread-safe; call from a single queue (the audio capture queue).
final class AudioEncoder {
    var onOutput: ((EncodedAudioFrame) -> Void)?

    private var bitRate: Int
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var startTime: CMTime = .invalid
    private var inputFrames: Int64 = 0
    private var outputPackets: Int64 = 0

    init(bitRate: Int) {
        self.bitRate = bitRate
    }

    func reset() {
        converter = nil
        inputFormat = nil
        outputFormat = nil
        pending.removeAll()
        startTime = .invalid
        inputFrames = 0
        outputPackets = 0
    }

    /// Encodes a PCM sample buffer from AVCaptureAudioDataOutput.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        encode(buffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Encodes a PCM buffer captured at `presentationTime` (host clock).
    func encode(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        if inputFormat != buffer.format || converter == nil {
            configure(for: buffer.format)
        }
        guard let converter, let outputFormat else { return }
        let sampleRate = buffer.format.sampleRate

        if startTime.isValid {
            // Re-anchor when the capture clock and our sample count disagree by more than 100 ms.
            let expected = CMTimeAdd(startTime, CMTime(value: inputFrames, timescale: CMTimeScale(sampleRate)))
            if abs(CMTimeGetSeconds(CMTimeSubtract(presentationTime, expected))) > 0.1 {
                configure(for: buffer.format)
            }
        }
        if !startTime.isValid {
            startTime = presentationTime
        }
        pending.append(buffer)
        inputFrames += Int64(buffer.frameLength)

        while true {
            let packet = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 1,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let result = converter.convert(to: packet, error: &error) { [self] _, inputStatus in
                if pending.isEmpty {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return pending.removeFirst()
            }
            guard result == .haveData, packet.packetCount > 0 else {
                if let error { PVLog.error("AAC encode failed: \(error)") }
                return
            }
            let size = Int(packet.packetDescriptions?.pointee.mDataByteSize ?? packet.byteLength)
            let raw = Data(bytes: packet.data, count: size)
            let channels = Int(outputFormat.channelCount)
            guard let header = ADTS.header(frameLength: size, sampleRate: outputFormat.sampleRate, channels: channels) else {
                return
            }
            let pts = CMTimeAdd(startTime, CMTime(value: outputPackets * 1024, timescale: CMTimeScale(outputFormat.sampleRate)))
            outputPackets += 1
            onOutput?(EncodedAudioFrame(adts: header + raw, presentationTime: pts))
        }
    }

    private func configure(for format: AVAudioFormat) {
        reset()
        let channels = min(format.channelCount, 2)
        guard let output = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels
        ]), let converter = AVAudioConverter(from: format, to: output) else {
            PVLog.error("Cannot create AAC converter for \(format)")
            return
        }
        converter.bitRate = bitRate
        self.converter = converter
        self.inputFormat = format
        self.outputFormat = output
    }
}
