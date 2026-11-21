import Foundation
import Combine
import ARKit
import CoreMotion
import CoreImage
import Metal
import AVFoundation
import Photos
import UIKit

/// Isolated high-frequency telemetry store so 30Hz HUD updates never rebuild the main camera view tree.
final class HUDTelemetryStore: ObservableObject {
    @Published var telemetry = CameraTelemetry()
}

final class SpatialCameraEngine: NSObject, ObservableObject, ARSessionDelegate {
    let arSession = ARSession()
    let hudStore = HUDTelemetryStore()

    @Published var selectedPack: ScenePack = ScenePack.presets[0]
    @Published var activeShotIndex: Int = 0
    @Published var completedShotIds: Set<String> = []
    @Published var captureMode: CaptureMode = .video
    @Published var isRecording: Bool = false
    @Published var recordingSeconds: Int = 0
    @Published var statusToast: String?
    @Published var showGrid: Bool = true

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.framepilot.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let writerQueue = DispatchQueue(label: "com.framepilot.videoWriter", qos: .userInitiated)
    private let sensorLock = NSLock()

    // Metal-backed CIContext for GPU-accelerated photo & video frame rendering
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStartTimestamp: CMTime?
    private var recordingTimer: Timer?
    private var isEncodingFrame: Bool = false

    // Smoothed sensor state (protected by sensorLock)
    private var smoothedPitchDegrees: Double = 0
    private var smoothedRollDegrees: Double = 0
    private var smoothedDistanceMeters: Double?
    private var hasMotionSample: Bool = false

    private var lastHUDUpdate: TimeInterval = 0
    private var lastAdviceUpdate: TimeInterval = 0
    private var cachedAdvice: CoachingAdvice = .idle
    private var cachedLighting: LightingCondition = .balanced
    private var cachedDetectedShot: ShotKind = .medium
    private var wasLocked: Bool = false

    // Thread-safe snapshot of activeShot for ARSession callback
    private var currentTargetShot: ShotTemplate?

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
        arSession.delegate = self
        currentTargetShot = activeShot
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        config.planeDetection = []

        // Prefer 60fps video format for native-like viewfinder fluidity
        if let best60fps = Self.selectOptimalVideoFormat() {
            config.videoFormat = best60fps
        }

