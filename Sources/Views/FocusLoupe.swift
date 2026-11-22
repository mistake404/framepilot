import AVFoundation
import CoreImage
import SwiftUI

final class FocusLoupe: ObservableObject {
    static let diameter: CGFloat = 120
    @Published fileprivate(set) var image: CGImage?
    fileprivate(set) var touchPoint = CGPoint.zero

    private struct Request {
        let id = UUID()
        let lowerLeft: CGPoint
        let lowerRight: CGPoint
        let upperLeft: CGPoint
    }

    private let lock = NSLock()
    private var request: Request?
    // The analysis queue owns rendering and its refresh cadence.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame: CFTimeInterval = 0

    func inspect(at point: CGPoint, in preview: AVCaptureVideoPreviewLayer) {
        let side = Self.diameter / 3
        let bounds = preview.bounds
        guard bounds.width >= side, bounds.height >= side else { return }
        let x = min(max(bounds.minX, point.x - side / 2), bounds.maxX - side)
        let y = min(max(bounds.minY, point.y - side / 2), bounds.maxY - side)
        func devicePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            preview.captureDevicePointConverted(fromLayerPoint: CGPoint(x: x, y: y))
        }
        let next = Request(lowerLeft: devicePoint(x, y + side),
                           lowerRight: devicePoint(x + side, y + side),
                           upperLeft: devicePoint(x, y))
        lock.lock()
        request = next
        lock.unlock()
        touchPoint = point
        image = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.currentRequest()?.id == next.id else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        lock.lock()
        request = nil
        lock.unlock()
        if image != nil { image = nil }
    }

    private func currentRequest() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func render(_ buffer: CVPixelBuffer, from output: AVCaptureOutput, at time: CFTimeInterval) {
        guard time - lastFrame >= 0.1, let target = currentRequest() else { return }
        lastFrame = time
        let input = CIImage(cvPixelBuffer: buffer)
        // Use the preview's three corners to preserve rotation, mirror and aspect-fill cropping.
        func sourcePoint(_ point: CGPoint) -> CGPoint {
            let epsilon: CGFloat = 0.00001
            let box = CGRect(x: point.x - epsilon, y: point.y - epsilon, width: 2 * epsilon, height: 2 * epsilon)
            let pixel = output.outputRectConverted(fromMetadataOutputRect: box)
            return CGPoint(x: pixel.midX, y: input.extent.maxY - pixel.midY)
        }
        let origin = sourcePoint(target.lowerLeft)
        let right = sourcePoint(target.lowerRight)
        let top = sourcePoint(target.upperLeft)
        let pixels = Self.diameter * 3
        let toSource = CGAffineTransform(a: (right.x - origin.x) / pixels, b: (right.y - origin.y) / pixels,
                                         c: (top.x - origin.x) / pixels, d: (top.y - origin.y) / pixels,
                                         tx: origin.x, ty: origin.y)
        let determinant = toSource.a * toSource.d - toSource.b * toSource.c
        guard determinant.isFinite, abs(determinant) > 0.000001 else { return }
        let crop = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let detail = input.transformed(by: toSource.inverted()).cropped(to: crop)
        guard let frame = context.createCGImage(detail, from: crop) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentRequest()?.id == target.id else { return }
            self.image = frame
        }
    }
}

struct FocusLoupeView: View {
    @ObservedObject var loupe: FocusLoupe

    var body: some View {
        GeometryReader { geometry in
            if let image = loupe.image {
                let radius = FocusLoupe.diameter / 2
                let margin = radius + 8
                let point = loupe.touchPoint
                let y = point.y >= 2 * margin + 20 ? point.y - margin - 20 : point.y + margin + 20
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: 2 * radius, height: 2 * radius)
                    .overlay(alignment: .bottom) {
                        Text("3×").font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).background(.black.opacity(0.7)).clipShape(Capsule())
                            .padding(.bottom, 6)
                    }
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.yellow, lineWidth: 2) }
                    .position(x: min(max(margin, point.x), geometry.size.width - margin),
                              y: min(max(margin, y), geometry.size.height - margin))
                    .accessibilityLabel("Lupa de foco, três vezes")
            }
        }
        .ignoresSafeArea()
    }
}
