import SwiftUI
import AVFoundation
import UIKit
import Combine

final class CameraPreviewUIView: UIView {
    private let zebra = ZebraOverlay()
    private var highlightSubscription: AnyCancellable?

    func observeHighlights(_ regions: HighlightRegions) {
        zebra.preview = previewLayer
        zebra.backgroundColor = .clear
        zebra.isOpaque = false
        zebra.isUserInteractionEnabled = false
        zebra.contentMode = .redraw
        zebra.frame = bounds
        zebra.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(zebra)
        highlightSubscription = regions.$rects.sink { [weak self] rects in
            self?.zebra.rects = rects
            self?.zebra.setNeedsDisplay()
        }
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct ProCameraPreviewView: UIViewRepresentable {
    let highlights: HighlightRegions
    let session: AVCaptureSession
    let onInspectFocus: (CGPoint, AVCaptureVideoPreviewLayer) -> Void
    let onFocusTap: (CGPoint, CGPoint) -> Void
    let onLongPressLock: (CGPoint, CGPoint) -> Void
    let onPinchZoom: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInspectFocus: onInspectFocus,
            onFocusTap: onFocusTap,
            onLongPressLock: onLongPressLock,
            onPinchZoom: onPinchZoom
        )
    }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.observeHighlights(highlights)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        view.addGestureRecognizer(longPress)
        tap.require(toFail: longPress)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        context.coordinator.onInspectFocus = onInspectFocus
        context.coordinator.onFocusTap = onFocusTap
        context.coordinator.onLongPressLock = onLongPressLock
        context.coordinator.onPinchZoom = onPinchZoom
    }

    final class Coordinator: NSObject {
        weak var previewView: CameraPreviewUIView?
        var onInspectFocus: (CGPoint, AVCaptureVideoPreviewLayer) -> Void
        var onFocusTap: (CGPoint, CGPoint) -> Void
        var onLongPressLock: (CGPoint, CGPoint) -> Void
        var onPinchZoom: (CGFloat, UIGestureRecognizer.State) -> Void

        init(
            onInspectFocus: @escaping (CGPoint, AVCaptureVideoPreviewLayer) -> Void,
            onFocusTap: @escaping (CGPoint, CGPoint) -> Void,
            onLongPressLock: @escaping (CGPoint, CGPoint) -> Void,
            onPinchZoom: @escaping (CGFloat, UIGestureRecognizer.State) -> Void
        ) {
            self.onInspectFocus = onInspectFocus
            self.onFocusTap = onFocusTap
            self.onLongPressLock = onLongPressLock
            self.onPinchZoom = onPinchZoom
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let screenPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
            onFocusTap(devicePoint, screenPoint)
            onInspectFocus(screenPoint, view.previewLayer)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = previewView else { return }
            let screenPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
            onLongPressLock(devicePoint, screenPoint)
            onInspectFocus(screenPoint, view.previewLayer)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            onPinchZoom(gesture.scale, gesture.state)
        }
    }
}
