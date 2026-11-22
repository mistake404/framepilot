import Foundation
import CoreImage

struct CubeLUTLoader {
    private static let lutColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    private let dimension: Int
    private let rgba: NSData
    private let domainMin: SIMD3<Float>
    private let domainScale: SIMD3<Float>

    enum LoadError: LocalizedError {
        case invalidCube

        var errorDescription: String? { "Escolhe um ficheiro .cube com uma LUT 3D válida." }
    }

    static func load(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard url.pathExtension.lowercased() == "cube", values.isRegularFile == true,
              values.isSymbolicLink != true, let size = values.fileSize, size <= 32 * 1024 * 1024 else {
            throw LoadError.invalidCube
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    private static func parse(_ text: String) throws -> Self {
        var dimension = 0
        var expectedCount = 0
        var rgba: [Float32] = []
        var lower = SIMD3<Float>.zero
        var upper = SIMD3<Float>(repeating: 1)

        let text = text.drop(while: { $0 == "\u{FEFF}" })
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.prefix(while: { $0 != "#" }).split(whereSeparator: \.isWhitespace)
            guard let key = fields.first else { continue }
            switch key {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard dimension == 0, fields.count == 2, let size = Int(fields[1]), (2...65).contains(size) else {
                    throw LoadError.invalidCube
                }
                dimension = size
                expectedCount = 4 * size * size * size
                rgba.reserveCapacity(expectedCount)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard rgba.isEmpty, let value = triple(fields.dropFirst()) else { throw LoadError.invalidCube }
                if key == "DOMAIN_MIN" { lower = value } else { upper = value }
            case "LUT_3D_INPUT_RANGE":
                guard rgba.isEmpty, fields.count == 3, let minValue = Float(fields[1]),
                      let maxValue = Float(fields[2]), minValue.isFinite, maxValue.isFinite else {
                    throw LoadError.invalidCube
                }
                lower = SIMD3(repeating: minValue)
                upper = SIMD3(repeating: maxValue)
            default:
                guard rgba.count < expectedCount, let value = triple(fields[...]) else {
                    throw LoadError.invalidCube
                }
                // .cube and Core Image both store red as the fastest-changing grid axis.
                rgba.append(value.x)
                rgba.append(value.y)
                rgba.append(value.z)
                rgba.append(1)
            }
        }
        let width = upper - lower
        let scale = SIMD3<Float>(repeating: 1) / width
        let offset = -lower * scale
        guard dimension > 0, rgba.count == expectedCount, scale.x > 0, scale.y > 0, scale.z > 0,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { throw LoadError.invalidCube }
        return Self(dimension: dimension, rgba: rgba.withUnsafeBytes { Data($0) as NSData },
                    domainMin: lower, domainScale: scale)
    }

    private static func triple(_ fields: ArraySlice<Substring>) -> SIMD3<Float>? {
        let i = fields.startIndex
        guard fields.count == 3, let r = Float(fields[i]), let g = Float(fields[i + 1]),
              let b = Float(fields[i + 2]), r.isFinite, g.isFinite, b.isFinite else { return nil }
        return SIMD3(r, g, b)
    }

    func apply(to image: CIImage) -> CIImage {
        // .cube has no colour-space metadata. Use display-referred sRGB component values.
        guard let colorSpace = Self.lutColorSpace, let workingSpace = Self.workingColorSpace,
              let encoded = image.matchedFromWorkingSpace(to: colorSpace),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        let input: CIImage
        if domainMin == .zero, domainScale == SIMD3<Float>(repeating: 1) {
            input = encoded
        } else {
            let offset = -domainMin * domainScale
            input = encoded.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(domainScale.x), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(domainScale.y), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(domainScale.z), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(offset.x), y: CGFloat(offset.y), z: CGFloat(offset.z), w: 0)
            ])
        }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(rgba, forKey: "inputCubeData")
        filter.setValue(workingSpace, forKey: "inputColorSpace")
        return filter.outputImage?.matchedToWorkingSpace(from: colorSpace) ?? image
    }
}
