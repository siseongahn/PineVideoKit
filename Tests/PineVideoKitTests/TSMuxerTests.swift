//
//  TSMuxerTests.swift
//  PineVideoKitTests
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import CoreMedia
import Foundation
import Testing
@testable import PineVideoKit

struct TSMuxerTests {
    @Test func crc32MatchesMPEG2CheckValue() {
        // Standard check value for CRC-32/MPEG-2 over "123456789".
        #expect(MPEGCRC32.checksum(Array("123456789".utf8)) == 0x0376_E6E7)
    }

    @Test func psiSectionsHaveValidCRC() {
        let muxer = TSMuxer(videoCodec: .h264, hasAudio: true)
        for packet in [muxer.makePAT(), muxer.makePMT()] {
            #expect(packet.count == 188)
            let bytes = [UInt8](packet)
            #expect(bytes[0] == 0x47)
            let sectionLength = (Int(bytes[6] & 0x0F) << 8) | Int(bytes[7])
            let section = Array(bytes[5..<(8 + sectionLength)]) // table_id … CRC
            // Running the CRC over a section including its CRC yields 0.
            #expect(MPEGCRC32.checksum(section) == 0)
        }
    }

    @Test(arguments: [1, 2, 150, 176, 182, 183, 184, 185, 1000, 5000])
    func packetizeProducesAlignedPacketsWithPayloadIntact(payloadSize: Int) {
        let muxer = TSMuxer(videoCodec: .h264, hasAudio: false)
        let pes = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        let out = muxer.packetize(pid: 0x100, pes: pes, pcr: 12_345, randomAccess: true)
        #expect(out.count % 188 == 0)

        var payload = Data()
        var expectedCC: UInt8 = 0
        for start in stride(from: 0, to: out.count, by: 188) {
            let packet = [UInt8](out[start..<(start + 188)])
            #expect(packet[0] == 0x47)
            #expect((UInt16(packet[1] & 0x1F) << 8 | UInt16(packet[2])) == 0x100)
            #expect(packet[3] & 0x0F == expectedCC)
            expectedCC = (expectedCC + 1) & 0x0F
            var offset = 4
            if packet[3] & 0x20 != 0 {
                offset += 1 + Int(packet[4])
            }
            payload.append(contentsOf: packet[offset...])
        }
        #expect(payload == pes)
    }

    @Test func outputStartsAtFirstKeyFrameAndDropsEarlierAudio() {
        let muxer = TSMuxer(videoCodec: .h264, hasAudio: true)
        var chunks: [Data] = []
        muxer.onOutput = { chunks.append($0) }
        let t0 = CMTime(value: 1_000, timescale: 1_000)
        muxer.writeAudio(Data([0xFF, 0xF1, 0, 0, 0, 0, 0]), presentationTime: t0)
        muxer.writeVideo(Data([0, 0, 0, 1, 0x41]), presentationTime: t0, isKeyFrame: false)
        #expect(chunks.isEmpty)
        muxer.writeVideo(Data([0, 0, 0, 1, 0x65]), presentationTime: t0, isKeyFrame: true)
        #expect(chunks.count == 1)
        // PAT + PMT + at least one PES packet.
        #expect(chunks[0].count >= 3 * 188)
        #expect(chunks[0][1] & 0x1F == 0x00 && chunks[0][2] == 0x00) // PAT first
    }

    @Test func timestampEncodingRoundTrips() {
        let ts: Int64 = 0x1_2345_6789 & 0x1_FFFF_FFFF
        let b = [UInt8](TSMuxer.encodeTimestamp(ts, prefix: 0x20))
        let decoded = (Int64(b[0] & 0x0E) << 29) | (Int64(b[1]) << 22) | (Int64(b[2] & 0xFE) << 14)
            | (Int64(b[3]) << 7) | (Int64(b[4]) >> 1)
        #expect(decoded == ts)
        #expect(b[0] & 0xF0 == 0x20 && b[0] & 1 == 1 && b[2] & 1 == 1 && b[4] & 1 == 1)
    }

    @Test func adtsHeaderEncodesLengthAndRate() throws {
        let header = try #require(ADTS.header(frameLength: 300, sampleRate: 48_000, channels: 1))
        let b = [UInt8](header)
        #expect(b.count == 7 && b[0] == 0xFF && b[1] == 0xF1)
        #expect((b[2] >> 2) & 0x0F == 3) // 48 kHz index
        let length = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | Int(b[5] >> 5)
        #expect(length == 307)
    }

    @Test func endpointParsesURL() throws {
        let url = try #require(URL(string: "srt://10.0.0.2:9000?mode=caller&latency=80&passphrase=0123456789&pbkeylen=32&streamid=cam1"))
        let endpoint = try #require(PVSRTEndpoint(url: url))
        #expect(endpoint.host == "10.0.0.2" && endpoint.port == 9000 && endpoint.mode == .caller)
        #expect(endpoint.latencyMs == 80 && endpoint.passphrase == "0123456789" && endpoint.pbKeyLength == 32)
        #expect(endpoint.streamID == "cam1")
        #expect(PVSRTEndpoint(url: URL(string: "srt://:9000?mode=listener")!)?.mode == .listener)
        #expect(PVSRTEndpoint(url: URL(string: "http://host:9000")!) == nil)
    }
}
