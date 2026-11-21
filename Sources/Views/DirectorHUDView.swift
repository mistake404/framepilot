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
            }

            // Center spatial reticle + artificial horizon (EMA-smoothed at 30Hz)
            CenterReticleView(
                rollDegrees: telemetry.rollDegrees,
                alignmentScore: telemetry.advice.alignmentScore,
                isLocked: telemetry.advice.isLocked,
                isHorizonLevel: telemetry.isHorizonLevel
            )
            .allowsHitTesting(false)

            // Coaching pill + Motion Pace badge
            VStack(spacing: 6) {
                Spacer().frame(height: 68)

                CoachingBanner(
                    advice: telemetry.advice,
                    activeShot: activeShot
                )
                .padding(.horizontal, 16)

                if isRecording || telemetry.motionPace != .still {
                    MotionPacePill(
                        pace: telemetry.motionPace,
                        speedDegPerSec: telemetry.motionSpeedDegPerSec
                    )
                }

                Spacer()
            }
            .allowsHitTesting(false)
        }
    }
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
                // Subtle rule-of-thirds inside safe frame
                RuleOfThirdsGrid()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)

                // Shaded Reels/TikTok right-side interaction icons zone
                Rectangle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: rightMargin, height: h - topMargin - bottomMargin)
                    .position(x: w - rightMargin / 2, y: topMargin + (h - topMargin - bottomMargin) / 2)

                // Shaded Reels/TikTok bottom caption & audio zone
                Rectangle()
                    .fill(Color.red.opacity(0.14))
                    .frame(width: w, height: bottomMargin)
                    .position(x: w / 2, y: h - bottomMargin / 2)

                // Safe zone dashed outline
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
                    Label(shot.lensLabel, systemImage: "camera.aperture")
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
