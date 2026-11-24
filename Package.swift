// swift-tools-version:6.0
//
// PineVideoKit — low-latency camera → H.264/HEVC + AAC → MPEG-TS → SRT publishing for Apple platforms.
//
// Copyright (c) 2026 DigiPine. Licensed under the MIT License.
// This software is provided "AS IS", without warranty of any kind, express or implied.
// See the LICENSE file in the project root for the full license text.
import PackageDescription

let package = Package(
    name: "PineVideoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PineVideoKit", targets: ["PineVideoKit"])
    ],
    dependencies: [
        // Prebuilt libsrt (+ OpenSSL) xcframework. libsrt is MPL-2.0.
        .package(url: "https://github.com/HaishinKit/libsrt-xcframework.git", exact: "1.5.7")
    ],
    targets: [
        .target(
            name: "PineVideoKit",
            dependencies: [.product(name: "libsrt", package: "libsrt-xcframework")]
        ),
        // macOS command-line sender with a synthetic test pattern; used to verify and measure the
        // encoder → muxer → SRT path without a camera or a phone.
        .executableTarget(
            name: "pvk-selftest",
            dependencies: ["PineVideoKit"]
        ),
        .testTarget(
            name: "PineVideoKitTests",
            dependencies: ["PineVideoKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
