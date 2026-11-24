//
//  TSMuxer.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import CoreMedia
import Foundation

/// MPEG-2 CRC32 (polynomial 0x04C11DB7, init 0xFFFFFFFF, no reflection, no final XOR),
/// as used by PSI sections (PAT/PMT).
enum MPEGCRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}

/// Writes an MPEG transport stream with one program: an H.264/HEVC video track (also the PCR
/// track) and an optional AAC (ADTS) audio track.
///
/// Design choices for low latency:
/// - Output starts at the first video keyframe so a receiver can decode the very first frame.
/// - PAT/PMT are repeated in front of every keyframe, so a late-joining receiver locks on within
///   one keyframe interval.
/// - Audio and video share a single time base (the first keyframe's capture time), so A/V stay
///   in sync and PTS track wall-clock time.
/// - Each access unit is emitted as soon as it is packetised; nothing is buffered across frames.
///
/// Not thread-safe; callers serialise access.
final class TSMuxer {
    static let packetSize = 188
    static let patPID: UInt16 = 0x0000
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101

    /// PTS is offset ahead of PCR so a receiver's decoder never sees a frame that is already late.
    static let ptsOffsetTicks: Int64 = 9_000 // 100 ms at 90 kHz

    /// Receives complete 188-byte-aligned TS data for one access unit (or PSI tables).
    var onOutput: ((Data) -> Void)?

    private let videoCodec: PVVideoCodec
    private let hasAudio: Bool
    private var baseTime: CMTime?
    private var continuity: [UInt16: UInt8] = [:]

    init(videoCodec: PVVideoCodec, hasAudio: Bool) {
        self.videoCodec = videoCodec
        self.hasAudio = hasAudio
    }

    /// Whether the first keyframe has been written (until then, audio is dropped).
    var hasStarted: Bool { baseTime != nil }

    /// Writes one video access unit in Annex B format.
    func writeVideo(_ annexB: Data, presentationTime: CMTime, isKeyFrame: Bool) {
        if baseTime == nil {
            guard isKeyFrame else { return }
            baseTime = presentationTime
        }
        guard let ticks = ticks(for: presentationTime) else { return }
        var out = Data()
        if isKeyFrame {
            out.append(makePAT())
            out.append(makePMT())
        }
        let pes = makePES(streamID: 0xE0, payload: annexB, pts: ticks + Self.ptsOffsetTicks, boundedLength: false)
        out.append(packetize(pid: Self.videoPID, pes: pes, pcr: ticks, randomAccess: isKeyFrame))
        onOutput?(out)
    }

    /// Writes one AAC frame, including its 7-byte ADTS header.
    func writeAudio(_ adtsFrame: Data, presentationTime: CMTime) {
        guard hasAudio, let ticks = ticks(for: presentationTime) else { return }
        let pes = makePES(streamID: 0xC0, payload: adtsFrame, pts: ticks + Self.ptsOffsetTicks, boundedLength: true)
        onOutput?(packetize(pid: Self.audioPID, pes: pes, pcr: nil, randomAccess: true))
    }

    // MARK: - Timestamps