        var lidarAvailable = false
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
            lidarAvailable = true
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            lidarAvailable = true
        }

        DispatchQueue.main.async {
            self.hudStore.telemetry.hasLidarSupport = lidarAvailable
        }

        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        startMotionUpdates()
        impactFeedback.prepare()
    }

    func stop() {
        if isRecording {
            stopVideoRecording()
        }
        arSession.pause()
        motionManager.stopDeviceMotionUpdates()
    }

    func selectPack(_ pack: ScenePack) {
        selectedPack = pack
        activeShotIndex = 0
        completedShotIds.removeAll()
        if let first = pack.shots.first {
            captureMode = first.preferredMode
        }
        currentTargetShot = activeShot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    func selectShot(at index: Int) {
        guard selectedPack.shots.indices.contains(index) else { return }
        activeShotIndex = index
        captureMode = selectedPack.shots[index].preferredMode
        currentTargetShot = activeShot
        lastAdviceUpdate = 0
        wasLocked = false
    }

    func toggleShotCompleted(_ shot: ShotTemplate) {
        if completedShotIds.contains(shot.id) {
            completedShotIds.remove(shot.id)
        } else {
            completedShotIds.insert(shot.id)
        }
    }

    private static func selectOptimalVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        // Prefer 60fps formats; among 60fps, pick 1920x1080 or highest resolution up to 1080p for zero thermal throttling
        let sixtyFps = formats.filter { $0.framesPerSecond >= 60 }
        if !sixtyFps.isEmpty {
            return sixtyFps.min { lhs, rhs in
                let lhsDiff = abs(lhs.imageResolution.width - 1920)
                let rhsDiff = abs(rhs.imageResolution.width - 1920)
                return lhsDiff < rhsDiff
            }
        }
        return formats.first
    }

    // MARK: - CoreMotion (Background Queue + Exponential Smoothing)

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }

            let pitchDeg = atan2(g.z, hypot(g.x, g.y)) * 180.0 / .pi
            let rawRollDeg = atan2(g.x, -g.y) * 180.0 / .pi
            let nearestRightAngle = (rawRollDeg / 90.0).rounded() * 90.0
            let horizonErrorDeg = rawRollDeg - nearestRightAngle

            self.sensorLock.lock()
            if self.hasMotionSample {
                // Smooth low-pass filter (responsive, zero jitter)
                let alpha = 0.25
                self.smoothedPitchDegrees += alpha * (pitchDeg - self.smoothedPitchDegrees)
                self.smoothedRollDegrees += alpha * (horizonErrorDeg - self.smoothedRollDegrees)
            } else {
                self.smoothedPitchDegrees = pitchDeg
                self.smoothedRollDegrees = horizonErrorDeg
                self.hasMotionSample = true
            }
            self.sensorLock.unlock()
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isRecording {
            appendVideoFrame(frame)
        }

        // Update HUD reticle & horizon at ~30Hz (33ms) for buttery smoothness
        let now = frame.timestamp
        guard now - lastHUDUpdate >= 0.033 else { return }
        lastHUDUpdate = now

        sensorLock.lock()
        let pitch = smoothedPitchDegrees
        let roll = smoothedRollDegrees
        sensorLock.unlock()

        // Sample LiDAR depth & recompute coaching advice at ~8Hz (125ms) to avoid jitter and save CPU
        let shouldUpdateAdvice = (now - lastAdviceUpdate >= 0.125)
        var currentDistance = smoothedDistanceMeters

        if shouldUpdateAdvice {
            lastAdviceUpdate = now

            let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
            if let rawDistance = depthMap.flatMap({ Self.sampleCenterDepth(from: $0) }) {
                if let prev = smoothedDistanceMeters {
                    currentDistance = prev + 0.35 * (rawDistance - prev)
                } else {
                    currentDistance = rawDistance
                }
                smoothedDistanceMeters = currentDistance
            } else {
                currentDistance = nil
                smoothedDistanceMeters = nil
            }

            let lumens = Double(frame.lightEstimate?.ambientIntensity ?? 1000)
            cachedLighting = ShotCoachEngine.classifyLighting(lumens: lumens)
            cachedDetectedShot = ShotCoachEngine.detectShotKind(distanceMeters: currentDistance, pitchDegrees: pitch)
            cachedAdvice = ShotCoachEngine.evaluate(
                distanceMeters: currentDistance,
                pitchDegrees: pitch,
                rollDegrees: roll,
                lighting: cachedLighting,
                target: currentTargetShot
            )
        }

        let advice = cachedAdvice
        let lighting = cachedLighting
        let detected = cachedDetectedShot

        DispatchQueue.main.async {
            var next = self.hudStore.telemetry
            next.pitchDegrees = pitch
            next.rollDegrees = roll
            next.lidarDistanceMeters = currentDistance
            next.lighting = lighting
            next.detectedShotKind = detected
            next.advice = advice
            self.hudStore.telemetry = next

            if advice.isLocked && !self.wasLocked {
                self.impactFeedback.impactOccurred()
            }
            self.wasLocked = advice.isLocked
        }
    }

    /// Samples a 3x3 cross around the center of the LiDAR depth map (fast & noise-resistant).
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

    // MARK: - Capture Photo (Off-Main-Thread GPU Encoding)

    func capturePhoto() {
        guard let frame = arSession.currentFrame else { return }
        let pixelBuffer = frame.capturedImage
        let orientation = currentImageOrientation()

        writerQueue.async { [weak self] in
            guard let self else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.showToast("Permite acesso à galeria nas Definições")
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
                }) { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            self.notificationFeedback.notificationOccurred(.success)
                            self.markActiveShotCaptured()
                            self.showToast("Foto guardada na galeria")
                        } else {
                            self.showToast("Erro ao guardar foto")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Capture Video (Hardware HEVC + Non-Blocking Frame Drop Guard)

    func toggleVideoRecording() {
        if isRecording {
            stopVideoRecording()
        } else {
            startVideoRecording()
        }
    }

    private func startVideoRecording() {
        guard let frame = arSession.currentFrame else { return }
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        let transform = currentVideoTransform()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-\(UUID().uuidString).mov")

        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                input.transform = transform

                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: attrs
                )

                guard writer.canAdd(input) else { return }
                writer.add(input)
                writer.startWriting()

                self.assetWriter = writer
                self.videoInput = input
                self.pixelBufferAdaptor = adaptor
                self.recordingURL = tempURL
                self.recordingStartTimestamp = nil
                self.isEncodingFrame = false

                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingSeconds = 0
                    self.impactFeedback.impactOccurred()
                    self.recordingTimer?.invalidate()
                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        self?.recordingSeconds += 1
                    }
                }
            } catch {
                self.showToast("Não foi possível iniciar vídeo")
            }
        }
    }

    private func appendVideoFrame(_ frame: ARFrame) {
        // Never back up ARKit's frame pool: drop frame cleanly if previous GPU encode is still in flight
        guard !isEncodingFrame else { return }
        isEncodingFrame = true

        let pixelBuffer = frame.capturedImage
        let timestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)

        writerQueue.async { [weak self] in
            guard let self else { return }
            defer { self.isEncodingFrame = false }

            guard let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor,
                  writer.status == .writing,
                  input.isReadyForMoreMediaData else { return }

            if self.recordingStartTimestamp == nil {
                writer.startSession(atSourceTime: timestamp)
                self.recordingStartTimestamp = timestamp
            }

            guard let pool = adaptor.pixelBufferPool else { return }
            var renderedBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &renderedBuffer)
            if let renderedBuffer {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                self.ciContext.render(ciImage, to: renderedBuffer)
                adaptor.append(renderedBuffer, withPresentationTime: timestamp)
            }
        }
    }

    private func stopVideoRecording() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let outputURL = self.recordingURL else { return }

            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.assetWriter = nil
                self.videoInput = nil
                self.pixelBufferAdaptor = nil
                self.recordingStartTimestamp = nil
                self.isEncodingFrame = false

                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        self.showToast("Permite acesso à galeria nas Definições")
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                    }) { success, _ in
                        try? FileManager.default.removeItem(at: outputURL)
                        DispatchQueue.main.async {
                            if success {
                                self.notificationFeedback.notificationOccurred(.success)
                                self.markActiveShotCaptured()
                                self.showToast("Vídeo guardado na galeria")
                            } else {
                                self.showToast("Erro ao guardar vídeo")
                            }
                        }
                    }
                }
            }
        }
    }

    private func markActiveShotCaptured() {
        guard let shot = activeShot else { return }
        completedShotIds.insert(shot.id)
        if activeShotIndex + 1 < selectedPack.shots.count {
            activeShotIndex += 1
            captureMode = selectedPack.shots[activeShotIndex].preferredMode
            currentTargetShot = activeShot
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

    private func currentImageOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    private func currentVideoTransform() -> CGAffineTransform {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .identity
        case .landscapeRight: return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown: return CGAffineTransform(rotationAngle: -.pi / 2)
        default: return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }
}
