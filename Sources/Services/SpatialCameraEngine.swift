import Foundation
import Combine
import ARKit
import CoreMotion
import CoreImage
import Metal
import AVFoundation
import Photos
import Vision
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
    @Published var overlayMode: OverlayMode = .thirds

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.framepilot.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let writerQueue = DispatchQueue(label: "com.framepilot.videoWriter", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.framepilot.vision", qos: .utility)
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
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStartTimestamp: CMTime?
    private var recordingTimer: Timer?
    private var isEncodingFrame: Bool = false
    private var isRecordingFlag: Bool = false

    // Smoothed sensor state (protected by sensorLock)
    private var smoothedPitchDegrees: Double = 0
    private var smoothedRollDegrees: Double = 0
    private var smoothedMotionSpeed: Double = 0
    private var smoothedDistanceMeters: Double?
    private var hasMotionSample: Bool = false

    // Vision subject detection state
    private var lastVisionUpdate: TimeInterval = 0
    private var isAnalyzingVision: Bool = false
    private var latestFaceRect: CGRect?

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
        config.providesAudioData = true

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

    func cycleOverlayMode() {
        overlayMode = overlayMode.next
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

    private static func selectOptimalVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
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

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isRecordingFlag {
            appendVideoFrame(frame)
        }

        let now = frame.timestamp

        // Run Apple Vision face detection at ~5Hz on background utility queue
        if now - lastVisionUpdate >= 0.20 && !isAnalyzingVision {
            lastVisionUpdate = now
            runVisionFaceDetection(on: frame.capturedImage)
        }

        // Update HUD reticle & horizon at ~30Hz (33ms)
        guard now - lastHUDUpdate >= 0.033 else { return }
        lastHUDUpdate = now

        sensorLock.lock()
        let pitch = smoothedPitchDegrees
        let roll = smoothedRollDegrees
        let motionSpeed = smoothedMotionSpeed
        let faceRect = latestFaceRect
        sensorLock.unlock()

        let motionPace = ShotCoachEngine.classifyMotionPace(speedDegPerSec: motionSpeed)

        // Sample LiDAR depth & recompute coaching advice at ~8Hz (125ms)
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
                motionPace: motionPace,
                detectedFaceRect: faceRect,
                isRecording: isRecordingFlag,
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
            next.motionSpeedDegPerSec = motionSpeed
            next.motionPace = motionPace
            next.lidarDistanceMeters = currentDistance
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

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        guard isRecordingFlag else { return }

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let audioInput = self.audioInput,
                  let startTime = self.recordingStartTimestamp,
                  writer.status == .writing,
                  audioInput.isReadyForMoreMediaData else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer)
            if pts >= startTime {
                audioInput.append(audioSampleBuffer)
            }
        }
    }

    // MARK: - Apple Vision Face Detection

    private func runVisionFaceDetection(on pixelBuffer: CVPixelBuffer) {
        isAnalyzingVision = true
        let orientation = currentImageOrientation()

        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.isAnalyzingVision = false }

            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                if let face = (request.results ?? []).max(by: {
                    ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
                }) {
                    let b = face.boundingBox
                    // Convert Vision bottom-left origin to SwiftUI top-left origin
                    let converted = CGRect(x: b.minX, y: 1.0 - b.maxY, width: b.width, height: b.height)
                    self.sensorLock.lock()
                    self.latestFaceRect = converted
                    self.sensorLock.unlock()
                } else {
                    self.sensorLock.lock()
                    self.latestFaceRect = nil
                    self.sensorLock.unlock()
                }
            } catch {
                // Ignore transient Vision errors
            }
        }
    }

    /// Samples a 3x3 patch around the center of the LiDAR depth map (fast & noise-resistant).
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

    // MARK: - Capture Video (Hardware HEVC + AAC Audio + Non-Blocking Frame Drop Guard)

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

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true
                vInput.transform = transform

                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: vInput,
                    sourcePixelBufferAttributes: attrs
                )

                guard writer.canAdd(vInput) else { return }
                writer.add(vInput)

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    self.audioInput = aInput
                } else {
                    self.audioInput = nil
                }

                writer.startWriting()

                self.assetWriter = writer
                self.videoInput = vInput
                self.pixelBufferAdaptor = adaptor
                self.recordingURL = tempURL
                self.recordingStartTimestamp = nil
                self.isEncodingFrame = false
                self.isRecordingFlag = true

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
        isRecordingFlag = false
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let vInput = self.videoInput,
                  let outputURL = self.recordingURL else { return }

            vInput.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
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
                                self.showToast("Vídeo com áudio guardado")
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
