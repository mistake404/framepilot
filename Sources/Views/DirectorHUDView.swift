import SwiftUI

struct DirectorHUDView: View {
    @ObservedObject var hudStore: HUDTelemetryStore
    let activeShot: ShotTemplate?
    let overlayMode: OverlayMode
    let aspectMask: AspectMask
    let isRecording: Bool

    var body: some View {
        let telemetry = hudStore.telemetry

        ZStack {
            // Aspect ratio framing mask (4:5 Feed / 16:9 Cinema)
            if let ratio = aspectMask.portraitRatio {
                AspectMaskOverlay(widthOverHeight: ratio, label: aspectMask.rawValue)
                    .allowsHitTesting(false)
            }

            // Grid or Reels/TikTok Safe Zone overlay
            switch overlayMode {
            case .thirds:
                RuleOfThirdsGrid()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                    .allowsHitTesting(false)
            case .reelsSafeZone:
                ReelsSafeZoneOverlay()
                    .allowsHitTesting(false)
            case .none:
                EmptyView()
            }

            // Vision Face Tracking Brackets
            if let faceRect = telemetry.detectedFaceRect {
                FaceTrackerOverlay(
                    normalizedRect: faceRect,
                    isGoodFraming: faceRect.minY >= 0.08 && faceRect.midY <= 0.68
                )
                .allowsHitTesting(false)
            } else if let subjectRect = telemetry.detectedSubjectRect {
                SubjectTrackerOverlay(
                    normalizedRect: subjectRect,
                    isGoodFraming: subjectRect.minX >= 0.02 && subjectRect.maxX <= 0.98 &&
                        subjectRect.minY >= 0.02 && subjectRect.maxY <= 0.92
                )
                .allowsHitTesting(false)
            }

            // Holographic 3D Virtual Dolly Rail
            if telemetry.isDollyActive {
                VirtualDollyHologramOverlay(
                    shotKind: activeShot?.kind ?? .orbit,
                    movementHint: activeShot?.movementHint ?? "Deslize lateral",
                    progress: telemetry.dollyProgress,
                    alignmentScore: telemetry.dollyAlignmentScore
                )
                .allowsHitTesting(false)
            }

            // Center spatial reticle + artificial horizon (EMA-smoothed at 30Hz)
            CenterReticleView(
                rollDegrees: telemetry.rollDegrees,
                alignmentScore: telemetry.advice.alignmentScore,
                isLocked: telemetry.advice.isLocked,
                isHorizonLevel: telemetry.isHorizonLevel
            )
            .allowsHitTesting(false)

            // Live Audio VU Meter (left edge, video mode)
            if telemetry.hasAudioMonitor {
                HStack {
                    AudioMeterOverlay(
                        level: telemetry.audioLevel,
                        isClipping: telemetry.isAudioClipping
                    )
                    .padding(.leading, 10)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Live Vertical Pitch Gauge (Picado / Contrapicado visual guide)
            if let shot = activeShot {
                HStack {
                    Spacer()
                    PitchGaugeOverlay(
                        pitchDegrees: telemetry.pitchDegrees,
                        targetRange: shot.targetPitchRange
                    )
                    .padding(.trailing, 10)
                }
                .allowsHitTesting(false)
            }

            // Coaching pill + Motion Pace badge + Rack Focus indicator
            VStack(spacing: 6) {
                Spacer().frame(height: 68)

                CoachingBanner(
                    advice: telemetry.advice,
                    activeShot: activeShot,
                    telemetry: telemetry
                )
                .padding(.horizontal, 16)

                if isRecording, let progress = telemetry.recordingProgress, !telemetry.isDollyActive {
                    RecordingPaceBar(
                        movementHint: activeShot?.movementHint ?? "Ritmo constante",
                        elapsed: telemetry.recordingElapsed,
                        target: telemetry.recordingTargetSeconds,
                        progress: progress,
                        pace: telemetry.motionPace
                    )
                    .padding(.horizontal, 28)
                }

                if telemetry.isAudioClipping {
                    DirectorAlertPill(
                        icon: "exclamationmark.triangle.fill",
                        text: "Áudio a saturar — afasta o microfone",
                        tint: .red
                    )
                } else if let continuity = telemetry.continuityAlert {
                    DirectorAlertPill(
                        icon: continuity.suggestLockWhiteBalance ? "thermometer.medium" : "sun.max.trianglebadge.exclamationmark",
                        text: continuity.message,
                        tint: .orange
                    )
                }

                if isRecording || telemetry.motionPace != .still {
                    MotionPacePill(
                        pace: telemetry.motionPace,
                        speedDegPerSec: telemetry.motionSpeedDegPerSec
                    )
                }

                // Live Rack Focus active transition banner
                if let progress = telemetry.rackFocusProgress, let target = telemetry.rackFocusTargetLabel {
                    RackFocusActivePill(targetLabel: target, progress: progress)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer()
            }
            .allowsHitTesting(false)
        }
    }
}

private struct VirtualDollyHologramOverlay: View {
    let shotKind: ShotKind
    let movementHint: String
    let progress: Double
    let alignmentScore: Double

    var isLocked: Bool {
        alignmentScore > 0.8
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Curved Holographic Rail
                DollyRailShape(kind: shotKind)
                    .stroke(
                        LinearGradient(
                            colors: [
                                isLocked ? Color.green.opacity(0.85) : Color.cyan.opacity(0.75),
                                isLocked ? Color.emeraldGlaze : Color.yellow.opacity(0.65)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round, dash: [8, 6])
                    )
                    .shadow(color: isLocked ? Color.green.opacity(0.6) : Color.cyan.opacity(0.4), radius: 8)

                // Holographic Glider moving along the track
                GliderPointView(kind: shotKind, progress: progress, bounds: geo.size, isLocked: isLocked)

                // Dolly telemetry status pill
                VStack {
                    Spacer().frame(height: h * 0.70)
                    HStack(spacing: 6) {
                        Image(systemName: isLocked ? "lock.shield.fill" : "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isLocked ? .green : .cyan)

                        Text(isLocked ? "DOLLY GIMBAL BLOQUEADO" : "DOLLY 3D • \(movementHint)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color.black.opacity(0.75))
                            .overlay(Capsule().stroke(isLocked ? Color.green.opacity(0.8) : Color.cyan.opacity(0.5), lineWidth: 1))
                    )
                    Spacer()
                }
            }
        }
    }
}

private struct DollyRailShape: Shape {
    let kind: ShotKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        switch kind {
        case .orbit:
            // Sweeping elliptical camera arc
            path.addArc(
                center: CGPoint(x: w / 2, y: h * 0.52),
                radius: w * 0.38,
                startAngle: .degrees(160),
                endAngle: .degrees(20),
                clockwise: false
            )
        case .lowAngle, .highAngle:
            // Vertical ascending/descending runway
            path.move(to: CGPoint(x: w / 2, y: h * 0.75))
            path.addLine(to: CGPoint(x: w / 2, y: h * 0.30))
        default:
            // Smooth horizontal motion track
            path.move(to: CGPoint(x: w * 0.12, y: h * 0.52))
            path.addQuadCurve(
                to: CGPoint(x: w * 0.88, y: h * 0.52),
                control: CGPoint(x: w / 2, y: h * 0.44)
            )
        }
        return path
    }
}

private struct GliderPointView: View {
    let kind: ShotKind
    let progress: Double
    let bounds: CGSize
    let isLocked: Bool

    private var currentPosition: CGPoint {
        let w = bounds.width
        let h = bounds.height
        let p = CGFloat(max(0, min(1, progress)))

        switch kind {
        case .orbit:
            let radius = w * 0.38
            let startDeg: Double = 160
            let endDeg: Double = 20
            let angleDeg = startDeg + (endDeg - startDeg) * Double(p)
            let angleRad = angleDeg * .pi / 180.0
            let cx = w / 2
            let cy = h * 0.52
            return CGPoint(x: cx + radius * CGFloat(cos(angleRad)), y: cy + radius * CGFloat(sin(angleRad)))
        case .lowAngle, .highAngle:
            let startY = h * 0.75
            let endY = h * 0.30
            return CGPoint(x: w / 2, y: startY + (endY - startY) * p)
        default:
            let startX = w * 0.12
            let endX = w * 0.88
            let x = startX + (endX - startX) * p
            let y = h * 0.52 - sin(p * .pi) * (h * 0.08)
            return CGPoint(x: x, y: y)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isLocked ? Color.green.opacity(0.35) : Color.cyan.opacity(0.3))
                .frame(width: 28, height: 28)

            Circle()
                .stroke(isLocked ? Color.green : Color.cyan, lineWidth: 2)
                .frame(width: 18, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
        }
        .position(currentPosition)
        .animation(.linear(duration: 0.1), value: progress)
    }
}

private struct RackFocusActivePill: View {
    let targetLabel: String
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.yellow)

            Text("Rack Focus ➔ Ponto \(targetLabel)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            // Progress bar
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 60, height: 5)

                Capsule()
                    .fill(Color.yellow)
                    .frame(width: 60 * CGFloat(max(0, min(1, progress))), height: 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .overlay(Capsule().stroke(Color.yellow.opacity(0.7), lineWidth: 1))
    }
}

private extension Color {
    static let emeraldGlaze = Color(red: 0.1, green: 0.85, blue: 0.45)
}

private struct AspectMaskOverlay: View {
    let widthOverHeight: CGFloat
    let label: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let targetHeight = min(h, w / widthOverHeight)
            let barHeight = max(0, (h - targetHeight) / 2)

            ZStack {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(height: barHeight)

                    Rectangle()
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                        .frame(height: targetHeight)

                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(height: barHeight)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct RuleOfThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        for i in 1...2 {
            let x = w * CGFloat(i) / 3.0
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: h))

            let y = h * CGFloat(i) / 3.0
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: w, y: y))
        }
        return path
    }
}

