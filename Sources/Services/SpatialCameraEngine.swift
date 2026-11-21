import Foundation
import Combine
import AVFoundation
import CoreMotion
import Photos
import Vision
import UIKit

/// Isolated high-frequency telemetry store so 30Hz HUD updates never rebuild the main camera view tree.
final class HUDTelemetryStore: ObservableObject {
    @Published var telemetry = CameraTelemetry()
}

final class SpatialCameraEngine: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()
    let hudStore = HUDTelemetryStore()

    @Published var selectedPack: ScenePack = ScenePack.presets[0]
    @Published var activeShotIndex: Int = 0
    @Published var completedShotIds: Set<String> = []
    @Published var captureMode: CaptureMode = .photo
    @Published var isRecording: Bool = false
    @Published var recordingSeconds: Int = 0
    @Published var statusToast: String?
    @Published var overlayMode: OverlayMode = .thirds
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

    private var videoDevice: AVCaptureDevice?
    private var wideZoomFactor: Double = 1.0
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

    private var lastVisionTimestamp: TimeInterval = 0
    private var isAnalyzingVision: Bool = false
    private var lastAdviceUpdate: TimeInterval = 0
    private var cachedAdvice: CoachingAdvice = .idle
    private var cachedDetectedShot: ShotKind = .medium
    private var wasLocked: Bool = false

    private var hudTimer: DispatchSourceTimer?
    private var recordingTimer: Timer?

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    var activeShot: ShotTemplate? {
        guard !selectedPack.shots.isEmpty, selectedPack.shots.indices.contains(activeShotIndex) else {
            return nil
        }
        return selectedPack.shots[activeShotIndex]
    }

    override init() {
        super.init()
        currentTargetShot = activeShot
        if let first = activeShot {
            captureMode = first.preferredMode
        }
    }

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

    // MARK: - Session Configuration (Native Apple Quality + Live LiDAR Depth)

    private func configureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high

        // Prefer Triple Camera (0.5x / 1x / 2x / 5x) -> LiDAR Depth Camera -> Dual Wide -> Wide
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

        // Audio input for native synced video sound
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // Photo output (Smart HDR, Photonic Engine, full-resolution HEIC)
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        // Movie output (native HEVC + Cinematic Extended Stabilization + Audio)
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

            if let depthFormat = Self.selectBestDepthFormat(for: device) {
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

        // Compute lens switch-over multipliers (0.5x, 1x, 2x, 5x)
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            wideZoomFactor = device.virtualDeviceSwitchOverVideoFactors.first?.doubleValue ?? 2.0
        } else {
            wideZoomFactor = 1.0
        }

        let minMult = Double(device.minAvailableVideoZoomFactor) / wideZoomFactor
        let maxMult = Double(device.maxAvailableVideoZoomFactor) / wideZoomFactor
        let candidateLenses: [Double] = [0.5, 1.0, 2.0, 5.0]
        let supported = candidateLenses.filter { $0 >= minMult - 0.05 && $0 <= maxMult + 0.05 }

        // Start cleanly at 1.0x
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(max(Double(device.minAvailableVideoZoomFactor), wideZoomFactor))
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {}

        DispatchQueue.main.async {
            self.availableLenses = supported.isEmpty ? [1.0] : supported
            self.activeLens = 1.0
            self.hudStore.telemetry.hasLidarSupport = lidarEnabled
        }

        isConfigured = true
    }

    private static func selectBestDepthFormat(
        for device: AVCaptureDevice
    ) -> (videoFormat: AVCaptureDevice.Format?, depthFormat: AVCaptureDevice.Format)? {
        // First check active format so we keep .high / 4K if already depth-capable
        if let existing = pickDepthFormat(from: device.activeFormat.supportedDepthDataFormats) {
            return (nil, existing)
        }

        // Otherwise pick highest-resolution depth-capable video format (preferring 1920x1080+)
        let depthCapable = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        let sorted = depthCapable.sorted { lhs, rhs in
            let lDim = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDim = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return (Int(lDim.width) * Int(lDim.height)) > (Int(rDim.width) * Int(rDim.height))
        }

        for fmt in sorted {
            if let depthFmt = pickDepthFormat(from: fmt.supportedDepthDataFormats) {
                return (fmt, depthFmt)
            }
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

    // MARK: - User Controls (Lenses, Focus, Exposure, Scene Packs)

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

    func selectPack(_ pack: ScenePack) {
        selectedPack = pack
        activeShotIndex = 0
        completedShotIds.removeAll()
        if let first = pack.shots.first {
            captureMode = first.preferredMode
            if availableLenses.contains(first.recommendedLens) {
                setLens(first.recommendedLens)
            }
        }
        currentTargetShot = activeShot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    func selectShot(at index: Int) {
        guard selectedPack.shots.indices.contains(index) else { return }
        activeShotIndex = index
        let shot = selectedPack.shots[index]
        captureMode = shot.preferredMode
        if availableLenses.contains(shot.recommendedLens) {
            setLens(shot.recommendedLens)
        }
        currentTargetShot = shot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    // MARK: - CoreMotion (Background 60Hz)

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
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
                let alpha = 0.25
                self.smoothedPitchDegrees += alpha * (pitchDeg - self.smoothedPitchDegrees)
                self.smoothedRollDegrees += alpha * (horizonErrorDeg - self.smoothedRollDegrees)
                self.smoothedMotionSpeed += 0.20 * (angularSpeedDeg - self.smoothedMotionSpeed)
            } else {
                self.smoothedPitchDegrees = pitchDeg
                self.smoothedRollDegrees = horizonErrorDeg
                self.smoothedMotionSpeed = angularSpeedDeg
                self.hasMotionSample = true
            }
            self.sensorLock.unlock()
        }
    }

    // MARK: - 30Hz HUD Update Loop

    private func startHUDLoop() {
        hudTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
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
        sensorLock.unlock()

        let motionPace = ShotCoachEngine.classifyMotionPace(speedDegPerSec: motionSpeed)
        let iso = Double(videoDevice?.iso ?? 200)
        let lighting: LightingCondition = iso > 900 ? .low : (iso < 60 ? .bright : .balanced)

        let now = CACurrentMediaTime()
        if now - lastAdviceUpdate >= 0.125 {
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

    // MARK: - Capture Native Photo (Smart HDR + Photonic Engine)

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality

            if let conn = self.photoOutput.connection(with: .video) {
                conn.videoRotationAngle = self.currentVideoRotationAngle()
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Capture Native Movie (4K/1080p HEVC + Cinematic Stabilization + Audio)

    func toggleVideoRecording() {
        if isRecording {
            stopVideoRecording()
        } else {
            startVideoRecording()
        }
    }

    private func startVideoRecording() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-\(UUID().uuidString).mov")

        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            if let conn = self.movieOutput.connection(with: .video) {
                conn.videoRotationAngle = self.currentVideoRotationAngle()
            }
            self.isRecordingFlag = true
            self.movieOutput.startRecording(to: tempURL, recordingDelegate: self)

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingSeconds = 0
                self.impactFeedback.impactOccurred()
                self.recordingTimer?.invalidate()
                self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.recordingSeconds += 1
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
            captureMode = nextShot.preferredMode
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
                        self.showToast("Foto Pro guardada na galeria")
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

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.showToast("Permite acesso à galeria nas Definições")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, _ in
                try? FileManager.default.removeItem(at: outputFileURL)
                DispatchQueue.main.async {
                    if success {
                        self.notificationFeedback.notificationOccurred(.success)
                        self.markActiveShotCaptured()
                        self.showToast("Vídeo Pro guardado na galeria")
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (5Hz Apple Vision Face Tracking)

extension SpatialCameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastVisionTimestamp >= 0.20, !isAnalyzingVision else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastVisionTimestamp = now
        isAnalyzingVision = true
        defer { isAnalyzingVision = false }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: currentVisionOrientation(),
            options: [:]
        )

        do {
            try handler.perform([request])
            if let face = (request.results ?? []).max(by: {
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
