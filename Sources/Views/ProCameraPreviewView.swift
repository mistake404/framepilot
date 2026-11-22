import SwiftUI
import AVFoundation
import UIKit

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct ProCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocusTap: (CGPoint, CGPoint) -> Void
    let onLongPressLock: (CGPoint, CGPoint) -> Void
    let onPinchZoom: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
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

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        view.addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        context.coordinator.onFocusTap = onFocusTap
        context.coordinator.onLongPressLock = onLongPressLock
        context.coordinator.onPinchZoom = onPinchZoom
    }

    final class Coordinator: NSObject {
        weak var previewView: CameraPreviewUIView?
        var onFocusTap: (CGPoint, CGPoint) -> Void
        var onLongPressLock: (CGPoint, CGPoint) -> Void
        var onPinchZoom: (CGFloat, UIGestureRecognizer.State) -> Void

        init(
            onFocusTap: @escaping (CGPoint, CGPoint) -> Void,
            onLongPressLock: @escaping (CGPoint, CGPoint) -> Void,
            onPinchZoom: @escaping (CGFloat, UIGestureRecognizer.State) -> Void
        ) {
            self.onFocusTap = onFocusTap
            self.onLongPressLock = onLongPressLock
            self.onPinchZoom = onPinchZoom
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let screenPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
            onFocusTap(devicePoint, screenPoint)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = previewView else { return }
            let screenPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
            onLongPressLock(devicePoint, screenPoint)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            onPinchZoom(gesture.scale, gesture.state)
        }
    }
}
