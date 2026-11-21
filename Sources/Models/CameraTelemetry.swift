import Foundation

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
    var ambientLumens: Double = 1000
    var hasLidarSupport: Bool = false
    var detectedShotKind: ShotKind = .medium
    var lighting: LightingCondition = .balanced
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
