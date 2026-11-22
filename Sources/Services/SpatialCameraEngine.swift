import Foundation
import Combine
import AVFoundation
import CoreMotion
import Photos
import Vision
import UIKit

enum VideoQuality: String, CaseIterable {
    case hd1080p60 = "1080p 60"
    case uhd4K30 = "4K 30"

    var next: VideoQuality {
        self == .hd1080p60 ? .uhd4K30 : .hd1080p60
    }
}

enum FlashOption: String, CaseIterable {
    case auto = "Auto"
    case on = "On"
    case off = "Off"

    var next: FlashOption {
        switch self {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

enum TimerOption: Int, CaseIterable {
    case off = 0
    case three = 3
    case ten = 10

    var next: TimerOption {
        switch self {
        case .off: return .three
        case .three: return .ten
        case .ten: return .off
        }
    }

    var label: String {
        self == .off ? "Off" : "\(rawValue)s"
    }
}

/// Isolated high-frequency telemetry store so HUD updates never rebuild the main camera view tree.
final class HUDTelemetryStore: ObservableObject {
    @Published var telemetry = CameraTelemetry()
}

final class SpatialCameraEngine: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()
    let hudStore = HUDTelemetryStore()

    @Published var customPacks: [ScenePack] = CustomPackStore.load()
    @Published var selectedPack: ScenePack = ScenePack.presets[0]
    @Published var activeShotIndex: Int = 0
    @Published var completedShotIds: Set<String> = []
    @Published var sessionTakes: [String: SessionTake] = [:]
    @Published var captureMode: CaptureMode = .photo
    @Published var videoQuality: VideoQuality = .uhd4K30
    @Published var flashOption: FlashOption = .auto
    @Published var timerOption: TimerOption = .off
    @Published var autoStopEnabled: Bool = true
    @Published var countdownRemaining: Int = 0
    @Published var shutterFlashVisible: Bool = false
    @Published var isThermalEcoActive: Bool = false
    @Published var isRecording: Bool = false
    @Published var isExportingReel: Bool = false
    @Published var recordingSeconds: Int = 0
    @Published var recordingElapsed: Double = 0.0
    @Published var statusToast: String?
    @Published var overlayMode: OverlayMode = .thirds
    @Published var aspectMask: AspectMask = .full
    @Published var ghostImage: UIImage?
    @Published var showGhostOverlay: Bool = false
    @Published var availableLenses: [Double] = [1.0]
    @Published var activeLens: Double = 1.0
    @Published var exposureBias: Float = 0.0
    @Published var focusIndicatorPoint: CGPoint?

    private let sessionQueue = DispatchQueue(label: "com.framepilot.session", qos: .userInitiated)
    private let depthQueue = DispatchQueue(label: "com.framepilot.depth", qos: .utility)
    private let visionQueue = DispatchQueue(label: "com.framepilot.vision", qos: .utility)
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.framepilot.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let sensorLock = NSLock()

    // Reusable Vision request (zero per-frame allocations)
    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var videoDevice: AVCaptureDevice?
    private var wideZoomFactor: Double = 1.0
    private var pinchStartLens: Double = 1.0
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private var isConfigured = false

    // Smoothed sensor state (protected by sensorLock)
    private var smoothedPitchDegrees: Double = 0
    private var smoothedRollDegrees: Double = 0
    private var smoothedMotionSpeed: Double = 0
    private var smoothedDistanceMeters: Double?
    private var latestFaceRect: CGRect?
    private var hasMotionSample: Bool = false
    private var isRecordingFlag: Bool = false
    private var currentTargetShot: ShotTemplate?
    private var currentThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var lastVisionTimestamp: TimeInterval = 0
    private var isAnalyzingVision: Bool = false
    private var lastAdviceUpdate: TimeInterval = 0
    private var cachedAdvice: CoachingAdvice = .idle
    private var cachedDetectedShot: ShotKind = .medium
    private var wasLocked: Bool = false

    private var hudTimer: DispatchSourceTimer?
    private var recordingTimer: Timer?
    private var countdownTimer: Timer?
    private var thermalObserver: NSObjectProtocol?

    private var recordingShotId: String?
    private var recordingShotTitle: String?
    private var didHitTargetDurationHaptic: Bool = false

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    var allPacks: [ScenePack] {
        customPacks + ScenePack.presets
    }

    var activeShot: ShotTemplate? {
        guard !selectedPack.shots.isEmpty, selectedPack.shots.indices.contains(activeShotIndex) else {
            return nil
        }
        return selectedPack.shots[activeShotIndex]
    }

    var targetDurationProgress: Double {
        guard isRecording, let target = activeShot?.targetDurationSeconds, target > 0 else {
            return 0
        }
        return min(1.0, recordingElapsed / target)
    }

    var recordedVideoCount: Int {
        selectedPack.shots.compactMap { sessionTakes[$0.id] }.filter { $0.isVideo && $0.fileURL != nil }.count
    }

    override init() {
        super.init()
        currentTargetShot = activeShot
        if let first = activeShot {
            captureMode = first.preferredMode
        }
        observeThermalState()
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Thermal & Battery Protection

    private func observeThermalState() {
        updateThermalState()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
    }

    private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        sensorLock.lock()
        currentThermalState = state
        sensorLock.unlock()

        let ecoNeeded = (state == .serious || state == .critical)
        DispatchQueue.main.async {
            if ecoNeeded && !self.isThermalEcoActive {
                self.showToast("Modo frio ativo — a proteger bateria")
            }
            self.isThermalEcoActive = ecoNeeded
        }

        // Automatically cap frame rate to 30fps if device starts getting warm
        if ecoNeeded {
            sessionQueue.async { [weak self] in
                self?.applyThermalSafeFrameRate()
            }
        }
    }

    private func applyThermalSafeFrameRate() {
        guard let device = videoDevice else { return }
        let targetFps: Int32 = (captureMode == .video && videoQuality == .hd1080p60 && currentThermalState == .nominal) ? 60 : 30
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(targetFps) && $0.maxFrameRate >= Double(targetFps)
        }
        guard supported else { return }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: targetFps)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - Lifecycle (Strict Background Shutdown = 0% Battery Drain)

    func start() {
        impactFeedback.prepare()
        startMotionUpdates()
        startHUDLoop()

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showToast("Permite acesso à câmara nas Definições")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            self.sessionQueue.async {
                if !self.isConfigured {
                    self.configureSession()
                }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
            }
        }
    }

