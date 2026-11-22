import AVFoundation
import Combine
import UIKit

final class HighlightRegions: ObservableObject {
    @Published var rects: [CGRect] = []

    static func supports(_ type: OSType) -> Bool {
        type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    // Sample luma in small cells and coalesce adjacent bright cells within each row.
    static func sample(_ buffer: CVPixelBuffer) -> [CGRect] {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        guard supports(type), CVPixelBufferGetPlaneCount(buffer) > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cell = max(1, max(width, height) / 96)
        let threshold: UInt8 = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 243 : 225
        var rects: [CGRect] = []
        for y in Swift.stride(from: 0, to: height, by: cell) {
            let row = base.assumingMemoryBound(to: UInt8.self) + min(height - 1, y + cell / 2) * stride
            var run: Int?
            for x in Swift.stride(from: 0, to: width, by: cell) {
                if row[min(width - 1, x + cell / 2)] >= threshold {
                    if run == nil { run = x }
                } else if let start = run {
                    rects.append(CGRect(x: start, y: y, width: x - start, height: min(cell, height - y)))
                    run = nil
                }
            }
            if let start = run {
                rects.append(CGRect(x: start, y: y, width: width - start, height: min(cell, height - y)))
            }
        }
        return rects
    }
}

final class ZebraOverlay: UIView {
    weak var preview: AVCaptureVideoPreviewLayer?
    var rects: [CGRect] = []

    override func draw(_ rect: CGRect) {
        guard !rects.isEmpty, let preview, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rects.map { preview.layerRectConverted(fromMetadataOutputRect: $0) })
        context.setLineWidth(2)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.68).cgColor)
        for x in stride(from: -bounds.height, through: bounds.width, by: 8) {
            context.move(to: CGPoint(x: x, y: bounds.height))
            context.addLine(to: CGPoint(x: x + bounds.height, y: 0))
        }
        context.strokePath()
    }
}
