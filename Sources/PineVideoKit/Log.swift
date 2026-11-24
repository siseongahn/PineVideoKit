//
//  Log.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

import os

/// Unified logging for PineVideoKit (subsystem `com.digipine.PineVideoKit`).
enum PVLog {
    private static let logger = Logger(subsystem: "com.digipine.PineVideoKit", category: "PineVideoKit")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
