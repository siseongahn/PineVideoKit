//
//  SRTTransport.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import Foundation
import libsrt

/// Errors raised while opening an SRT connection.
public enum PVSRTError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidURL
    case resolveFailed(String)
    case socket(String)
    case connectFailed(String)

    public var description: String {
        switch self {
        case .invalidURL: "Invalid SRT URL"
        case .resolveFailed(let host): "Cannot resolve host \(host)"
        case .socket(let message): "SRT socket error: \(message)"
        case .connectFailed(let message): "SRT connection failed: \(message)"
        }
    }
}

/// A sending SRT socket in live mode (caller or listener) that carries MPEG-TS.
///
/// `send` is non-blocking for the caller: data is split into 1316-byte messages (7 TS packets)
/// and written by `srt_sendmsg2` on a dedicated serial queue, so the encoder threads never wait
/// on the network.
final class SRTTransport: @unchecked Sendable {
    /// 7 × 188-byte TS packets: libsrt's default live payload size.
    static let payloadSize = 1316

    /// Called once, on the send queue, when the connection breaks while sending.
    var onDisconnect: (@Sendable (String) -> Void)?

    private static let startup: Void = {
        srt_startup()
    }()

    private let queue = DispatchQueue(label: "com.digipine.PineVideoKit.srt.send", qos: .userInteractive)
    private let lock = NSLock()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var listenSocket: SRTSOCKET = SRT_INVALID_SOCK
    private var isBroken = false

    init() {
        _ = Self.startup
    }

    deinit {
        close()
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return socket != SRT_INVALID_SOCK && !isBroken && srt_getsockstate(socket) == SRTS_CONNECTED
    }

    /// Opens the connection. Blocks a background thread (not the caller) until connected,
    /// accepted (listener) or failed.
    func open(_ endpoint: PVSRTEndpoint) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.openBlocking(endpoint)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            lock.lock()
            let socket = self.socket
            let broken = isBroken
            lock.unlock()
            guard socket != SRT_INVALID_SOCK, !broken else { return }

            var offset = data.startIndex
            while offset < data.endIndex {
                let end = min(offset + Self.payloadSize, data.endIndex)
                let result = data[offset..<end].withUnsafeBytes { raw in
                    srt_sendmsg2(socket, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), nil)
                }
                if result == SRT_ERROR {
                    markBroken(Self.lastError())
                    return
                }
                offset = end
            }
        }
    }

    func close() {
        lock.lock()
        let socket = self.socket
        let listenSocket = self.listenSocket
        self.socket = SRT_INVALID_SOCK
        self.listenSocket = SRT_INVALID_SOCK
        isBroken = false
        lock.unlock()
        if socket != SRT_INVALID_SOCK { srt_close(socket) }
        if listenSocket != SRT_INVALID_SOCK { srt_close(listenSocket) }
    }

    func stats() -> PVStats? {
        lock.lock()
        let socket = self.socket
        lock.unlock()
        guard socket != SRT_INVALID_SOCK else { return nil }
        var perf = CBytePerfMon()
        guard srt_bstats(socket, &perf, 1) != SRT_ERROR else { return nil }
        return PVStats(
            mbpsSendRate: perf.mbpsSendRate,
            rttMs: perf.msRTT,
            mbpsBandwidth: perf.mbpsBandwidth,
            packetsLost: Int(perf.pktSndLossTotal),
            packetsRetransmitted: Int(perf.pktRetransTotal),
            packetsDropped: Int(perf.pktSndDropTotal),
            sendBufferBytes: Int(perf.byteSndBuf)
        )
    }

    // MARK: - Private

    private func markBroken(_ reason: String) {
        lock.lock()
        let wasBroken = isBroken
        isBroken = true
        lock.unlock()
        if !wasBroken {
            PVLog.error("SRT send failed: \(reason)")
            onDisconnect?(reason)
        }
    }

    private func openBlocking(_ endpoint: PVSRTEndpoint) throws {
        close()
        let sock = srt_create_socket()
        guard sock != SRT_INVALID_SOCK else { throw PVSRTError.socket(Self.lastError()) }
        do {
            try configure(sock, endpoint)
            switch endpoint.mode {
            case .caller:
                try withAddress(host: endpoint.host, port: endpoint.port) { address, length in
                    guard srt_connect(sock, address, length) != SRT_ERROR else {
                        throw PVSRTError.connectFailed(Self.lastError())
                    }
                }
                lock.lock()
                socket = sock
                lock.unlock()
            case .listener:
                try withAddress(host: endpoint.host.isEmpty ? "0.0.0.0" : endpoint.host, port: endpoint.port) { address, length in
                    guard srt_bind(sock, address, length) != SRT_ERROR else {
                        throw PVSRTError.socket(Self.lastError())
                    }
                }
                guard srt_listen(sock, 1) != SRT_ERROR else { throw PVSRTError.socket(Self.lastError()) }
                lock.lock()
                listenSocket = sock
                lock.unlock()
                let accepted = srt_accept(sock, nil, nil)
                lock.lock()
                listenSocket = SRT_INVALID_SOCK
                lock.unlock()
                srt_close(sock)
                guard accepted != SRT_INVALID_SOCK else { throw PVSRTError.connectFailed(Self.lastError()) }
                lock.lock()
                socket = accepted
                lock.unlock()
            }
        } catch {
            srt_close(sock)
            throw error
        }
    }

    private func configure(_ sock: SRTSOCKET, _ endpoint: PVSRTEndpoint) throws {
        var transtype = SRTT_LIVE
        try set(sock, SRTO_TRANSTYPE, &transtype, MemoryLayout.size(ofValue: transtype))
        var yes: Int32 = 1
        try set(sock, SRTO_SENDER, &yes, MemoryLayout<Int32>.size)
        var latency = endpoint.latencyMs
        try set(sock, SRTO_LATENCY, &latency, MemoryLayout<Int32>.size)
        var payload = Int32(Self.payloadSize)
        try set(sock, SRTO_PAYLOADSIZE, &payload, MemoryLayout<Int32>.size)
        var timeout = endpoint.connectTimeoutMs
        try set(sock, SRTO_CONNTIMEO, &timeout, MemoryLayout<Int32>.size)
        if !endpoint.passphrase.isEmpty {
            try setString(sock, SRTO_PASSPHRASE, endpoint.passphrase)
            var keyLength = endpoint.pbKeyLength
            try set(sock, SRTO_PBKEYLEN, &keyLength, MemoryLayout<Int32>.size)
        }
        if !endpoint.streamID.isEmpty {
            try setString(sock, SRTO_STREAMID, endpoint.streamID)
        }
    }

    private func set(_ sock: SRTSOCKET, _ option: SRT_SOCKOPT, _ value: UnsafeRawPointer, _ size: Int) throws {
        guard srt_setsockflag(sock, option, value, Int32(size)) != SRT_ERROR else {
            throw PVSRTError.socket("option \(option.rawValue): \(Self.lastError())")
        }
    }

    private func setString(_ sock: SRTSOCKET, _ option: SRT_SOCKOPT, _ value: String) throws {
        try value.withCString { pointer in
            try set(sock, option, pointer, strlen(pointer))
        }
    }

    /// Resolves `host:port` (IPv4 or IPv6) and passes the first address to `body`.
    private func withAddress(host: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, Int32) throws -> Void) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result, let address = info.pointee.ai_addr else {
            throw PVSRTError.resolveFailed(host)
        }
        defer { freeaddrinfo(result) }
        try body(address, Int32(info.pointee.ai_addrlen))
    }

    private static func lastError() -> String {
        String(cString: srt_getlasterror_str())
    }
}