private struct ReelsSafeZoneOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let topMargin = h * 0.13
            let bottomMargin = h * 0.24
            let rightMargin = w * 0.16

            ZStack {
                RuleOfThirdsGrid()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)

                Rectangle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: rightMargin, height: h - topMargin - bottomMargin)
                    .position(x: w - rightMargin / 2, y: topMargin + (h - topMargin - bottomMargin) / 2)

                Rectangle()
                    .fill(Color.red.opacity(0.14))
                    .frame(width: w, height: bottomMargin)
                    .position(x: w / 2, y: h - bottomMargin / 2)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        Color.cyan.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                    )
                    .frame(width: w - rightMargin - 12, height: h - topMargin - bottomMargin)
                    .position(
                        x: (w - rightMargin) / 2,
                        y: topMargin + (h - topMargin - bottomMargin) / 2
                    )
            }
        }
        .ignoresSafeArea()
    }
}

private struct FaceTrackerOverlay: View {
    let normalizedRect: CGRect
    let isGoodFraming: Bool

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(
                x: normalizedRect.origin.x * geo.size.width,
                y: normalizedRect.origin.y * geo.size.height,
                width: normalizedRect.size.width * geo.size.width,
                height: normalizedRect.size.height * geo.size.height
            )

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isGoodFraming ? Color.green.opacity(0.85) : Color.orange.opacity(0.9),
                    lineWidth: 2
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .ignoresSafeArea()
    }
}

