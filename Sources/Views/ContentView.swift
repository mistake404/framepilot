import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = SpatialCameraEngine()
    @State private var showPackSheet = false
    @State private var showExposureSlider = false

    var body: some View {
        ZStack {
            // Native Apple Pro Camera preview with tap-to-focus & pinch-to-zoom
            ProCameraPreviewView(
                session: engine.captureSession,
                onFocusTap: { devicePoint, screenPoint in
                    engine.focus(at: devicePoint, screenPoint: screenPoint)
                },
                onPinchZoom: { scale, state in
                    engine.handlePinchZoom(scale: scale, state: state)
                }
            )
            .ignoresSafeArea()

            // Crisp native-style shutter blink
            if engine.shutterFlashVisible {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Tap-to-focus yellow reticle
            if let focusPoint = engine.focusIndicatorPoint {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.yellow, lineWidth: 1.8)
                    .frame(width: 68, height: 68)
                    .position(focusPoint)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }

            // Isolated high-frequency HUD (does not re-render ContentView)
            DirectorHUDView(
                hudStore: engine.hudStore,
                activeShot: engine.activeShot,
                overlayMode: engine.overlayMode,
                isRecording: engine.isRecording
            )

            // Big self-timer countdown overlay
            if engine.countdownRemaining > 0 {
                Text("\(engine.countdownRemaining)")
                    .font(.system(size: 86, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .allowsHitTesting(false)
            }

            // Controls overlay (Top telemetry + Bottom capture dock)
            VStack(spacing: 0) {
                TopTelemetryBar(
                    hudStore: engine.hudStore,
                    overlayMode: engine.overlayMode,
                    isThermalEcoActive: engine.isThermalEcoActive,
                    onCycleOverlay: { engine.cycleOverlayMode() }
                )
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
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // Exposure (EV) slider when toggled
                if showExposureSlider {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))

                        Slider(
                            value: Binding(
                                get: { Double(engine.exposureBias) },
                                set: { engine.setExposureBias(Float($0)) }
                            ),
                            in: -2.0...2.0,
                            step: 0.1
                        )
                        .tint(.yellow)

                        Text(String(format: "%+.1f EV", engine.exposureBias))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.68)))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                }

                // Pro Controls strip: Lenses + EV + Flash/Quality + Timer
                HStack(spacing: 7) {
                    if engine.availableLenses.count > 1 {
                        HStack(spacing: 3) {
                            ForEach(engine.availableLenses, id: \.self) { lens in
                                let isSelected = abs(engine.activeLens - lens) < 0.15
                                let label = lens == 0.5 ? ".5" : "\(Int(lens))"
                                Button {
                                    engine.setLens(lens)
                                } label: {
                                    Text(isSelected ? "\(label)x" : label)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(isSelected ? .yellow : .white)
                                        .frame(width: 32, height: 26)
                                        .background(
                                            Circle().fill(isSelected ? Color.black.opacity(0.75) : Color.clear)
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.48)))
                    }

                    // EV button
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showExposureSlider.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plusminus.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(engine.exposureBias == 0 ? "EV" : String(format: "%+.1f", engine.exposureBias))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(showExposureSlider || engine.exposureBias != 0 ? .yellow : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                    }

                    // Flash (Photo) or Quality 4K30/1080p60 (Video)
                    if engine.captureMode == .photo {
                        Button {
                            engine.cycleFlash()
                        } label: {
                            Image(systemName: engine.flashOption.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(engine.flashOption == .on ? .yellow : .white)
                                .frame(width: 30, height: 28)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                    } else {
                        Button {
                            engine.toggleVideoQuality()
                        } label: {
                            Text(engine.videoQuality.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(engine.videoQuality == .uhd4K30 ? .yellow : .cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.black.opacity(0.5)))
                        }
                        .disabled(engine.isRecording)
                    }

                    // Self-timer (Off / 3s / 10s)
                    Button {
                        engine.cycleTimer()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 11, weight: .semibold))
                            if engine.timerOption != .off {
                                Text(engine.timerOption.label)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                        }
                        .foregroundColor(engine.timerOption == .off ? .white : .yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                    }
                    .disabled(engine.isRecording)
                }
                .padding(.bottom, 10)

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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                engine.start()
            } else {
                // Immediately release camera, LiDAR & motion sensors in background (0% battery drain)
                engine.stop()
            }
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

    private var bottomCaptureDock: some View {
        VStack(spacing: 12) {
            if engine.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    Text(formatDuration(engine.recordingSeconds))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.35)))
            } else {
                HStack(spacing: 20) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button {
                            engine.setCaptureMode(mode)
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

                CaptureShutterButton(
                    hudStore: engine.hudStore,
                    captureMode: engine.captureMode,
                    isRecording: engine.isRecording,
                    isCountingDown: engine.countdownRemaining > 0
                ) {
                    engine.triggerShutter()
                }

                Spacer()

                LightingProgressBadge(
                    hudStore: engine.hudStore,
                    completedCount: engine.completedShotIds.count,
                    totalCount: engine.selectedPack.shots.count
                )
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

private struct TopTelemetryBar: View {
    @ObservedObject var hudStore: HUDTelemetryStore
    let overlayMode: OverlayMode
    let isThermalEcoActive: Bool
    let onCycleOverlay: () -> Void

    var body: some View {
        let telemetry = hudStore.telemetry

        HStack(spacing: 7) {
            telemetryPill(
                icon: telemetry.hasLidarSupport ? "dot.radiowaves.left.and.right" : "ruler",
                text: telemetry.formattedDistance,
                accent: telemetry.lidarDistanceMeters != nil ? .cyan : .gray
            )

            telemetryPill(
                icon: "angle",
                text: telemetry.formattedPitch,
                accent: .yellow
            )

            telemetryPill(
                icon: telemetry.detectedShotKind.iconName,
                text: telemetry.detectedShotKind.rawValue,
                accent: .white
            )

            if isThermalEcoActive {
                Image(systemName: "snowflake")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.cyan)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.58)))
            }

            Spacer()

            Button(action: onCycleOverlay) {
                HStack(spacing: 4) {
                    Image(systemName: overlayMode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(overlayMode.rawValue)
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(overlayMode == .reelsSafeZone ? .cyan : (overlayMode == .thirds ? .yellow : .white.opacity(0.7)))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.58)))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.58)))
    }
}

private struct CaptureShutterButton: View {
    @ObservedObject var hudStore: HUDTelemetryStore
    let captureMode: CaptureMode
    let isRecording: Bool
    let isCountingDown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(hudStore.telemetry.advice.isLocked ? Color.green : Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)

                if isCountingDown {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.orange))
                } else if captureMode == .video {
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 30, style: .continuous)
                        .fill(Color.red)
                        .frame(
                            width: isRecording ? 28 : 58,
                            height: isRecording ? 28 : 58
                        )
                        .animation(.easeInOut(duration: 0.18), value: isRecording)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 58, height: 58)
                }
            }
        }
    }
}

private struct LightingProgressBadge: View {
    @ObservedObject var hudStore: HUDTelemetryStore
    let completedCount: Int
    let totalCount: Int

    var body: some View {
        let lighting = hudStore.telemetry.lighting

        VStack(spacing: 3) {
            Image(systemName: lighting.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(lighting == .low ? .orange : .yellow)

            if totalCount == 0 {
                Text("Livre")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            } else {
                Text("\(completedCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 62, height: 50)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
    }
}