    func stop() {
        cancelCountdown()
        hudTimer?.cancel()
        hudTimer = nil
        motionManager.stopDeviceMotionUpdates()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    // MARK: - Session Configuration (Max Quality + Thermal Efficiency + Live LiDAR)

    private func configureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high

        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInLiDARDepthCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first,
              let videoInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(videoInput) else {
            showToast("Câmara traseira indisponível")
            return
        }

        captureSession.addInput(videoInput)
        videoDevice = device

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // Photo Output: Smart HDR + Photonic Engine + Max Resolution + Zero Shutter Lag
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
        }

        // Movie Output: Native HEVC + Cinematic Extended Stabilization
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            if let videoConn = movieOutput.connection(with: .video) {
                if videoConn.isVideoStabilizationSupported {
                    videoConn.preferredVideoStabilizationMode = .cinematicExtended
                }
                if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: videoConn)
                }
            }
        }

        // Lightweight VideoDataOutput for background Apple Vision face tracking
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: visionQueue)
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }

        // Live LiDAR Depth Data Output
        var lidarEnabled = false
        if captureSession.canAddOutput(depthDataOutput) {
            captureSession.addOutput(depthDataOutput)
            depthDataOutput.isFilteringEnabled = true
            depthDataOutput.setDelegate(self, callbackQueue: depthQueue)

            if let depthFormat = Self.selectBestDepthFormat(for: device, prefer4K: videoQuality == .uhd4K30) {
                do {
                    try device.lockForConfiguration()
                    if let videoFormat = depthFormat.videoFormat {
                        device.activeFormat = videoFormat
                    }
                    device.activeDepthDataFormat = depthFormat.depthFormat
                    device.unlockForConfiguration()
                    if let conn = depthDataOutput.connection(with: .depthData) {
                        conn.isEnabled = true
                    }
                    lidarEnabled = true
                } catch {
                    lidarEnabled = false
                }
            }
        }

        // Unlock highest supported photo resolution (24MP / 48MP on Pro Max)
        applyMaxPhotoDimensions(for: device)

        // Compute lens switch-over multipliers (0.5x, 1x, 2x, 5x)
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            wideZoomFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2.0
        } else {
            wideZoomFactor = 1.0
        }

        let minMult = Double(device.minAvailableVideoZoomFactor) / wideZoomFactor
        let maxMult = Double(device.maxAvailableVideoZoomFactor) / wideZoomFactor
        let candidateLenses: [Double] = [0.5, 1.0, 2.0, 5.0]
        let supported = candidateLenses.filter { $0 >= minMult - 0.05 && $0 <= maxMult + 0.05 }

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(max(Double(device.minAvailableVideoZoomFactor), wideZoomFactor))
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = true
            }
            device.unlockForConfiguration()
        } catch {}

        applyThermalSafeFrameRate()

        DispatchQueue.main.async {
            self.availableLenses = supported.isEmpty ? [1.0] : supported
            self.activeLens = 1.0
            self.hudStore.telemetry.hasLidarSupport = lidarEnabled
        }

        isConfigured = true
    }

    private func applyMaxPhotoDimensions(for device: AVCaptureDevice) {
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height))
        }) {
            photoOutput.maxPhotoDimensions = maxDim
        }
    }

    private static func selectBestDepthFormat(
        for device: AVCaptureDevice,
        prefer4K: Bool
    ) -> (videoFormat: AVCaptureDevice.Format?, depthFormat: AVCaptureDevice.Format)? {
        let depthCapable = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        let targetWidth: Int32 = prefer4K ? 3840 : 1920

        let sorted = depthCapable.sorted { lhs, rhs in
            let lDim = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDim = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lDiff = abs(lDim.width - targetWidth)
            let rDiff = abs(rDim.width - targetWidth)
            if lDiff != rDiff { return lDiff < rDiff }
            let lMaxFps = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            let rMaxFps = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            return lMaxFps > rMaxFps
        }

        for fmt in sorted {
            if let depthFmt = pickDepthFormat(from: fmt.supportedDepthDataFormats) {
                return (fmt, depthFmt)
            }
        }

        if let existing = pickDepthFormat(from: device.activeFormat.supportedDepthDataFormats) {
            return (nil, existing)
        }
        return nil
    }

    private static func pickDepthFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        let preferredTypes: [OSType] = [
            kCVPixelFormatType_DepthFloat32,
            kCVPixelFormatType_DepthFloat16,
            kCVPixelFormatType_DisparityFloat32,
            kCVPixelFormatType_DisparityFloat16
        ]
        for type in preferredTypes {
            if let match = formats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == type
            }) {
                return match
            }
        }
        return formats.first
    }

    // MARK: - User Controls (Lenses, Pinch, Focus, Exposure, Quality, Flash, Timer)

    func setCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        sessionQueue.async { [weak self] in
            self?.applyThermalSafeFrameRate()
        }
    }

    func toggleVideoQuality() {
        guard !isRecording else { return }
        videoQuality = videoQuality.next
        let prefer4K = (videoQuality == .uhd4K30)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.captureSession.beginConfiguration()
            if let depthFormat = Self.selectBestDepthFormat(for: device, prefer4K: prefer4K) {
                do {
                    try device.lockForConfiguration()
                    if let videoFormat = depthFormat.videoFormat {
                        device.activeFormat = videoFormat
                    }
                    device.activeDepthDataFormat = depthFormat.depthFormat
                    if device.activeFormat.isVideoHDRSupported {
                        device.automaticallyAdjustsVideoHDREnabled = true
                    }
                    device.unlockForConfiguration()
                } catch {}
                self.applyMaxPhotoDimensions(for: device)
            }
            self.captureSession.commitConfiguration()
            self.applyThermalSafeFrameRate()
        }
    }

    func cycleFlash() {
        flashOption = flashOption.next
    }

    func cycleTimer() {
        timerOption = timerOption.next
    }

    func setLens(_ multiplier: Double) {
        activeLens = multiplier
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let rawFactor = multiplier * self.wideZoomFactor
            let clamped = max(
                device.minAvailableVideoZoomFactor,
                min(device.maxAvailableVideoZoomFactor, CGFloat(rawFactor))
            )
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: clamped, withRate: 14.0)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func handlePinchZoom(scale: CGFloat, state: UIGestureRecognizer.State) {
        if state == .began {
            pinchStartLens = activeLens
            return
        }
        guard state == .changed else { return }
        let minLens = availableLenses.first ?? 0.5
        let maxLens = max(availableLenses.last ?? 5.0, 10.0)
        let target = max(minLens, min(maxLens, pinchStartLens * Double(scale)))
        activeLens = target

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let rawFactor = target * self.wideZoomFactor
            let clamped = max(
                device.minAvailableVideoZoomFactor,
                min(device.maxAvailableVideoZoomFactor, CGFloat(rawFactor))
            )
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func focus(at devicePoint: CGPoint, screenPoint: CGPoint) {
        DispatchQueue.main.async {
            self.focusIndicatorPoint = screenPoint
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                if self?.focusIndicatorPoint == screenPoint {
                    self?.focusIndicatorPoint = nil
                }
            }
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setExposureBias(_ ev: Float) {
        let clamped = max(-2.0, min(2.0, ev))
        exposureBias = clamped
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let deviceClamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, clamped))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(deviceClamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func cycleOverlayMode() {
        overlayMode = overlayMode.next
    }

    func cycleAspectMask() {
        aspectMask = aspectMask.next
    }

    func toggleGhostOverlay() {
        guard ghostImage != nil else {
            showToast("Capta 1 foto ou vídeo primeiro para o Ghost Frame")
            return
        }
        showGhostOverlay.toggle()
    }

    func selectPack(_ pack: ScenePack) {
        clearSessionFiles()
        selectedPack = pack
        activeShotIndex = 0
        completedShotIds.removeAll()
        sessionTakes.removeAll()
        if let first = pack.shots.first {
            setCaptureMode(first.preferredMode)
            if availableLenses.contains(first.recommendedLens) {
                setLens(first.recommendedLens)
            }
        }
        currentTargetShot = activeShot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    func addCustomPack(_ pack: ScenePack) {
        customPacks.insert(pack, at: 0)
        CustomPackStore.save(customPacks)
        selectPack(pack)
        showToast("Guião \"\(pack.name)\" guardado")
    }

    func deleteCustomPack(id: String) {
        customPacks.removeAll { $0.id == id }
        CustomPackStore.save(customPacks)
        if selectedPack.id == id {
            selectPack(ScenePack.presets[0])
        }
    }

    func toggleAutoStop() {
        autoStopEnabled.toggle()
        showToast(autoStopEnabled ? "Auto-Stop na duração alvo: Ligado" : "Auto-Stop: Manual")
    }

    func exportSessionReel() {
        guard !isExportingReel else { return }
        let orderedURLs = selectedPack.shots
            .compactMap { sessionTakes[$0.id] }
            .filter { $0.isVideo }
            .compactMap { $0.fileURL }

        guard !orderedURLs.isEmpty else {
            showToast("Grava pelo menos 1 plano em vídeo primeiro")
            return
        }

        isExportingReel = true
        Task {
            do {
                try await ReelExporter.exportReel(videoURLs: orderedURLs)
                await MainActor.run {
                    self.isExportingReel = false
                    self.notificationFeedback.notificationOccurred(.success)
                    self.showToast("Reel montado (\(orderedURLs.count) planos) guardado!")
                }
            } catch {
                await MainActor.run {
                    self.isExportingReel = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    private func sessionClipURL(for shotId: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FramePilotSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(shotId)-\(UUID().uuidString).mov")
        return url
    }

    private func clearSessionFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FramePilotSession", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func selectShot(at index: Int) {
        guard selectedPack.shots.indices.contains(index) else { return }
        activeShotIndex = index
        let shot = selectedPack.shots[index]
        setCaptureMode(shot.preferredMode)
        if availableLenses.contains(shot.recommendedLens) {
            setLens(shot.recommendedLens)
        }
        currentTargetShot = shot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    // MARK: - CoreMotion (Power-Efficient 30Hz Background Sampling)

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let r = motion.rotationRate

            let pitchDeg = atan2(g.z, hypot(g.x, g.y)) * 180.0 / .pi
            let rawRollDeg = atan2(g.x, -g.y) * 180.0 / .pi
            let nearestRightAngle = (rawRollDeg / 90.0).rounded() * 90.0
            let horizonErrorDeg = rawRollDeg - nearestRightAngle
            let angularSpeedDeg = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180.0 / .pi

            self.sensorLock.lock()
            if self.hasMotionSample {
                let alpha = 0.28
                self.smoothedPitchDegrees += alpha * (pitchDeg - self.smoothedPitchDegrees)
                self.smoothedRollDegrees += alpha * (horizonErrorDeg - self.smoothedRollDegrees)
                self.smoothedMotionSpeed += 0.22 * (angularSpeedDeg - self.smoothedMotionSpeed)
            } else {
                self.smoothedPitchDegrees = pitchDeg
                self.smoothedRollDegrees = horizonErrorDeg
                self.smoothedMotionSpeed = angularSpeedDeg
                self.hasMotionSample = true
            }
            self.sensorLock.unlock()
        }
    }

    // MARK: - Adaptive HUD Update Loop (20Hz nominal, 10Hz thermal eco)

    private func startHUDLoop() {
        hudTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.publishHUDTick()
        }
        timer.resume()
        hudTimer = timer
    }

    private func publishHUDTick() {
        sensorLock.lock()
        let pitch = smoothedPitchDegrees
        let roll = smoothedRollDegrees
        let motionSpeed = smoothedMotionSpeed
        let distance = smoothedDistanceMeters
        let faceRect = latestFaceRect
        let thermal = currentThermalState
        sensorLock.unlock()

        let motionPace = ShotCoachEngine.classifyMotionPace(speedDegPerSec: motionSpeed)
        let iso = Double(videoDevice?.iso ?? 200)
        let lighting: LightingCondition = iso > 900 ? .low : (iso < 60 ? .bright : .balanced)

        let adviceInterval = (thermal == .serious || thermal == .critical) ? 0.30 : 0.15
        let now = CACurrentMediaTime()
        if now - lastAdviceUpdate >= adviceInterval {
            lastAdviceUpdate = now
            cachedDetectedShot = ShotCoachEngine.detectShotKind(distanceMeters: distance, pitchDegrees: pitch)
            cachedAdvice = ShotCoachEngine.evaluate(
                distanceMeters: distance,
                pitchDegrees: pitch,
                rollDegrees: roll,
                lighting: lighting,
                motionPace: motionPace,
                detectedFaceRect: faceRect,
                isRecording: isRecordingFlag,
                target: currentTargetShot
            )
        }

        let advice = cachedAdvice
        let detected = cachedDetectedShot

        DispatchQueue.main.async {
            var next = self.hudStore.telemetry
            next.pitchDegrees = pitch
            next.rollDegrees = roll
            next.motionSpeedDegPerSec = motionSpeed
            next.motionPace = motionPace
            next.lidarDistanceMeters = distance
            next.lighting = lighting
            next.detectedShotKind = detected
            next.detectedFaceRect = faceRect
            next.advice = advice
            self.hudStore.telemetry = next

            if advice.isLocked && !self.wasLocked {
                self.impactFeedback.impactOccurred()
            }
            self.wasLocked = advice.isLocked
        }
    }

    // MARK: - Shutter & Countdown

    func triggerShutter() {
        if countdownRemaining > 0 {
            cancelCountdown()
            return
        }

        if captureMode == .video && isRecording {
            stopVideoRecording()
            return
        }

        if timerOption != .off {
            startCountdown(seconds: timerOption.rawValue) { [weak self] in
                guard let self else { return }
                if self.captureMode == .photo {
                    self.capturePhotoNow()
                } else {
                    self.startVideoRecording()
                }
            }
        } else {
            if captureMode == .photo {
                capturePhotoNow()
            } else {
                startVideoRecording()
            }
        }
    }

    private func startCountdown(seconds: Int, completion: @escaping () -> Void) {
        countdownRemaining = seconds
        impactFeedback.impactOccurred()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.countdownRemaining > 1 {
                self.countdownRemaining -= 1
                self.impactFeedback.impactOccurred()
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.countdownRemaining = 0
                completion()
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private func capturePhotoNow() {
        DispatchQueue.main.async {
            self.shutterFlashVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.shutterFlashVisible = false
            }
        }

        let desiredFlash = flashOption.avFlashMode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if self.photoOutput.supportedFlashModes.contains(desiredFlash) {
                settings.flashMode = desiredFlash
            }

            if let conn = self.photoOutput.connection(with: .video) {
                conn.videoRotationAngle = self.currentVideoRotationAngle()
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startVideoRecording() {
        let shotId = activeShot?.id ?? "free-\(UUID().uuidString)"
        let shotTitle = activeShot?.title ?? "Plano Livre"
        let targetDuration = activeShot?.targetDurationSeconds
        let shouldAutoStop = autoStopEnabled && targetDuration != nil
        let clipURL = sessionClipURL(for: shotId)

        recordingShotId = shotId
        recordingShotTitle = shotTitle
        didHitTargetDurationHaptic = false

        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            if let conn = self.movieOutput.connection(with: .video) {
                conn.videoRotationAngle = self.currentVideoRotationAngle()
            }
            self.isRecordingFlag = true
            self.movieOutput.startRecording(to: clipURL, recordingDelegate: self)

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingSeconds = 0
                self.recordingElapsed = 0.0
                self.impactFeedback.impactOccurred()
                self.recordingTimer?.invalidate()
                self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.recordingElapsed += 0.1
                    self.recordingSeconds = Int(self.recordingElapsed)

                    if let target = targetDuration, self.recordingElapsed >= target {
                        if !self.didHitTargetDurationHaptic {
                            self.didHitTargetDurationHaptic = true
                            self.impactFeedback.impactOccurred()
                        }
                        if shouldAutoStop {
                            self.stopVideoRecording()
                        }
                    }
                }
            }
        }
    }

    private func stopVideoRecording() {
        isRecordingFlag = false
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }

        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    private func markActiveShotCaptured() {
        guard let shot = activeShot else { return }
        completedShotIds.insert(shot.id)
        if activeShotIndex + 1 < selectedPack.shots.count {
            activeShotIndex += 1
            let nextShot = selectedPack.shots[activeShotIndex]
            setCaptureMode(nextShot.preferredMode)
            if availableLenses.contains(nextShot.recommendedLens) {
                setLens(nextShot.recommendedLens)
            }
            currentTargetShot = nextShot
            lastAdviceUpdate = 0
            wasLocked = false
        }
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.statusToast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                if self?.statusToast == text {
                    self?.statusToast = nil
                }
            }
        }
    }

    private func currentVideoRotationAngle() -> CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    private func currentVisionOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension SpatialCameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            showToast("Erro ao capturar foto")
            return
        }

        if let preview = Self.downscaledGhostImage(from: data) {
            DispatchQueue.main.async {
                self.ghostImage = preview
                if let shot = self.activeShot {
                    self.sessionTakes[shot.id] = SessionTake(
                        shotId: shot.id,
                        shotTitle: shot.title,
                        isVideo: false,
                        fileURL: nil,
                        thumbnail: preview,
                        durationSeconds: 0
                    )
                }
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.showToast("Permite acesso à galeria nas Definições")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self.notificationFeedback.notificationOccurred(.success)
                        self.markActiveShotCaptured()
                        self.showToast("Foto HD Pro guardada")
                    } else {
                        self.showToast("Erro ao guardar foto")
                    }
                }
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension SpatialCameraEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            showToast("Erro na gravação de vídeo")
            return
        }

        // Extract last frame of the recorded clip for Match Cut Ghost Overlay & Storyboard thumbnail
        let lastFrame = Self.extractLastVideoFrame(from: outputFileURL)
        let capturedShotId = recordingShotId
        let capturedShotTitle = recordingShotTitle ?? "Plano"
        let clipDuration = AVURLAsset(url: outputFileURL).duration.seconds

        DispatchQueue.main.async {
            if let lastFrame {
                self.ghostImage = lastFrame
            }
            if let capturedShotId {
                // Clean up previous retake file for the same shot if any
                if let oldURL = self.sessionTakes[capturedShotId]?.fileURL, oldURL != outputFileURL {
                    try? FileManager.default.removeItem(at: oldURL)
                }
                self.sessionTakes[capturedShotId] = SessionTake(
                    shotId: capturedShotId,
                    shotTitle: capturedShotTitle,
                    isVideo: true,
                    fileURL: outputFileURL,
                    thumbnail: lastFrame,
                    durationSeconds: clipDuration.isFinite ? clipDuration : self.recordingElapsed
                )
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.showToast("Permite acesso à galeria nas Definições")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self.notificationFeedback.notificationOccurred(.success)
                        self.markActiveShotCaptured()
                        self.showToast("Vídeo Pro guardado")
                    } else {
                        self.showToast("Erro ao guardar vídeo")
                    }
                }
            }
        }
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate (Live LiDAR Distance)