private struct MotionPacePill: View {
    let pace: MotionPace
    let speedDegPerSec: Double

    private var color: Color {
        switch pace {
        case .still: return .white.opacity(0.75)
        case .cinematic: return .green
        case .tooFast: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(pace.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)

            Text("\(Int(speedDegPerSec.rounded()))°/s")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

private struct CenterReticleView: View {
    let rollDegrees: Double
    let alignmentScore: Double
    let isLocked: Bool
    let isHorizonLevel: Bool

    private var accentColor: Color {
        if isLocked { return .green }
        if alignmentScore >= 0.72 { return .yellow }
        return .white.opacity(0.85)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 2)
                .frame(width: 78, height: 78)

            Circle()
                .trim(from: 0, to: CGFloat(max(0.05, min(1.0, alignmentScore))))
                .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 78, height: 78)

            Rectangle()
                .fill(isHorizonLevel ? Color.green : Color.white.opacity(0.8))
                .frame(width: 52, height: 2)
                .rotationEffect(.degrees(-rollDegrees))

            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
        }
    }
}

private struct CoachingBanner: View {
    let advice: CoachingAdvice
    let activeShot: ShotTemplate?
    let telemetry: CameraTelemetry

    private func isPitchOK(for shot: ShotTemplate) -> Bool {
        telemetry.pitchDegrees >= (shot.targetPitchRange.lowerBound - 3.5) &&
        telemetry.pitchDegrees <= (shot.targetPitchRange.upperBound + 3.5)
    }

    private func isDistanceOK(for shot: ShotTemplate) -> Bool {
        guard let d = telemetry.lidarDistanceMeters else { return true }
        return d >= (shot.targetDistanceRange.lowerBound - 0.15) &&
               d <= (shot.targetDistanceRange.upperBound + 0.15)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: advice.isLocked ? "checkmark.circle.fill" : "scope")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(advice.isLocked ? .green : .yellow)

