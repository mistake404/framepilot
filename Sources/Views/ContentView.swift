import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var engine = SpatialCameraEngine()
    @State private var showPackSheet = false
    @State private var showStoryboardSheet = false
    @State private var showProDrawer = false
    @State private var lensSelectionFeedback = false
    @State private var showExposureSlider = false
    @State private var showRackFocusBar = false
    @State private var showTeleprompter = false
    @State private var showTeleprompterEditor = false
    @AppStorage("framepilot.teleprompter.text") private var teleprompterText: String = "3 segundos para prender atenção: mostra primeiro o resultado final, depois explica o passo a passo com energia!"
    @AppStorage("framepilot.teleprompter.speed") private var teleprompterSpeed: Double = 28.0

    private var isAnyProFeatureActive: Bool {
        engine.whiteBalanceLocked || engine.showHighlights || engine.voiceCoachingEnabled || engine.exposureBias != 0 ||
        engine.timerOption != .off ||
        engine.aspectMask != .full ||
        engine.isVirtualDollyActive ||
        engine.focusMarkA != nil ||
        engine.showGhostOverlay ||
        engine.cameraPosition == .front
    }

    var body: some View {
        ZStack {
            // Native Apple Pro Camera preview with tap-to-focus, long-press AE/AF lock & pinch-to-zoom
            ProCameraPreviewView(
                highlights: engine.highlights,
                session: engine.captureSession,
                onInspectFocus: { engine.inspectFocus(at: $0, in: $1) },
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

            FocusLoupeView(loupe: engine.focusLoupe)
                .allowsHitTesting(false)

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

                if let verdict = engine.latestTakeVerdict {
                    TakeVerdictCard(
                        verdict: verdict,
                        onRetake: { engine.retakeShot(id: verdict.shotId) },
                        onDismiss: { engine.dismissTakeVerdict() }
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

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

                // Collapsible Pro Drawer
                if showProDrawer {
                    ProControlsDrawerView(
                        engine: engine,
                        showExposureSlider: $showExposureSlider,
                        showRackFocusBar: $showRackFocusBar,
                        onClose: { setProDrawerVisible(false) }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? AnyTransition.opacity : .offset(y: 12).combined(with: .opacity))
                }

                // Clean Viewfinder primary dock: Lenses (.5, 1x, 2x, 5x) + PRO Drawer button
                HStack(spacing: 8) {
                    if engine.availableLenses.count > 1 {
                        HStack(spacing: 3) {
                            ForEach(engine.availableLenses, id: \.self) { lens in
                                let isSelected = abs(engine.activeLens - lens) < 0.15
                                let label = lens.formatted(.number.precision(.fractionLength(0...1)))
                                Button {
                                    if !isSelected { lensSelectionFeedback.toggle() }
                                    engine.setLens(lens)
                                } label: {
                                    VStack(spacing: 0) {
                                        Text(isSelected ? "\(label)×" : label)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        if engine.digitalLensPresets.contains(lens) {
                                            Text("digital")
                                                .font(.system(size: 8))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                    }
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(isSelected ? .yellow : .white)
                                        .frame(width: 36, height: 32)
                                        .background(
                                            Circle().fill(isSelected ? Color.black.opacity(0.8) : Color.clear)
                                        )
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(engine.digitalLensPresets.contains(lens) ? "Ampliação digital \(label) vezes" : "Ampliação \(label) vezes")
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.black.opacity(0.52)))
                        .sensoryFeedback(.selection, trigger: lensSelectionFeedback)
                    }

                    // PRO button with active indicator
                    Button {
                        setProDrawerVisible(!showProDrawer)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showProDrawer ? "chevron.down" : "slider.horizontal.3")
                                .font(.system(size: 11, weight: .bold))
                            Text("PRO")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            if isAnyProFeatureActive {
                                Circle()
                                    .fill(Color.yellow)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .foregroundColor(showProDrawer || isAnyProFeatureActive ? .yellow : .white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.52))
                                .overlay(
                                    Capsule()
                                        .stroke(isAnyProFeatureActive ? Color.yellow.opacity(0.6) : Color.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                    }
                    .accessibilityLabel(showProDrawer ? "Fechar controlos PRO" : "Abrir controlos PRO")
                    .sensoryFeedback(.selection, trigger: showProDrawer)
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
                } else {
                    FreeModeShotPickerBar(
                        selectedKind: engine.freeModeTargetKind,
                        onSelect: { engine.selectFreeModeKind($0) }
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
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTeleprompterEditor) {
            TeleprompterEditorSheet(
                scriptText: $teleprompterText,
                speedPointsPerSecond: $teleprompterSpeed
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func setProDrawerVisible(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            showProDrawer = visible
        }
    }

    private var bottomCaptureDock: some View {
        VStack(spacing: 6) {
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
                .frame(minHeight: 44)
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
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(engine.captureMode == mode ? .isSelected : [])
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
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: engine.captureMode)
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
                        completedCount: engine.selectedPack.shots.isEmpty ? engine.freeModeTakeOrder.count : engine.completedShotIds.count,
                        totalCount: engine.selectedPack.shots.count,
                        videoCount: engine.recordedVideoCount
                    )
                }
                .accessibilityLabel("Abrir storyboard da sessão")
                .accessibilityValue("\(engine.completedShotIds.count) de \(engine.selectedPack.shots.count) planos concluídos")
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
    @State private var shutterFeedback = false
    @ObservedObject var hudStore: HUDTelemetryStore
    let captureMode: CaptureMode
    let isRecording: Bool
    let isCountingDown: Bool
    let targetProgress: Double
    let action: () -> Void

    private var shutterLabel: String {
        if isCountingDown { return "Cancelar temporizador" }
        if captureMode == .photo { return "Tirar fotografia" }
        return isRecording ? "Parar gravação" : "Iniciar gravação"
    }

    var body: some View {
        Button {
            shutterFeedback.toggle()
            action()
        } label: {
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
        .accessibilityLabel(shutterLabel)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: shutterFeedback)
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

// MARK: - Pro Drawer Components

private struct ProControlsDrawerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var engine: SpatialCameraEngine
    @Binding var showExposureSlider: Bool
    @Binding var showRackFocusBar: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.yellow)
                    Text("CONTROLOS PRO")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Fechar controlos PRO")
            }
            .padding(.horizontal, 4)

            // Grid of Pro Tools (2 Rows of 4 Tiles)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                // 1. Exposure (EV)
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                        showExposureSlider.toggle()
                    }
                } label: {
                    ProDrawerTile(
                        icon: "plusminus.circle",
                        title: "Exposição",
                        value: engine.exposureBias == 0 ? "0.0 EV" : String(format: "%+.1f EV", engine.exposureBias),
                        isActive: showExposureSlider || engine.exposureBias != 0,
                        accentColor: .yellow
                    )
                }

                // 2. Flash / Quality
                if engine.captureMode == .photo {
                    Button {
                        engine.cycleFlash()
                    } label: {
                        ProDrawerTile(
                            icon: engine.flashOption.iconName,
                            title: "Flash",
                            value: engine.flashOption == .auto ? "Auto" : (engine.flashOption == .on ? "Ligado" : "Desligado"),
                            isActive: engine.flashOption == .on,
                            accentColor: .yellow
                        )
                    }
                } else {
                    Button {
                        engine.toggleVideoQuality()
                    } label: {
                        ProDrawerTile(
                            icon: "video.badge.waveform",
                            title: "Qualidade",
                            value: engine.videoQuality.rawValue,
                            isActive: engine.videoQuality == .uhd4K30,
                            accentColor: engine.videoQuality == .uhd4K30 ? .yellow : .cyan
                        )
                    }
                    .disabled(engine.isRecording)
                }

                Button { engine.toggleWhiteBalance() } label: {
                    ProDrawerTile(icon: "thermometer.medium", title: "Brancos",
                                  value: engine.whiteBalanceLocked ? "Fixo" : "Auto",
                                  isActive: engine.whiteBalanceLocked, accentColor: .yellow)
                }
                .disabled(!engine.canLockWhiteBalance)

                Button { engine.showHighlights.toggle() } label: {
                    ProDrawerTile(icon: "sun.max", title: "Altas luzes",
                                  value: !engine.highlightsAvailable ? "Indisp." : (engine.showHighlights ? "95%" : "Off"),
                                  isActive: engine.showHighlights && engine.highlightsAvailable, accentColor: .yellow)
                }
                .disabled(!engine.highlightsAvailable)

                Button { engine.voiceCoachingEnabled.toggle() } label: {
                    ProDrawerTile(icon: engine.voiceCoachingEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                  title: "Voz",
                                  value: engine.voiceCoachingEnabled ? "Ativa" : "Off",
                                  isActive: engine.voiceCoachingEnabled, accentColor: .cyan)
                }

                // 3. Flip Camera
                Button {
                    engine.flipCamera()
                } label: {
                    ProDrawerTile(
                        icon: "camera.rotate",
                        title: "Câmara",
                        value: engine.cameraPosition == .front ? "Frontal" : "Traseira",
                        isActive: engine.cameraPosition == .front,
                        accentColor: .yellow
                    )
                }
                .disabled(engine.isRecording)

                // 4. Self-Timer
                Button {
                    engine.cycleTimer()
                } label: {
                    ProDrawerTile(
                        icon: "timer",
                        title: "Temporizador",
                        value: engine.timerOption == .off ? "Desligado" : engine.timerOption.label,
                        isActive: engine.timerOption != .off,
                        accentColor: .yellow
                    )
                }
                .disabled(engine.isRecording)

                // 5. Aspect Mask
                Button {
                    engine.cycleAspectMask()
                } label: {
                    ProDrawerTile(
                        icon: "aspectratio",
                        title: "Máscara",
                        value: engine.aspectMask.rawValue,
                        isActive: engine.aspectMask != .full,
                        accentColor: .cyan
                    )
                }

                // 6. Ghost Frame (Match Cut)
                Button {
                    engine.toggleGhostOverlay()
                } label: {
                    ProDrawerTile(
                        icon: "square.on.square.dashed",
                        title: "Fantasma",
                        value: engine.showGhostOverlay ? "Ativo" : "Inativo",
                        isActive: engine.showGhostOverlay,
                        accentColor: .cyan
                    )
                }

                // 7. Virtual Dolly 3D
                Button {
                    engine.toggleVirtualDolly()
                } label: {
                    ProDrawerTile(
                        icon: "point.3.filled.connected.trianglepath.dotted",
                        title: "Dolly 3D",
                        value: engine.isVirtualDollyActive ? "Ligado" : "Desligado",
                        isActive: engine.isVirtualDollyActive,
                        accentColor: .cyan
                    )
                }

                // 8. Hollywood Rack Focus
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                        showRackFocusBar.toggle()
                    }
                } label: {
                    ProDrawerTile(
                        icon: "camera.aperture",
                        title: "Rack Focus",
                        value: (engine.focusMarkA != nil || engine.focusMarkB != nil) ? "Marcado" : (showRackFocusBar ? "Aberto" : "Inativo"),
                        isActive: showRackFocusBar || engine.focusMarkA != nil,
                        accentColor: .yellow
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

private struct ProDrawerTile: View {
    let icon: String
    let title: String
    let value: String
    let isActive: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isActive ? accentColor : .white)

            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? accentColor : .white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? accentColor.opacity(0.2) : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? accentColor.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct TakeVerdictCard: View {
    let verdict: TakeVerdict
    let onRetake: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let accent: Color = verdict.isApproved ? .green : .orange

        HStack(spacing: 10) {
            Image(systemName: verdict.isApproved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.headline)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(verdict.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if verdict.canRetake {
                Button("Repetir") {
                    onRetake()
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.yellow))
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .accessibilityLabel("Fechar avaliação do take")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(0.65), lineWidth: 1.2)
                )
        )
    }
}

private struct FreeModeShotPickerBar: View {
    let selectedKind: ShotKind?
    let onSelect: (ShotKind?) -> Void

    private let selectionFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Livre", icon: "sparkles", isSelected: selectedKind == nil) {
                    onSelect(nil)
                }
                ForEach(ShotKind.allCases) { kind in
                    chip(title: kind.rawValue, icon: kind.iconName, isSelected: selectedKind == kind) {
                        onSelect(selectedKind == kind ? nil : kind)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            selectionFeedback.selectionChanged()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(isSelected ? .black : .white)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.yellow : Color.black.opacity(0.58))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isSelected ? 0 : 0.2), lineWidth: 1)
                    )
            )
        }
    }
}
