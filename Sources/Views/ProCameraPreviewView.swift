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

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocusTap: onFocusTap)
    }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        context.coordinator.onFocusTap = onFocusTap
    }

    final class Coordinator: NSObject {
        weak var previewView: CameraPreviewUIView?
        var onFocusTap: (CGPoint, CGPoint) -> Void

        init(onFocusTap: @escaping (CGPoint, CGPoint) -> Void) {
            self.onFocusTap = onFocusTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let screenPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
            onFocusTap(devicePoint, screenPoint)
        }
    }
}
