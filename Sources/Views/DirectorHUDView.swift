import SwiftUI

struct DirectorHUDView: View {
    let telemetry: CameraTelemetry
    let activeShot: ShotTemplate?
    let showGrid: Bool

    var body: some View {
        ZStack {
            if showGrid {
                RuleOfThirdsGrid()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }

            // Center spatial reticle + artificial horizon
            CenterReticleView(
                rollDegrees: telemetry.rollDegrees,
                alignmentScore: telemetry.advice.alignmentScore,
                isLocked: telemetry.advice.isLocked,
                isHorizonLevel: telemetry.isHorizonLevel
            )
            .allowsHitTesting(false)

            // Coaching pill positioned neatly below top bar
            VStack {
                Spacer().frame(height: 68)

                CoachingBanner(
                    advice: telemetry.advice,
                    activeShot: activeShot
                )
                .padding(.horizontal, 16)

                Spacer()
            }
            .allowsHitTesting(false)
        }
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
            // Outer alignment progress ring
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 2)
                .frame(width: 78, height: 78)

            Circle()
                .trim(from: 0, to: CGFloat(max(0.05, min(1.0, alignmentScore))))
                .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 78, height: 78)
                .animation(.easeOut(duration: 0.12), value: alignmentScore)

            // Artificial horizon bar
            Rectangle()
                .fill(isHorizonLevel ? Color.green : Color.white.opacity(0.8))
                .frame(width: 52, height: 2)
                .rotationEffect(.degrees(-rollDegrees))
                .animation(.easeOut(duration: 0.08), value: rollDegrees)

            // Center LiDAR sampling dot
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
        }
    }
}

private struct CoachingBanner: View {
    let advice: CoachingAdvice
    let activeShot: ShotTemplate?

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
                HStack(spacing: 10) {
                    Label(shot.distanceLabel, systemImage: "ruler")
                    Label(shot.pitchLabel, systemImage: "angle")
                    Label(shot.preferredMode.rawValue, systemImage: shot.preferredMode == .video ? "video.fill" : "camera.fill")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
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