                Text(advice.primaryInstruction)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Text(advice.secondaryHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let shot = activeShot {
                let distOK = isDistanceOK(for: shot)
                let pitchOK = isPitchOK(for: shot)

                HStack(spacing: 9) {
                    Label(shot.lensLabel, systemImage: "camera.aperture")
                        .foregroundColor(.white.opacity(0.82))
                    Label(shot.distanceLabel, systemImage: distOK ? "checkmark.circle.fill" : "ruler")
                        .foregroundColor(distOK ? .green : .yellow)
                    Label(shot.pitchLabel, systemImage: pitchOK ? "checkmark.circle.fill" : "angle")
                        .foregroundColor(pitchOK ? .green : .yellow)
                    if shot.preferredMode == .video {
                        Label(shot.durationLabel, systemImage: "stopwatch")
                            .foregroundColor(.white.opacity(0.82))
                    } else {
                        Label(shot.preferredMode.rawValue, systemImage: "camera.fill")
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(advice.isLocked ? 0.62 : 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(advice.isLocked ? Color.green.opacity(0.75) : Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

/// Visual vertical pitch gauge on the right edge so Picado (-) and Contrapicado (+) angles are effortless to hit.
private struct PitchGaugeOverlay: View {
    let pitchDegrees: Double
    let targetRange: ClosedRange<Double>

    private let minDeg: Double = -90.0
    private let maxDeg: Double = 90.0
    private let trackHeight: CGFloat = 156

    private var isInTarget: Bool {
        pitchDegrees >= (targetRange.lowerBound - 3.5) && pitchDegrees <= (targetRange.upperBound + 3.5)
    }

    private var needsTiltUp: Bool {
        pitchDegrees < targetRange.lowerBound - 3.5
    }

    private var needsTiltDown: Bool {
        pitchDegrees > targetRange.upperBound + 3.5
    }

    private func yPosition(for degrees: Double) -> CGFloat {
        let clamped = max(minDeg, min(maxDeg, degrees))
        let normalized = (clamped - minDeg) / (maxDeg - minDeg) // 0 = bottom (-90), 1 = top (+90)
        return 7 + (trackHeight - 14) * CGFloat(1.0 - normalized)
    }

    var body: some View {
        let topY = yPosition(for: targetRange.upperBound)
        let bottomY = yPosition(for: targetRange.lowerBound)
        let targetBandHeight = max(12, bottomY - topY)
        let currentY = yPosition(for: pitchDegrees)
        let horizonY = yPosition(for: 0)

        VStack(spacing: 5) {
            // Directional arrow hint (up = contrapicado, down = picado)
            Image(systemName: isInTarget ? "checkmark.circle.fill" : (needsTiltUp ? "chevron.up" : "chevron.down"))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isInTarget ? .green : .yellow)

            ZStack(alignment: .top) {
                // Background track
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 10, height: trackHeight)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                // 0° horizon reference tick
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 14, height: 1)
                    .offset(y: horizonY)

                // Target pitch zone band
                Capsule()
                    .fill(isInTarget ? Color.green.opacity(0.85) : Color.cyan.opacity(0.65))
                    .frame(width: 10, height: targetBandHeight)
                    .offset(y: topY)

                // Current pitch live indicator
                Circle()
                    .fill(isInTarget ? Color.green : Color.yellow)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.75), lineWidth: 1.5)
                    )
                    .shadow(color: (isInTarget ? Color.green : Color.yellow).opacity(0.7), radius: 4)
                    .offset(y: currentY - 7)
            }
            .frame(width: 24, height: trackHeight)

            Text("\(Int(pitchDegrees.rounded()))°")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isInTarget ? .green : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.62)))
        }
    }
}

private struct SubjectTrackerOverlay: View {
    let normalizedRect: CGRect
    let isGoodFraming: Bool

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(
                x: normalizedRect.minX * geo.size.width,
                y: normalizedRect.minY * geo.size.height,
                width: normalizedRect.width * geo.size.width,
                height: normalizedRect.height * geo.size.height
            )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    (isGoodFraming ? Color.cyan : Color.orange).opacity(0.65),
                    style: StrokeStyle(lineWidth: 1.4, dash: [7, 5])
                )
                .frame(width: max(28, rect.width), height: max(28, rect.height))
                .position(x: rect.midX, y: rect.midY)
        }
        .ignoresSafeArea()
    }
}

private struct AudioMeterOverlay: View {
    let level: Float
    let isClipping: Bool
    private let barHeight: CGFloat = 110

    var body: some View {
        let clamped = CGFloat(max(0, min(1, level)))
        let fillHeight = max(3, barHeight * clamped)
        let color: Color = isClipping ? .red : (clamped > 0.78 ? .yellow : .green)

        VStack(spacing: 4) {
            Image(systemName: isClipping ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isClipping ? .red : .white.opacity(0.85))

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 7, height: barHeight)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                Capsule()
                    .fill(color)
                    .frame(width: 7, height: fillHeight)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Capsule().fill(Color.black.opacity(0.38)))
    }
}

private struct RecordingPaceBar: View {
    let movementHint: String
    let elapsed: Double
    let target: Double
    let progress: Double
    let pace: MotionPace

    private var reachedTarget: Bool {
        progress >= 1.0
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(movementHint)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1fs / %.1fs", elapsed, target))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(reachedTarget ? .green : .yellow)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(pace == .tooFast ? Color.red : (reachedTarget ? Color.green : Color.yellow))
                        .frame(width: max(4, geo.size.width * CGFloat(max(0, min(1, progress)))))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.68))
        )
    }
}

private struct DirectorAlertPill: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
                .overlay(Capsule().stroke(tint.opacity(0.7), lineWidth: 1))
        )
    }
}
