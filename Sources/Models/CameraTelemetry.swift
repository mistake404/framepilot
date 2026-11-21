import Foundation
import CoreGraphics

enum AspectMask: String, CaseIterable {
    case full = "9:16"
    case feed4x5 = "4:5"
    case cinema16x9 = "16:9"

    var next: AspectMask {
        switch self {
        case .full: return .feed4x5
        case .feed4x5: return .cinema16x9
        case .cinema16x9: return .full
        }
    }

    /// Width / Height ratio when held in portrait
    var portraitRatio: CGFloat? {
        switch self {
        case .full: return nil
        case .feed4x5: return 4.0 / 5.0
        case .cinema16x9: return 16.0 / 9.0
        }
    }
}

enum OverlayMode: String, CaseIterable {
    case thirds = "Terços"
    case reelsSafeZone = "Reels"
    case none = "Limpo"

    var next: OverlayMode {
        switch self {
        case .thirds: return .reelsSafeZone
        case .reelsSafeZone: return .none
        case .none: return .thirds
        }
    }

    var iconName: String {
        switch self {
        case .thirds: return "grid"
        case .reelsSafeZone: return "rectangle.inset.filled"
        case .none: return "eye.slash"
        }
    }
}

enum LightingCondition: String {
    case low = "Luz baixa"
    case balanced = "Luz equilibrada"
    case bright = "Luz intensa"

    var iconName: String {
        switch self {
        case .low: return "moon.fill"
        case .balanced: return "sun.max.fill"
        case .bright: return "sun.max.trianglebadge.exclamationmark"
        }
    }
}

enum MotionPace: String {
    case still = "Estático"
    case cinematic = "Ritmo fluido"
    case tooFast = "Abranda o movimento"
}

struct CoachingAdvice: Equatable {
    let primaryInstruction: String
    let secondaryHint: String
    let alignmentScore: Double // 0.0 ... 1.0
    let isLocked: Bool

    static let idle = CoachingAdvice(
        primaryInstruction: "Aponta para o sujeito",
        secondaryHint: "A calibrar sensores LiDAR e giroscópio...",
        alignmentScore: 0.0,
        isLocked: false
    )
}

struct CameraTelemetry {
    var lidarDistanceMeters: Double?
    var pitchDegrees: Double = 0
    var rollDegrees: Double = 0
    var motionSpeedDegPerSec: Double = 0
    var hasLidarSupport: Bool = false
    var detectedShotKind: ShotKind = .medium
    var lighting: LightingCondition = .balanced
    var motionPace: MotionPace = .still
    var detectedFaceRect: CGRect? // normalized top-left 0...1
    var advice: CoachingAdvice = .idle

    var formattedDistance: String {
        guard let d = lidarDistanceMeters else { return "-- m" }
        if d < 1.0 {
            return String(format: "%d cm", Int((d * 100).rounded()))
        }
        return String(format: "%.2f m", d)
    }

    var formattedPitch: String {
        let deg = Int(pitchDegrees.rounded())
        return deg > 0 ? "+\(deg)°" : "\(deg)°"
    }

    var formattedRoll: String {
        let deg = Int(rollDegrees.rounded())
        return deg > 0 ? "+\(deg)°" : "\(deg)°"
    }

    var isHorizonLevel: Bool {
        abs(rollDegrees) <= 2.5
    }
}
