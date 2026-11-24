//
//  PVPreviewView.swift
//  PineVideoKit
//
//  Copyright (c) 2026 DigiPine. Licensed under the MIT License.
//  This software is provided "AS IS", without warranty of any kind, express or implied.
//  See the LICENSE file in the project root for the full license text.
//

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Camera preview backed by AVCaptureVideoPreviewLayer: frames go straight from the capture
/// session to the screen, independent of (and with no latency from) the encoding pipeline.
public final class PVPreviewView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    public var videoGravity: AVLayerVideoGravity {
        get { previewLayer.videoGravity }
        set { previewLayer.videoGravity = newValue }
    }

    private var rotationAngle: CGFloat = 0
    // Only touched on the main actor and in deinit (after the last main-actor use).
    nonisolated(unsafe) private var runningObserver: (any NSObjectProtocol)?

    deinit {
        if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) }
    }

    /// Shows `source`'s session, rotated by `rotationAngle` degrees (match the capture configuration).
    ///
    /// The preview layer only gets a connection once the session has a camera input, which is
    /// usually after the view is created. Otherwise the layer keeps iOS's default (portrait, 90°)
    /// and a landscape UI shows a sideways picture. So the angle is re-applied whenever the
    /// session starts running and on every layout pass.
    public func attach(_ source: PVCaptureSource, rotationAngle: CGFloat = 0) {
        self.rotationAngle = rotationAngle
        if previewLayer.session !== source.session {
            previewLayer.session = source.session
            if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) }
            runningObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: source.session, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRotation() }
            }
        }
        applyRotation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    private func applyRotation() {
        guard let connection = previewLayer.connection,
              connection.videoRotationAngle != rotationAngle,
              connection.isVideoRotationAngleSupported(rotationAngle) else { return }
        connection.videoRotationAngle = rotationAngle
    }
}

/// SwiftUI wrapper for `PVPreviewView`.
public struct PVPreview: UIViewRepresentable {
    private let source: PVCaptureSource
    private let rotationAngle: CGFloat
    private let videoGravity: AVLayerVideoGravity

    public init(source: PVCaptureSource, rotationAngle: CGFloat = 0, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.source = source
        self.rotationAngle = rotationAngle
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> PVPreviewView {
        let view = PVPreviewView()
        view.backgroundColor = .black
        view.videoGravity = videoGravity
        view.attach(source, rotationAngle: rotationAngle)
        return view
    }

    public func updateUIView(_ view: PVPreviewView, context: Context) {
        view.videoGravity = videoGravity
        view.attach(source, rotationAngle: rotationAngle)
    }
}
#endif