    /// 90 kHz ticks since the stream's base time; nil for samples captured before the base.
    private func ticks(for time: CMTime) -> Int64? {
        guard let baseTime, time.isValid else { return nil }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(time, baseTime))
        guard seconds >= 0 else { return nil }
        return Int64((seconds * 90_000).rounded()) & 0x1_FFFF_FFFF // 33-bit wrap
    }

    // MARK: - PES

    private func makePES(streamID: UInt8, payload: Data, pts: Int64, boundedLength: Bool) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamID])
        let headerLength = 3 + 5 // flags(2) + header_data_length(1) + PTS(5)
        // PES_packet_length may be 0 ("unbounded") only for video; audio frames are always small.
        let length = boundedLength ? headerLength + payload.count : 0
        pes.append(UInt8((length >> 8) & 0xFF))
        pes.append(UInt8(length & 0xFF))
        pes.append(0x84) // '10' marker, data_alignment_indicator = 1
        pes.append(0x80) // PTS only (no B-frames, so DTS == PTS)
        pes.append(0x05) // PES_header_data_length
        pes.append(Self.encodeTimestamp(pts, prefix: 0x20))
        pes.append(payload)
        return pes
    }

    static func encodeTimestamp(_ ts: Int64, prefix: UInt8) -> Data {
        let v = UInt64(ts) & 0x1_FFFF_FFFF
        return Data([
            prefix | UInt8((v >> 29) & 0x0E) | 0x01,
            UInt8((v >> 22) & 0xFF),
            UInt8((v >> 14) & 0xFE) | 0x01,
            UInt8((v >> 7) & 0xFF),
            UInt8((v << 1) & 0xFE) | 0x01
        ])
    }

    static func encodePCR(_ base: Int64) -> [UInt8] {
        let v = UInt64(base) & 0x1_FFFF_FFFF
        return [
            UInt8((v >> 25) & 0xFF),
            UInt8((v >> 17) & 0xFF),
            UInt8((v >> 9) & 0xFF),
            UInt8((v >> 1) & 0xFF),
            UInt8((v & 0x01) << 7) | 0x7E, // 6 reserved bits set, extension MSB = 0
            0x00
        ]
    }

    // MARK: - TS packets

    private func nextContinuity(_ pid: UInt16) -> UInt8 {
        let cc = continuity[pid, default: 0]
        continuity[pid] = (cc + 1) & 0x0F
        return cc
    }

    /// Splits a PES into 188-byte TS packets. The first packet carries the PCR / random-access
    /// flag when requested; the last packet is padded with adaptation-field stuffing.
    func packetize(pid: UInt16, pes: Data, pcr: Int64?, randomAccess: Bool) -> Data {
        var out = Data()
        out.reserveCapacity((pes.count / 184 + 2) * Self.packetSize)
        var offset = pes.startIndex
        var first = true
        while offset < pes.endIndex {
            var adaptation: [UInt8]? = nil // adaptation field content, excluding its length byte
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                var field: [UInt8] = []
                if let pcr {
                    flags |= 0x10
                    field = Self.encodePCR(pcr)
                }
                adaptation = [flags] + field
            }
            let adaptationSize = adaptation.map { 1 + $0.count } ?? 0
            let space = 184 - adaptationSize
            let remaining = pes.endIndex - offset
            if remaining < space {
                let stuffing = space - remaining
                if adaptation != nil {
                    adaptation! += [UInt8](repeating: 0xFF, count: stuffing)
                } else if stuffing == 1 {
                    adaptation = [] // a lone length byte of 0 is one byte of stuffing
                } else {
                    adaptation = [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                }
            }
            let take = min(remaining, 184 - (adaptation.map { 1 + $0.count } ?? 0))
            var header: [UInt8] = [
                0x47,
                (first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F),
                UInt8(pid & 0xFF),
                (adaptation != nil ? 0x30 : 0x10) | nextContinuity(pid)
            ]
            if let adaptation {
                header.append(UInt8(adaptation.count))
                header += adaptation
            }
            out.append(contentsOf: header)
            out.append(pes[offset..<(offset + take)])
            offset += take
            first = false
        }
        return out
    }

    /// Wraps a PSI section in a single TS packet (pointer_field + section + 0xFF padding).
    private func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var packet: [UInt8] = [0x47, 0x40 | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF), 0x10 | nextContinuity(pid), 0x00]
        packet += section
        packet += [UInt8](repeating: 0xFF, count: Self.packetSize - packet.count)
        return Data(packet)
    }

    private static func withCRC(_ section: [UInt8]) -> [UInt8] {
        let crc = MPEGCRC32.checksum(section)
        return section + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    func makePAT() -> Data {
        let sectionLength = 5 + 4 + 4 // header after length, one program, CRC
        let section: [UInt8] = [
            0x00,                                          // table_id
            0xB0 | UInt8(sectionLength >> 8), UInt8(sectionLength & 0xFF),
            0x00, 0x01,                                    // transport_stream_id
            0xC1,                                          // version 0, current_next 1
            0x00, 0x00,                                    // section / last section
            0x00, 0x01,                                    // program_number 1
            0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)
        ]
        return psiPacket(pid: Self.patPID, section: Self.withCRC(section))
    }

    func makePMT() -> Data {
        var streams: [(type: UInt8, pid: UInt16)] = [(videoCodec == .hevc ? 0x24 : 0x1B, Self.videoPID)]
        if hasAudio {
            streams.append((0x0F, Self.audioPID)) // AAC in ADTS
        }
        let sectionLength = 9 + 5 * streams.count + 4
        var section: [UInt8] = [
            0x02,                                          // table_id
            0xB0 | UInt8(sectionLength >> 8), UInt8(sectionLength & 0xFF),
            0x00, 0x01,                                    // program_number 1
            0xC1, 0x00, 0x00,
            0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), // PCR_PID = video
            0xF0, 0x00                                     // program_info_length 0
        ]
        for stream in streams {
            section += [stream.type, 0xE0 | UInt8(stream.pid >> 8), UInt8(stream.pid & 0xFF), 0xF0, 0x00]
        }
        return psiPacket(pid: Self.pmtPID, section: Self.withCRC(section))
    }
}

/// Builds the 7-byte ADTS header that precedes each raw AAC-LC frame in a transport stream.
enum ADTS {
    private static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func header(frameLength aacLength: Int, sampleRate: Double, channels: Int) -> Data? {
        guard let rateIndex = sampleRates.firstIndex(of: sampleRate), (1...7).contains(channels) else {
            return nil
        }
        let length = aacLength + 7
        let profile = 1 // AAC LC (object type 2) - 1
        return Data([
            0xFF,
            0xF1, // MPEG-4, layer 0, no CRC
            UInt8(profile << 6) | UInt8(rateIndex << 2) | UInt8((channels >> 2) & 0x01),
            UInt8((channels & 0x03) << 6) | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5) | 0x1F,
            0xFC
        ])
    }
}
