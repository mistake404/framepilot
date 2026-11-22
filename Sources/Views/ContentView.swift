import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = SpatialCameraEngine()
    @State private var showPackSheet = false
    @State private var showStoryboardSheet = false
    @State private var showExposureSlider = false
    @State private var showRackFocusBar = false
    @State private var showTeleprompter = false
    @State private var showTeleprompterEditor = false
    @AppStorage("framepilot.teleprompter.text") private var teleprompterText: String = "3 segundos para prender atenção: mostra primeiro o resultado final, depois explica o passo a passo com energia!"
    @AppStorage("framepilot.teleprompter.speed") private var teleprompterSpeed: Double = 28.0

    var body: some View {
        ZStack {
            // Native Apple Pro Camera preview with tap-to-focus, long-press AE/AF lock & pinch-to-zoom
            ProCameraPreviewView(
                session: engine.captureSession,
                onFocusTap: { devicePoint, screenPoint in
                    engine.focus(at: devicePoint, screenPoint: screenPoint)
                },
                onLongPressLock: { devicePoint, screenPoint in
                    engine.lockFocusAndExposure(at: devicePoint, screenPoint: screenPoint)
                },
                onPinchZoom: { scale, state in
                    engine.handlePinchZoom(scale: scale, state: state)
                }
            )
            .ignoresSafeArea()

            // Ghost Frame (Match Cut) translucent overlay of last photo or video frame
            if engine.showGhostOverlay, let ghost = engine.ghostImage {
                Image(uiImage: ghost)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.28)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

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
                aspectMask: engine.aspectMask,
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

            // Controls overlay (Top telemetry + Teleprompter + Bottom capture dock)
            VStack(spacing: 0) {
                TopTelemetryBar(
                    hudStore: engine.hudStore,
                    overlayMode: engine.overlayMode,
                    isThermalEcoActive: engine.isThermalEcoActive,
                    isAEAFLocked: engine.isAEAFLocked,
                    showTeleprompter: showTeleprompter,
                    onCycleOverlay: { engine.cycleOverlayMode() },
                    onToggleTeleprompter: { showTeleprompter.toggle() }
                )
                .padding(.horizontal, 14)
                .padding(.top, 8)

                if showTeleprompter {
                    TeleprompterOverlayView(
                        scriptText: teleprompterText,
                        isScrolling: engine.isRecording,
                        speedPointsPerSecond: teleprompterSpeed,
                        onEditTap: { showTeleprompterEditor = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

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

                // Hollywood Rack Focus bar when toggled or active
                if showRackFocusBar || engine.focusMarkA != nil || engine.focusMarkB != nil {
                    HStack(spacing: 8) {
                        // Mark A
                        Button {
                            engine.setFocusMarkA()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Ponto A")
                                    .font(.system(size: 10, weight: .bold))
                                if let a = engine.focusMarkA {
                                    Text(a.formattedDistance)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                }
                            }
                            .foregroundColor(engine.focusMarkA != nil ? .yellow : .white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.68)))
                        }

                        // Trigger [ A ➔ B ]
                        Button {
                            let next = (engine.focusMarkB != nil && engine.hudStore.telemetry.rackFocusTargetLabel != "B") ? "B" : "A"
                            engine.triggerRackFocus(to: next)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.aperture")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Rack A➔B")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    (engine.focusMarkA != nil && engine.focusMarkB != nil) ? Color.yellow : Color.gray.opacity(0.5)
                                )
                            )
                        }
                        .disabled(engine.focusMarkA == nil || engine.focusMarkB == nil || engine.isRackFocusing)

                        // Mark B
                        Button {
                            engine.setFocusMarkB()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Ponto B")
                                    .font(.system(size: 10, weight: .bold))
                                if let b = engine.focusMarkB {
                                    Text(b.formattedDistance)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                }
                            }
                            .foregroundColor(engine.focusMarkB != nil ? .yellow : .white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.68)))
                        }

                        // Clear
                        if engine.focusMarkA != nil || engine.focusMarkB != nil {
                            Button {
                                engine.clearFocusMarks()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.65))
                                    .font(.system(size: 14))
                            }
                        }
                    }
                    .padding(.bottom, 6)
                    .transition(.opacity)
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

                    // Hollywood Rack Focus toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showRackFocusBar.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Rack")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(showRackFocusBar || engine.focusMarkA != nil ? .yellow : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                    }

                    // 3D Virtual Dolly toggle
                    Button {
                        engine.toggleVirtualDolly()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                .font(.system(size: 11, weight: .bold))
                            Text("Dolly")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(engine.isVirtualDollyActive ? .cyan : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                    }

                    // Aspect Mask (9:16 / 4:5 / 16:9)
                    Button {
                        engine.cycleAspectMask()
                    } label: {
                        Text(engine.aspectMask.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(engine.aspectMask == .full ? .white : .cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                    }

                    // Ghost Frame (Match Cut) toggle
                    Button {
                        engine.toggleGhostOverlay()
                    } label: {
                        Image(systemName: "square.on.square.dashed")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(engine.showGhostOverlay ? .cyan : (engine.ghostImage != nil ? .white : .white.opacity(0.45)))
                            .frame(width: 30, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }

                    // Flip Front / Back Camera
                    Button {
                        engine.flipCamera()
                    } label: {
                        Image(systemName: "camera.rotate")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(engine.cameraPosition == .front ? .yellow : .white)
                            .frame(width: 30, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .disabled(engine.isRecording)

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
                customPacks: engine.customPacks,
                presetPacks: ScenePack.presets,
                selectedPack: engine.selectedPack,
                onSelect: { engine.selectPack($0) },
                onCreateCustom: { engine.addCustomPack($0) },
                onDeleteCustom: { engine.deleteCustomPack(id: $0) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStoryboardSheet) {
            StoryboardSheet(engine: engine)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTeleprompterEditor) {
            TeleprompterEditorSheet(
                scriptText: $teleprompterText,
                speedPointsPerSecond: $teleprompterSpeed
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
                    if let target = engine.activeShot?.durationLabel {
                        Text(String(format: "%.1fs / %@", engine.recordingElapsed, target))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    } else {
                        Text(formatDuration(engine.recordingSeconds))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.35)))
            } else {
                HStack(spacing: 16) {
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

                    if engine.captureMode == .video, let shot = engine.activeShot {
                        Button {
                            engine.toggleAutoStop()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "stopwatch")
                                    .font(.system(size: 10, weight: .bold))
                                Text(engine.autoStopEnabled ? "Auto \(shot.durationLabel)" : "Manual")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(engine.autoStopEnabled ? .cyan : .white.opacity(0.65))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
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
                    isCountingDown: engine.countdownRemaining > 0,
                    targetProgress: engine.targetDurationProgress
                ) {
                    engine.triggerShutter()
                }

                Spacer()

                Button {
                    showStoryboardSheet = true
                } label: {
                    SessionStoryboardButton(
                        completedCount: engine.completedShotIds.count,
                        totalCount: engine.selectedPack.shots.count,
                        videoCount: engine.recordedVideoCount
                    )
                }
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
    let isAEAFLocked: Bool
    let showTeleprompter: Bool
    let onCycleOverlay: () -> Void
    let onToggleTeleprompter: () -> Void

    var body: some View {
        let telemetry = hudStore.telemetry

        HStack(spacing: 6) {
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

            if isAEAFLocked {
                Text("AE/AF")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow))
            } else {
                telemetryPill(
                    icon: telemetry.detectedShotKind.iconName,
                    text: telemetry.detectedShotKind.rawValue,
                    accent: .white
                )
            }

            if isThermalEcoActive {
                Image(systemName: "snowflake")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.cyan)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.58)))
            }

            Spacer()

            Button(action: onToggleTeleprompter) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(showTeleprompter ? .yellow : .white.opacity(0.85))
                    .frame(width: 30, height: 28)
                    .background(Circle().fill(Color.black.opacity(0.58)))
            }

            Button(action: onCycleOverlay) {
                HStack(spacing: 4) {
                    Image(systemName: overlayMode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(overlayMode.rawValue)
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(overlayMode == .reelsSafeZone ? .cyan : (overlayMode == .thirds ? .yellow : .white.opacity(0.7)))
                .padding(.horizontal, 8)
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
    let targetProgress: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(hudStore.telemetry.advice.isLocked ? Color.green : Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)

                // Target duration progress ring while recording video
                if isRecording && targetProgress > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(targetProgress))
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 74, height: 74)
                }

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

private struct SessionStoryboardButton: View {
    let completedCount: Int
    let totalCount: Int
    let videoCount: Int

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: videoCount > 0 ? "film.stack.fill" : "film.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(videoCount > 0 ? .yellow : .white)

            if totalCount == 0 {
                Text("Sessão")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            } else {
                Text("\(completedCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 62, height: 50)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(videoCount > 0 ? Color.yellow.opacity(0.22) : Color.white.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(videoCount > 0 ? Color.yellow.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        )
    }
}
