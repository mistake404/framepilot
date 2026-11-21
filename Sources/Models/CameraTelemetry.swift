import Foundation
import CoreGraphics

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
