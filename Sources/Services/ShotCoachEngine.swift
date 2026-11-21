import Foundation

enum ShotCoachEngine {

    static func classifyLighting(lumens: Double) -> LightingCondition {
        if lumens < 420 { return .low }
        if lumens > 1850 { return .bright }
        return .balanced
    }

    static func detectShotKind(distanceMeters: Double?, pitchDegrees: Double) -> ShotKind {
        if pitchDegrees >= 16 { return .lowAngle }
        if pitchDegrees <= -28 { return .highAngle }

        guard let d = distanceMeters else {
            return .medium
        }
        if d < 0.6 { return .detail }
        if d < 1.2 { return .closeUp }
        if d < 2.4 { return .medium }
        return .establishing
    }

    static func evaluate(
        distanceMeters: Double?,
        pitchDegrees: Double,
        rollDegrees: Double,
        lighting: LightingCondition,
        target: ShotTemplate?
    ) -> CoachingAdvice {
        guard let target else {
            return evaluateFreeMode(
                distanceMeters: distanceMeters,
                pitchDegrees: pitchDegrees,
                rollDegrees: rollDegrees,
                lighting: lighting
            )
        }

        // 1. Roll score (horizon)
        let rollExcess = max(0, abs(rollDegrees) - target.maxRollDegrees)
        let rollScore = max(0.0, 1.0 - (rollExcess / 12.0))

        // 2. Pitch score
        let pitchDelta: Double
        if pitchDegrees < target.targetPitchRange.lowerBound {
            pitchDelta = target.targetPitchRange.lowerBound - pitchDegrees // positive = tilt up
        } else if pitchDegrees > target.targetPitchRange.upperBound {
            pitchDelta = target.targetPitchRange.upperBound - pitchDegrees // negative = tilt down
        } else {
            pitchDelta = 0
        }
        let pitchScore = max(0.0, 1.0 - (abs(pitchDelta) / 25.0))

        // 3. Distance score (LiDAR)
        let distanceDelta: Double?
        let distanceScore: Double
        if let d = distanceMeters {
            if d < target.targetDistanceRange.lowerBound {
                distanceDelta = target.targetDistanceRange.lowerBound - d // positive = step back
            } else if d > target.targetDistanceRange.upperBound {
                distanceDelta = target.targetDistanceRange.upperBound - d // negative = step closer
            } else {
                distanceDelta = 0
            }
            distanceScore = max(0.0, 1.0 - (abs(distanceDelta ?? 0) / 1.5))
        } else {
            distanceDelta = nil
            distanceScore = 0.65
        }

        let combinedScore = (rollScore * 0.25) + (pitchScore * 0.40) + (distanceScore * 0.35)
        let isLocked = rollExcess == 0 && abs(pitchDelta) <= 2.0 && abs(distanceDelta ?? 0) <= 0.12

        if isLocked {
            return CoachingAdvice(
                primaryInstruction: "Ângulo perfeito — dispara!",
                secondaryHint: "\(target.movementHint) • \(target.directorTip)",
                alignmentScore: 1.0,
                isLocked: true
            )
        }

        // Prioritize the single most actionable instruction
        if rollExcess > 1.5 {
            let dir = rollDegrees > 0 ? "para a esquerda" : "para a direita"
            return CoachingAdvice(
                primaryInstruction: "Nivela o horizonte (\(dir))",
                secondaryHint: target.directorTip,
                alignmentScore: combinedScore,
                isLocked: false
            )
        }

        if abs(pitchDelta) > 3.0 {
            let deg = Int(abs(pitchDelta).rounded())
            let instruction = pitchDelta > 0
                ? "Inclina mais para cima (+\(deg)°)"
                : "Aponta mais para baixo (-\(deg)°)"
            return CoachingAdvice(
                primaryInstruction: instruction,
                secondaryHint: "Alvo: \(target.pitchLabel) • \(target.movementHint)",
                alignmentScore: combinedScore,
                isLocked: false
            )
        }

        if let dd = distanceDelta, abs(dd) > 0.15 {
            let meters = abs(dd)
            let formatted = meters < 1.0
                ? "\(Int((meters * 100).rounded())) cm"
                : String(format: "%.1f m", meters)
            let instruction = dd > 0
                ? "Afasta-te cerca de \(formatted)"
                : "Aproxima-te cerca de \(formatted)"
            return CoachingAdvice(
                primaryInstruction: instruction,
                secondaryHint: "Distância ideal: \(target.distanceLabel)",
                alignmentScore: combinedScore,
                isLocked: false
            )
        }

        return CoachingAdvice(
            primaryInstruction: "Ajuste fino no enquadramento",
            secondaryHint: target.directorTip,
            alignmentScore: combinedScore,
            isLocked: false
        )
    }

    private static func evaluateFreeMode(
        distanceMeters: Double?,
        pitchDegrees: Double,
        rollDegrees: Double,
        lighting: LightingCondition
    ) -> CoachingAdvice {
        let detected = detectShotKind(distanceMeters: distanceMeters, pitchDegrees: pitchDegrees)

        if abs(rollDegrees) > 3.5 {
            let dir = rollDegrees > 0 ? "esquerda" : "direita"
            return CoachingAdvice(
                primaryInstruction: "Horizonte inclinado — corrige à \(dir)",
                secondaryHint: "Plano detetado: \(detected.rawValue)",
                alignmentScore: 0.55,
                isLocked: false
            )
        }

        if lighting == .low {
            return CoachingAdvice(
                primaryInstruction: "\(detected.rawValue) • Pouca luz detetada",
                secondaryHint: "Procura luz lateral ou aproxima o sujeito de uma janela.",
                alignmentScore: 0.75,
                isLocked: false
            )
        }

        return CoachingAdvice(
            primaryInstruction: "\(detected.rawValue) pronto",
            secondaryHint: "Horizonte nivelado • Experimenta variar para Contrapicado ou Detalhe.",
            alignmentScore: 0.92,
            isLocked: true
        )
    }
}
