import Foundation
import CoreGraphics

enum ShotCoachEngine {

    static func classifyLighting(lumens: Double) -> LightingCondition {
        if lumens < 420 { return .low }
        if lumens > 1850 { return .bright }
        return .balanced
    }

    static func classifyMotionPace(speedDegPerSec: Double) -> MotionPace {
        if speedDegPerSec < 6.0 { return .still }
        if speedDegPerSec <= 28.0 { return .cinematic }
        return .tooFast
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
        motionPace: MotionPace,
        detectedFaceRect: CGRect?,
        detectedSubjectRect: CGRect? = nil,
        isBacklit: Bool = false,
        isRecording: Bool,
        wasLocked: Bool = false,
        target: ShotTemplate?
    ) -> CoachingAdvice {
        // Live recording motion guard takes priority so video clips stay cinematic
        if isRecording && motionPace == .tooFast {
            return CoachingAdvice(
                primaryInstruction: "Abranda o movimento da câmara",
                secondaryHint: "Mantém a rotação suave para um resultado cinematográfico.",
                alignmentScore: 0.45,
                isLocked: false
            )
        }

        // Face framing check (headroom & Reels bottom caption safe zone)
        if let face = detectedFaceRect {
            let tightShot = target?.kind == .closeUp || target?.kind == .detail
            let minHeadroom: CGFloat = tightShot ? 0.02 : 0.08
            if face.minY < minHeadroom {
                return CoachingAdvice(
                    primaryInstruction: "Dá mais ar acima da cabeça",
                    secondaryHint: "Inclina ligeiramente para cima ou afasta-te um pouco.",
                    alignmentScore: 0.68,
                    isLocked: false
                )
            }
            if !tightShot && face.midY > 0.68 {
                return CoachingAdvice(
                    primaryInstruction: "Sobe o rosto para o terço superior",
                    secondaryHint: "Evita a zona inferior de legendas no Reels/TikTok.",
                    alignmentScore: 0.68,
                    isLocked: false
                )
            }
        }

        let subjectCrowdedEdge: Bool
        if !isRecording, detectedFaceRect == nil, let subject = detectedSubjectRect,
           subject.width < 0.75, subject.height < 0.70 {
            subjectCrowdedEdge = subject.minX < 0.02 || subject.maxX > 0.98 || subject.minY < 0.02 || subject.maxY > 0.92
        } else {
            subjectCrowdedEdge = false
        }

        guard let target else {
            return evaluateFreeMode(
                distanceMeters: distanceMeters,
                pitchDegrees: pitchDegrees,
                rollDegrees: rollDegrees,
                lighting: lighting,
                hasFace: detectedFaceRect != nil
            )
        }

        // 1. Roll score (horizon) — gracefully relaxed/disabled on steep picado (top-down) & contrapicado
        let absPitch = abs(pitchDegrees)
        let handheldRollFloor = max(2.0, target.maxRollDegrees)
        let baseMaxRoll: Double
        if absPitch >= 42.0 {
            baseMaxRoll = 90.0
        } else if absPitch >= 20.0 {
            baseMaxRoll = handheldRollFloor * 1.8
        } else {
            baseMaxRoll = handheldRollFloor
        }
        // Hysteresis prevents rapid green/yellow flickering at the edge of the target zone
        let effectiveMaxRoll = wasLocked ? (baseMaxRoll + 2.0) : baseMaxRoll
        let rollExcess = max(0, abs(rollDegrees) - effectiveMaxRoll)
        let rollScore = max(0.0, 1.0 - (rollExcess / 12.0))

        // 2. Pitch score
        let pitchDelta: Double
        if pitchDegrees < target.targetPitchRange.lowerBound {
            pitchDelta = target.targetPitchRange.lowerBound - pitchDegrees
        } else if pitchDegrees > target.targetPitchRange.upperBound {
            pitchDelta = target.targetPitchRange.upperBound - pitchDegrees
        } else {
            pitchDelta = 0
        }
        let pitchScore = max(0.0, 1.0 - (abs(pitchDelta) / 25.0))

        // 3. Distance score (LiDAR) — when unavailable (e.g. front camera), do not penalize the alignment ring
        let distanceDelta: Double?
        let distanceScore: Double
        if let d = distanceMeters {
            if d < target.targetDistanceRange.lowerBound {
                distanceDelta = target.targetDistanceRange.lowerBound - d
            } else if d > target.targetDistanceRange.upperBound {
                distanceDelta = target.targetDistanceRange.upperBound - d
            } else {
                distanceDelta = 0
            }
            distanceScore = max(0.0, 1.0 - (abs(distanceDelta ?? 0) / 1.5))
        } else {
            distanceDelta = nil
            distanceScore = 1.0
        }

        let pitchLockTol = wasLocked ? 5.5 : 3.5
        let distLockTol = wasLocked ? 0.25 : 0.15
        let rollLockTol = 0.5
        let combinedScore = (rollScore * 0.25) + (pitchScore * 0.40) + (distanceScore * 0.35)
        let isLocked = rollExcess <= rollLockTol && abs(pitchDelta) <= pitchLockTol && abs(distanceDelta ?? 0) <= distLockTol

        if target.preferredMode == .photo && motionPace == .tooFast {
            return CoachingAdvice(
                primaryInstruction: "Estabiliza a mão para foto nítida",
                secondaryHint: "Mantém o iPhone parado 1 segundo antes de fotografar em 48MP.",
                alignmentScore: min(combinedScore, 0.7),
                isLocked: false
            )
        }

        if isLocked {
            let lockedTitle: String
            if isRecording {
                lockedTitle = "Gravação perfeita — mantém o ritmo"
            } else if target.preferredMode == .photo {
                lockedTitle = lighting == .low ? "Mão firme — fotografa (pouca luz)" : "Enquadramento perfeito — fotografa!"
            } else {
                lockedTitle = "Ângulo perfeito — dispara!"
            }
            let hint: String
            if !isRecording && isBacklit {
                hint = "Contraluz — roda 45° para a luz ou sobe +0,7 EV"
            } else if subjectCrowdedEdge {
                hint = "Dica: dá um pouco de margem ao sujeito • \(target.movementHint)"
            } else {
                hint = "\(target.movementHint) • \(target.directorTip)"
            }
            return CoachingAdvice(
                primaryInstruction: lockedTitle,
                secondaryHint: hint,
                alignmentScore: 1.0,
                isLocked: true
            )
        }

        if rollExcess > rollLockTol {
            let dir = rollDegrees > 0 ? "para a esquerda" : "para a direita"
            return CoachingAdvice(
                primaryInstruction: "Nivela o horizonte (\(dir))",
                secondaryHint: target.directorTip,
                alignmentScore: combinedScore,
                isLocked: false
            )
        }

        if abs(pitchDelta) > pitchLockTol {
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

        if let dd = distanceDelta, abs(dd) > distLockTol {
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
        lighting: LightingCondition,
        hasFace: Bool
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

        let faceTag = hasFace ? "Rosto enquadrado • " : ""
        return CoachingAdvice(
            primaryInstruction: "\(detected.rawValue) pronto",
            secondaryHint: "\(faceTag)Horizonte nivelado • Varia para Contrapicado ou Detalhe.",
            alignmentScore: 0.92,
            isLocked: true
        )
    }
}
