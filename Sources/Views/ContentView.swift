import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SpatialCameraEngine()
    @State private var showPackSheet = false

    var body: some View {
        ZStack {
            // Full-screen AR / LiDAR camera preview
            ARCameraView(session: engine.arSession)
                .ignoresSafeArea()

            // Spatial HUD + Coaching overlay
            DirectorHUDView(
                telemetry: engine.telemetry,
                activeShot: engine.activeShot,
                showGrid: engine.showGrid
            )

            // Controls overlay (Top telemetry + Bottom capture dock)
            VStack(spacing: 0) {
                topTelemetryBar
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                Spacer()

                if let toast = engine.statusToast {
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                if !engine.selectedPack.shots.isEmpty {
                    ShotChecklistBar(
                        shots: engine.selectedPack.shots,
                        activeIndex: engine.activeShotIndex,
                        completedIds: engine.completedShotIds,
                        onSelect: { engine.selectShot(at: $0) }
                    )
                    .padding(.bottom, 12)
                }

                bottomCaptureDock
            }
        }
        .onAppear {
            engine.start()
        }
        .onDisappear {
            engine.stop()
        }
        .sheet(isPresented: $showPackSheet) {
            ScenePackSheet(
                packs: ScenePack.presets,
                selectedPack: engine.selectedPack,
                onSelect: { engine.selectPack($0) }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var topTelemetryBar: some View {
        HStack(spacing: 8) {
            // LiDAR Distance pill
            telemetryPill(
                icon: engine.telemetry.hasLidarSupport ? "dot.radiowaves.left.and.right" : "ruler",
                text: engine.telemetry.formattedDistance,
                accent: engine.telemetry.lidarDistanceMeters != nil ? .cyan : .gray
            )

            // Pitch angle pill
            telemetryPill(
                icon: "angle",
                text: engine.telemetry.formattedPitch,
                accent: .yellow
            )

            // Detected shot pill
            telemetryPill(
                icon: engine.telemetry.detectedShotKind.iconName,
                text: engine.telemetry.detectedShotKind.rawValue,
                accent: .white
            )

            Spacer()

            // Grid toggle button
            Button {
                engine.showGrid.toggle()
            } label: {
                Image(systemName: engine.showGrid ? "grid" : "grid.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(engine.showGrid ? .yellow : .white.opacity(0.7))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
        }
    }

    private func telemetryPill(icon: String, text: String, accent: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(accent)

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.58)))
    }

    private var bottomCaptureDock: some View {
        VStack(spacing: 12) {
            // Mode selector (Photo / Video) or Recording timer
            if engine.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(formatDuration(engine.recordingSeconds))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.3)))
            } else {
                HStack(spacing: 20) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button {
                            engine.captureMode = mode
                        } label: {
                            Text(mode.rawValue.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .tracking(1)
                                .foregroundColor(engine.captureMode == mode ? .yellow : .white.opacity(0.65))
                        }
                    }
                }
            }

            HStack {
                // Scene Pack button
                Button {
                    showPackSheet = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: engine.selectedPack.iconName)
                            .font(.system(size: 17, weight: .semibold))
                        Text("Guião")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(width: 62, height: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
                }

                Spacer()

                // Shutter / Record button
                Button {
                    if engine.captureMode == .photo {
                        engine.capturePhoto()
                    } else {
                        engine.toggleVideoRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(engine.telemetry.advice.isLocked ? Color.green : Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)

                        if engine.captureMode == .video {
                            RoundedRectangle(cornerRadius: engine.isRecording ? 8 : 30, style: .continuous)
                                .fill(Color.red)
                                .frame(
                                    width: engine.isRecording ? 28 : 58,
                                    height: engine.isRecording ? 28 : 58
                                )
                                .animation(.easeInOut(duration: 0.18), value: engine.isRecording)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                }

                Spacer()

                // Progress / Lighting badge
                VStack(spacing: 3) {
                    Image(systemName: engine.telemetry.lighting.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(engine.telemetry.lighting == .low ? .orange : .yellow)

                    if engine.selectedPack.shots.isEmpty {
                        Text("Livre")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    } else {
                        Text("\(engine.completedShotIds.count)/\(engine.selectedPack.shots.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 62, height: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