extension SpatialCameraEngine: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = converted.depthDataMap

        guard let rawDistance = Self.sampleCenterDepth(from: depthMap) else { return }

        sensorLock.lock()
        if let prev = smoothedDistanceMeters {
            smoothedDistanceMeters = prev + 0.35 * (rawDistance - prev)
        } else {
            smoothedDistanceMeters = rawDistance
        }
        sensorLock.unlock()
    }

    private static func sampleCenterDepth(from depthMap: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let cx = width / 2
        let cy = height / 2

        var samples: [Float] = []
        samples.reserveCapacity(9)

        for dy in -1...1 {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for dx in -1...1 {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let value = rowPtr[x]
                if value.isFinite && value > 0.08 && value < 8.0 {
                    samples.append(value)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    private static func downscaledGhostImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 900
        let scale = min(1.0, maxDim / max(image.size.width, image.size.height))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func extractLastVideoFrame(from url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 1600)
        let duration = asset.duration
        let targetTime = CMTime(seconds: max(0, duration.seconds - 0.08), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: targetTime, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Thermal-Aware Zero-Alloc Vision)

extension SpatialCameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sensorLock.lock()
        let thermal = currentThermalState
        sensorLock.unlock()

        // Pause Vision completely if device gets seriously warm to protect battery
        if thermal == .serious || thermal == .critical {
            sensorLock.lock()
            latestFaceRect = nil
            sensorLock.unlock()
            return
        }

        // Throttle Vision: 4Hz normal, 2Hz while recording, 1.5Hz if warm (.fair)
        let minInterval: TimeInterval
        if thermal == .fair {
            minInterval = 0.65
        } else if isRecordingFlag {
            minInterval = 0.50
        } else {
            minInterval = 0.25
        }

        let now = CACurrentMediaTime()
        guard now - lastVisionTimestamp >= minInterval, !isAnalyzingVision else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastVisionTimestamp = now
        isAnalyzingVision = true
        defer { isAnalyzingVision = false }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: currentVisionOrientation(),
            options: [:]
        )

        do {
            try handler.perform([faceRequest])
            if let face = (faceRequest.results ?? []).max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            }) {
                let b = face.boundingBox
                let converted = CGRect(x: b.minX, y: 1.0 - b.maxY, width: b.width, height: b.height)
                sensorLock.lock()
                latestFaceRect = converted
                sensorLock.unlock()
            } else {
                sensorLock.lock()
                latestFaceRect = nil
                sensorLock.unlock()
            }
        } catch {}
    }
}
