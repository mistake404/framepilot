import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct SceneContinuityReference: Equatable {
    let shotTitle: String
    let kelvin: Float
    let relativeEV: Double
}

struct ContinuityAlert: Equatable {
    let message: String
    let suggestLockWhiteBalance: Bool
}

struct TakeVerdict: Equatable, Identifiable {
    let id = UUID()
    let shotId: String
    let shotTitle: String
    let durationSeconds: Double
    let targetSeconds: Double
    let stabilityPercent: Int
    let isApproved: Bool
    let headline: String
    let detail: String
    let canRetake: Bool
}

enum SceneDirectorAnalyzer {
    /// Estimates backlight by comparing average luma inside the subject/face rect
    /// against the surrounding frame and clipped highlight ratio.
    static func isBacklit(buffer: CVPixelBuffer, subjectRectTopLeft: CGRect?) -> Bool {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        guard HighlightRegions.supports(type),
              CVPixelBufferGetPlaneCount(buffer) > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width >= 16, height >= 16 else { return false }

        let fullRange = (type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let lumaMin: Double = fullRange ? 0.0 : 16.0
        let lumaSpan: Double = fullRange ? 255.0 : 219.0
        let clipThreshold: UInt8 = fullRange ? 243 : 225

        // Default to center-upper portrait zone when no explicit subject rect is available.
        let subject = subjectRectTopLeft ?? CGRect(x: 0.30, y: 0.22, width: 0.40, height: 0.40)
        let step = max(2, max(width, height) / 48)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var subjectSum: Double = 0
        var subjectCount = 0
        var bgSum: Double = 0
        var bgCount = 0
        var bgClipped = 0

        for y in Swift.stride(from: 0, to: height, by: step) {
            let ny = CGFloat(y) / CGFloat(height)
            let row = bytes + y * stride
            for x in Swift.stride(from: 0, to: width, by: step) {
                let nx = CGFloat(x) / CGFloat(width)
                let raw = row[x]
                let norm = max(0.0, min(1.0, (Double(raw) - lumaMin) / lumaSpan))
                if subject.contains(CGPoint(x: nx, y: ny)) {
                    subjectSum += norm
                    subjectCount += 1
                } else {
                    bgSum += norm
                    bgCount += 1
                    if raw >= clipThreshold {
                        bgClipped += 1
                    }
                }
            }
        }

        guard subjectCount >= 4, bgCount >= 8 else { return false }
        let subjectAvg = subjectSum / Double(subjectCount)
        let bgAvg = bgSum / Double(bgCount)
        let clippedRatio = Double(bgClipped) / Double(bgCount)

        // Backlit when subject is dark while background is bright or substantially clipped.
        return subjectAvg < 0.34 && (bgAvg - subjectAvg > 0.32 || clippedRatio > 0.18)
    }

    /// Computes approximate color temperature (Kelvin) safely by clamping gains to device bounds.
    static func safeKelvin(for device: AVCaptureDevice) -> Float? {
        let maxGain = device.maxWhiteBalanceGain
        guard maxGain >= 1.0 else { return nil }
        let raw = device.deviceWhiteBalanceGains
        guard raw.redGain.isFinite, raw.greenGain.isFinite, raw.blueGain.isFinite else { return nil }
        let clamped = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(maxGain, max(1.0, raw.redGain)),
            greenGain: min(maxGain, max(1.0, raw.greenGain)),
            blueGain: min(maxGain, max(1.0, raw.blueGain))
        )
        let temp = device.temperatureAndTintValues(for: clamped).temperature
        return temp.isFinite && temp > 1000 && temp < 20000 ? temp : nil
    }

    /// Relative exposure value proxy (log2 of exposureDuration * ISO). Higher means brighter scene exposure.
    static func relativeEV(for device: AVCaptureDevice) -> Double? {
        let iso = Double(device.iso)
        let seconds = device.exposureDuration.seconds
        guard iso > 0, seconds.isFinite, seconds > 0 else { return nil }
        return log2(1.0 / (seconds * (iso / 100.0)))
    }

    /// Evaluates color and exposure drift against the previous shot in the same pack.
    static func continuityAlert(
        currentKelvin: Float?,
        currentEV: Double?,
        whiteBalanceLocked: Bool,
        reference: SceneContinuityReference?
    ) -> ContinuityAlert? {
        guard let ref = reference else { return nil }
        if !whiteBalanceLocked, let k = currentKelvin, abs(k - ref.kelvin) > 850 {
            return ContinuityAlert(
                message: "Cor diferente do plano anterior — bloqueia Brancos",
                suggestLockWhiteBalance: true
            )
        }
        if let ev = currentEV, abs(ev - ref.relativeEV) > 1.8 {
            let direction = ev > ref.relativeEV ? "mais clara" : "mais escura"
            return ContinuityAlert(
                message: "Luz \(direction) do que em «\(ref.shotTitle)»",
                suggestLockWhiteBalance: false
            )
        }
        return nil
    }
}

final class TakeMetricsTracker {
    private var totalSamples = 0
    private var stableSamples = 0
    private var hadAudioClipping = false
    private var hadBacklight = false
    private var peakHighlightRects = 0

    func reset() {
        totalSamples = 0
        stableSamples = 0
        hadAudioClipping = false
        hadBacklight = false
        peakHighlightRects = 0
    }

    func recordSample(pace: MotionPace, isAudioClipping: Bool, isBacklit: Bool, highlightCount: Int) {
        totalSamples += 1
        if pace != .tooFast {
            stableSamples += 1
        }
        if isAudioClipping { hadAudioClipping = true }
        if isBacklit { hadBacklight = true }
        if highlightCount > peakHighlightRects { peakHighlightRects = highlightCount }
    }

    func evaluate(
        shotId: String,
        shotTitle: String,
        durationSeconds: Double,
        targetSeconds: Double,
        canRetake: Bool
    ) -> TakeVerdict {
        let stability = totalSamples > 0 ? Int((Double(stableSamples) / Double(totalSamples) * 100.0).rounded()) : 100
        var issues: [String] = []

        if stability < 78 {
            issues.append("câmara rápida/tremida (\(stability)% estável)")
        }
        if hadAudioClipping {
            issues.append("áudio saturou")
        }
        if hadBacklight {
            issues.append("contraluz forte")
        }
        if targetSeconds >= 1.5, durationSeconds < targetSeconds * 0.65 {
            issues.append(String(format: "curto demais (%.1fs vs %.1fs)", durationSeconds, targetSeconds))
        }

        let durationText = String(format: "%.1fs", durationSeconds)
        if issues.isEmpty {
            let summary = "\(durationText) • \(stability)% estável • som limpo"
            return TakeVerdict(
                shotId: shotId,
                shotTitle: shotTitle,
                durationSeconds: durationSeconds,
                targetSeconds: targetSeconds,
                stabilityPercent: stability,
                isApproved: true,
                headline: "Boa! Take aprovado",
                detail: summary,
                canRetake: canRetake
            )
        } else {
            return TakeVerdict(
                shotId: shotId,
                shotTitle: shotTitle,
                durationSeconds: durationSeconds,
                targetSeconds: targetSeconds,
                stabilityPercent: stability,
                isApproved: false,
                headline: "Dá para melhorar",
                detail: "\(durationText) • " + issues.prefix(2).joined(separator: " • "),
                canRetake: canRetake
            )
        }
    }
}
