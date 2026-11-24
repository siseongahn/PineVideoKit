//
//  Settings.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import Foundation

/// Video codec used for publishing.
public enum PVVideoCodec: String, Sendable, Codable, CaseIterable {
    case h264
    case hevc
}

/// Video encoder settings.
public struct PVVideoSettings: Sendable, Equatable {
    /// Encoded width and height in pixels. Capture at the same size to avoid scaling.
    public var width: Int32
    public var height: Int32
    /// Expected frame rate; also used for the keyframe interval in frames.
    public var frameRate: Double
    /// Average bitrate in bits per second.
    public var bitRate: Int
    public var codec: PVVideoCodec
    /// Seconds between keyframes. Receivers can only start decoding at a keyframe.
    public var keyFrameInterval: Double
    /// VideoToolbox low-latency rate control (H.264 only; ignored for HEVC).
    /// The encoder emits every frame immediately instead of holding frames for rate control.
    public var lowLatency: Bool

    public init(
        width: Int32 = 1920,
        height: Int32 = 1080,
        frameRate: Double = 30,
        bitRate: Int = 5_000_000,
        codec: PVVideoCodec = .h264,
        keyFrameInterval: Double = 1,
        lowLatency: Bool = true
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.codec = codec
        self.keyFrameInterval = keyFrameInterval
        self.lowLatency = lowLatency
    }
}

/// AAC audio encoder settings.
public struct PVAudioSettings: Sendable, Equatable {
    public var isEnabled: Bool
    /// Bits per second.
    public var bitRate: Int

    public init(isEnabled: Bool = true, bitRate: Int = 128_000) {
        self.isEnabled = isEnabled
        self.bitRate = bitRate
    }
}

/// SRT connection mode.
public enum PVSRTMode: String, Sendable {
    /// Connect to a listening peer (`srt://host:port`).
    case caller
    /// Wait for a peer on the given port (`srt://:port?mode=listener`).
    case listener
}

/// An SRT endpoint parsed from a URL such as
/// `srt://192.168.0.10:9000?mode=caller&latency=120&passphrase=...&pbkeylen=16&streamid=...`.
///
/// Units follow libsrt: `latency` and `conntimeo` are milliseconds.
public struct PVSRTEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var mode: PVSRTMode
    /// Receiver buffer (TSBPD) in ms; SRT uses the larger of the two peers' values.
    public var latencyMs: Int32
    /// Empty disables encryption; otherwise 10–79 characters.
    public var passphrase: String
    /// AES key length in bytes: 16, 24 or 32.
    public var pbKeyLength: Int32
    public var streamID: String
    public var connectTimeoutMs: Int32

    public init(
        host: String,
        port: UInt16,
        mode: PVSRTMode = .caller,
        latencyMs: Int32 = 120,
        passphrase: String = "",
        pbKeyLength: Int32 = 16,
        streamID: String = "",
        connectTimeoutMs: Int32 = 3000
    ) {
        self.host = host
        self.port = port
        self.mode = mode
        self.latencyMs = latencyMs
        self.passphrase = passphrase
        self.pbKeyLength = pbKeyLength
        self.streamID = streamID
        self.connectTimeoutMs = connectTimeoutMs
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "srt",
              let port = components.port, (1...65535).contains(port) else {
            return nil
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }
        let mode = PVSRTMode(rawValue: query["mode"]?.lowercased() ?? "caller") ?? .caller
        let host = components.host ?? ""
        if mode == .caller && host.isEmpty {
            return nil
        }
        self.init(
            host: host,
            port: UInt16(port),
            mode: mode,
            latencyMs: query["latency"].flatMap(Int32.init) ?? 120,
            passphrase: query["passphrase"] ?? "",
            pbKeyLength: query["pbkeylen"].flatMap(Int32.init) ?? 16,
            streamID: query["streamid"] ?? "",
            connectTimeoutMs: query["conntimeo"].flatMap(Int32.init) ?? 3000
        )
    }
}

/// A snapshot of SRT sender statistics.
public struct PVStats: Sendable, Equatable {
    /// Current send rate in Mbps.
    public var mbpsSendRate: Double
    /// Smoothed round-trip time in ms.
    public var rttMs: Double
    /// Estimated link bandwidth in Mbps.
    public var mbpsBandwidth: Double
    /// Packets reported lost by the receiver since the connection started.
    public var packetsLost: Int
    /// Packets retransmitted since the connection started.
    public var packetsRetransmitted: Int
    /// Packets dropped by the sender because they were too late to be useful.
    public var packetsDropped: Int
    /// Bytes waiting in the sender buffer; grows when the network cannot keep up.
    public var sendBufferBytes: Int
}
