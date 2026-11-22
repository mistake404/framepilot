import Foundation
import Combine
import AVFoundation
import CoreMotion
import ImageIO
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
    @Published var captureMode: CaptureMode = .photo {
        didSet {
            guard oldValue != captureMode else { return }
            cancelRackFocus()
            requestConfiguration()
        }
    }
    @Published var videoQuality: VideoQuality = .uhd4K30 {
        didSet {
            guard oldValue != videoQuality else { return }
            cancelRackFocus()
            requestConfiguration()
        }
    }
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
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var exposureBias: Float = 0.0
    @Published var focusIndicatorPoint: CGPoint?
    @Published var isAEAFLocked: Bool = false
    @Published var focusMarkA: FocusMark?
    @Published var focusMarkB: FocusMark?
    @Published var isRackFocusing: Bool = false
    @Published var isVirtualDollyActive: Bool = false
    @Published var includeSoundDesign: Bool = true
    @Published var includeDynamicCaptions: Bool = false
    @Published var editedTranscriptions: [URL: CaptionService.Transcription] = [:]
    @Published var isPreparingCaptions: Bool = false
    @Published private(set) var selectedMusicURL: URL?
    @Published private(set) var isImportingMusic = false
    @Published var beatSyncEnabled = true
    @Published var autoDuckingEnabled = true
    @Published var selectedTransition: ReelTransition = .zoomPunch
    @Published var removeSilencesEnabled = false
    @Published private(set) var selectedLUTURL: URL?
    @Published private(set) var isImportingLUT = false

    // UI state lives on the main queue. Capture graph and lens commands live on sessionQueue.
    private var startID: UUID?
    private var hudDevice: AVCaptureDevice?
    private var rackID: UUID?
    private var markGeneration: UInt = 0
    private var captureBusy = false
    private var packGeneration = UUID()
    private var requestedPosition: AVCaptureDevice.Position = .back
    private var rackFocusTimer: DispatchSourceTimer?
    private var currentRackFocusProgress: Double?
    private var currentRackFocusTarget: String?

    private let sessionQueue = DispatchQueue(label: "com.framepilot.session", qos: .userInitiated)
    private let depthQueue = DispatchQueue(label: "com.framepilot.depth", qos: .utility)
    private let visionQueue = DispatchQueue(label: "com.framepilot.vision", qos: .utility)
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.framepilot.motion"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let sensorLock = NSLock()

    // Accessed only on visionQueue.
    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var wideZoomFactor: Double = 1.0
    private var pinchStartLens: Double = 1.0
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private var requestedMode: CaptureMode = .photo
    private var requestedQuality: VideoQuality = .uhd4K30
    private var sessionPosition: AVCaptureDevice.Position = .back
    private var requestingAudioAccess = false
    private var runningRequested = false
    private var isConfigured = false
    private var needsConfiguration = true
    private var photoInFlight = false
    private var movieInFlight = false
    private var stopMovieRequested = false
    private var lastDepthTimestamp: TimeInterval = 0
    private var analysisGeneration: UInt = 0
    private var depthConnection: AVCaptureConnection?
    private var visionConnection: AVCaptureConnection?
    private var visionOrientation: CGImagePropertyOrientation = .right

    // Smoothed sensor state (protected by sensorLock)
    private var smoothedPitchDegrees: Double = 0
    private var smoothedRollDegrees: Double = 0
    private var smoothedMotionSpeed: Double = 0
    private var smoothedDistanceMeters: Double?
    private var latestFaceRect: CGRect?
    private var hasMotionSample: Bool = false
    private var motionGeneration: UInt = 0
    private var isRecordingFlag: Bool = false
    private var isFrontCameraFlag: Bool = false
    private var currentThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var lastVisionTimestamp: TimeInterval = 0
    private var currentTargetShot: ShotTemplate?
    private var lastAdviceUpdate: TimeInterval = 0
    private var cachedAdvice: CoachingAdvice = .idle
    private var cachedDetectedShot: ShotKind = .medium
    private var wasLocked: Bool = false

    private var hudTimer: DispatchSourceTimer?
    private var recordingTimer: Timer?
    private var countdownTimer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    private struct ShotContext {
        let id: String
        let title: String
        let generation: UUID
    }

    // Main-queue ownership, including all delegate handoffs.
    private var captureContext: ShotContext?
    private let clipDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FramePilotSession", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var recordingURL: URL?
    private var recordingTarget: Double?
    private var autoStopRecording = false
    // sessionQueue combines the processing and terminal callbacks for a single photo.
    private var processedPhotoData: Data?

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
        observeSession()
    }

    deinit {
        for url in [selectedMusicURL, selectedLUTURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        hudTimer?.cancel()
        rackFocusTimer?.cancel()
        let timers = [countdownTimer, recordingTimer]
        DispatchQueue.main.async { timers.forEach { $0?.invalidate() } }
        motionManager.stopDeviceMotionUpdates()
        let directory = clipDirectory
        let session = captureSession
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            try? FileManager.default.removeItem(at: directory)
        }
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
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
        if ecoNeeded && !isThermalEcoActive {
            showToast("Modo frio ativo — a proteger bateria")
        }
        isThermalEcoActive = ecoNeeded
        if hudTimer != nil {
            startHUDLoop()
            motionManager.deviceMotionUpdateInterval = ecoNeeded ? 0.1 : 1.0 / 30.0
        }
        sessionQueue.async { [weak self] in self?.updateAnalysisOutputs() }
    }

    // MARK: - Lifecycle

    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification,
                                                   object: captureSession, queue: .main) { [weak self] _ in
            self?.stopTelemetry()
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                   object: captureSession, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cancelRackFocus()
            self.cancelCountdown()
            self.stopTelemetry()
            self.sessionQueue.async { self.updateAnalysisOutputs() }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                   object: captureSession, queue: .main) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.photoInFlight || self.movieInFlight {
                    self.updateAnalysisOutputs()
                    if self.runningRequested && self.captureSession.isRunning { self.startTelemetryIfNeeded() }
                } else {
                    self.resumeSessionIfNeeded()
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                   object: captureSession, queue: .main) { [weak self] note in
            guard let self, self.startID != nil else { return }
            self.cancelRackFocus()
            guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError,
                  error.code == AVError.Code.mediaServicesWereReset.rawValue else {
                self.showToast("A sessão da câmara foi interrompida")
                return
            }
            self.sessionQueue.async {
                self.needsConfiguration = true
                self.resumeSessionIfNeeded()
            }
        })
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard startID == nil else { return }
        let id = UUID()
        startID = id
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.startID == id else { return }
                guard granted else {
                    self.startID = nil
                    self.showToast("Permite acesso à câmara nas Definições")
                    return
                }
                self.impactFeedback.prepare()
                self.requestConfiguration(activate: true)
            }
        }
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop() }
            return
        }
        startID = nil
        markGeneration &+= 1
        cancelCountdown()
        cancelRackFocus()
        stopTelemetry()
        isVirtualDollyActive = false
        hudStore.telemetry = CameraTelemetry()
        lastAdviceUpdate = 0
        wasLocked = false
        resetRecordingUI()
        sessionQueue.async {
            self.runningRequested = false
            self.updateAnalysisOutputs()
            if self.movieInFlight { self.requestMovieStop() }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
        }
    }

    private func requestConfiguration(activate: Bool = false) {
        let mode = captureMode
        let quality = videoQuality
        let position = requestedPosition
        sessionQueue.async {
            if activate { self.runningRequested = true }
            if self.requestedMode != mode || self.sessionPosition != position ||
                (mode == .video && self.requestedQuality != quality) {
                self.needsConfiguration = true
            }
            self.requestedMode = mode
            self.requestedQuality = quality
            self.sessionPosition = position
            self.resumeSessionIfNeeded()
        }
    }

    private func resumeSessionIfNeeded() {
        guard runningRequested, !captureSession.isInterrupted, !photoInFlight, !movieInFlight else { return }
        if requestedMode == .video, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            guard !requestingAudioAccess else { return }
            requestingAudioAccess = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.requestingAudioAccess = false
                    self.resumeSessionIfNeeded()
                }
            }
            return
        }
        if needsConfiguration || !isConfigured {
            isConfigured = configureSession()
            needsConfiguration = !isConfigured
        }
        updateAnalysisOutputs()
        guard isConfigured else {
            if captureSession.isRunning { captureSession.stopRunning() }
            return
        }
        if !captureSession.isRunning { captureSession.startRunning() }
        if captureSession.isRunning { startTelemetryIfNeeded() }
    }

    private func startTelemetryIfNeeded() {
        DispatchQueue.main.async {
            guard self.startID != nil, self.hudTimer == nil else { return }
            self.startMotionUpdates()
            self.startHUDLoop()
        }
    }

    private func stopTelemetry() {
        hudTimer?.cancel()
        hudTimer = nil
        motionManager.stopDeviceMotionUpdates()
        sensorLock.lock()
        motionGeneration &+= 1
        hasMotionSample = false
        smoothedPitchDegrees = 0
        smoothedRollDegrees = 0
        smoothedMotionSpeed = 0
        sensorLock.unlock()
    }

    // MARK: - Capture graph (sessionQueue)

    private static func photoArea(_ format: AVCaptureDevice.Format) -> Int64 {
        format.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
    }

    private static func photoQualityRank(_ format: AVCaptureDevice.Format) -> Int {
        if format.isHighestPhotoQualitySupported { return 2 }
        return format.isHighPhotoQualitySupported ? 1 : 0
    }

    private func bestFormat(on device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let photos = requestedMode == .photo
        let primaryClass: AnyClass = photos ? AVCapturePhotoOutput.self : AVCaptureMovieFileOutput.self
        let fourK = requestedQuality == .uhd4K30
        let fps: Double = fourK ? 30 : 60
        var best: AVCaptureDevice.Format?
        var bestScore: (Int64, Int, Int, Int, Int64) = (-1, 0, 0, 0, 0)
        for format in device.formats {
            guard !format.unsupportedCaptureOutputClasses.contains(where: { $0 == primaryClass }) else { continue }
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if !photos {
                guard size.width == (fourK ? 3840 : 1920), size.height == (fourK ? 2160 : 1080),
                      format.videoSupportedFrameRateRanges.contains(where: {
                          $0.minFrameRate <= fps && fps <= $0.maxFrameRate
                      }) else { continue }
            }
            let area = photos ? Self.photoArea(format) : 0
            if photos && area == 0 { continue }
            let quality = photos ? Self.photoQualityRank(format) : 0
            let score = (area, quality,
                         !format.supportedDepthDataFormats.isEmpty ? 1 : 0,
                         format === device.activeFormat ? 1 : 0, -Int64(size.width) * Int64(size.height))
            if score > bestScore {
                bestScore = score
                best = format
            }
        }
        return best
    }

    private func configureSession() -> Bool {
        let back = sessionPosition == .back
        let types: [AVCaptureDevice.DeviceType] = back
            ? [.builtInTripleCamera, .builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                       position: sessionPosition).devices
        let candidates = devices.compactMap { device in bestFormat(on: device).map { (device, $0) } }
        // Prefer the current lens when it can deliver the same native resolution.
        let ranked = candidates.sorted { lhs, rhs in
            if requestedMode == .photo {
                let l = Self.photoArea(lhs.1), r = Self.photoArea(rhs.1)
                if l != r { return l > r }
                let lQuality = Self.photoQualityRank(lhs.1), rQuality = Self.photoQualityRank(rhs.1)
                if lQuality != rQuality { return lQuality > rQuality }
            }
            let lDepth = !lhs.1.supportedDepthDataFormats.isEmpty
            let rDepth = !rhs.1.supportedDepthDataFormats.isEmpty
            if back && lDepth != rDepth { return lDepth }
            if back && lDepth && rDepth {
                let lLidar = lhs.0.deviceType == .builtInLiDARDepthCamera
                let rLidar = rhs.0.deviceType == .builtInLiDARDepthCamera
                if lLidar != rLidar { return lLidar }
            }
            if lhs.0 === videoDevice { return rhs.0 !== videoDevice }
            if rhs.0 === videoDevice { return false }
            return (types.firstIndex(of: lhs.0.deviceType) ?? types.count)
                < (types.firstIndex(of: rhs.0.deviceType) ?? types.count)
        }
        guard let (device, format) = ranked.first else {
            showToast("Formato de captura indisponível nesta câmara")
            return false
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        cancelHardwareRack()
        invalidateAnalysis()
        let switched = videoInput?.device !== device
        let photos = requestedMode == .photo
        let primary: AVCaptureOutput = photos ? photoOutput : movieOutput
        for output in captureSession.outputs where switched || output !== primary {
            captureSession.removeOutput(output)
        }
        if switched {
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                showToast("Câmara indisponível")
                return false
            }
            let old = videoInput
            if let old { captureSession.removeInput(old) }
            guard captureSession.canAddInput(input) else {
                if let old, captureSession.canAddInput(old) {
                    captureSession.addInput(old)
                } else {
                    videoInput = nil
                    videoDevice = nil
                }
                showToast("Não foi possível mudar de câmara")
                return false
            }
            captureSession.addInput(input)
            videoInput = input
            videoDevice = device
        }
        if let audio = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.audio) }) {
            if photos { captureSession.removeInput(audio) }
        } else if !photos, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic), captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            if !photos {
                let duration = CMTime(value: 1, timescale: requestedQuality == .uhd4K30 ? 30 : 60)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } else {
                device.activeVideoMaxFrameDuration = .invalid
                device.activeVideoMinFrameDuration = .invalid
            }
            if back, let depth = Self.pickDepthFormat(from: format.supportedDepthDataFormats) {
                device.activeDepthDataFormat = depth
            }
            if switched {
                wideZoomFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1
                device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor,
                                              max(device.minAvailableVideoZoomFactor, CGFloat(wideZoomFactor)))
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
        } catch {
            showToast("Não foi possível configurar a lente")
            return false
        }

        guard attach(primary), let connection = primary.connection(with: .video) else {
            showToast("Saída de captura indisponível")
            return false
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = !back
        }
        if photos {
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let dims = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            }) {
                photoOutput.maxPhotoDimensions = dims
            }
        } else {
            if connection.isVideoStabilizationSupported {
                if !back {
                    // Front camera: avoid heavy digital crop from .cinematicExtended so talking-head framing matches preview
                    connection.preferredVideoStabilizationMode = format.isVideoStabilizationModeSupported(.standard)
                        ? .standard : .off
                } else {
                    connection.preferredVideoStabilizationMode = format.isVideoStabilizationModeSupported(.cinematic)
                        ? .cinematic : .auto
                }
            }
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
        if back, device.activeDepthDataFormat != nil, attach(depthDataOutput) {
            depthDataOutput.alwaysDiscardsLateDepthData = true
            // The center median ignores invalid pixels and doesn't need temporal filtering.
            depthDataOutput.isFilteringEnabled = false
        }

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoDataOutput.deliversPreviewSizedOutputBuffers = true
        _ = attach(videoDataOutput)

        let low = Double(device.minAvailableVideoZoomFactor) / wideZoomFactor
        let high = Double(device.maxAvailableVideoZoomFactor) / wideZoomFactor
        let lenses = [0.5, 1.0, 2.0, 5.0].filter { $0 >= low && $0 <= high }
        let lens = Double(device.videoZoomFactor) / wideZoomFactor
        sensorLock.lock()
        isFrontCameraFlag = (device.position == .front)
        sensorLock.unlock()
        DispatchQueue.main.async {
            self.hudDevice = device
            self.cameraPosition = device.position
            self.availableLenses = lenses.isEmpty ? [lens] : lenses
            self.activeLens = lens
            if switched {
                self.focusMarkA = nil
                self.focusMarkB = nil
                self.isAEAFLocked = false
            }
        }
        return true
    }

    private func attach(_ output: AVCaptureOutput) -> Bool {
        if captureSession.outputs.contains(where: { $0 === output }) { return true }
        guard captureSession.canAddOutput(output) else { return false }
        captureSession.addOutput(output)
        return true
    }

    private static func pickDepthFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        let float32 = formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        return (float32.isEmpty ? formats : float32).min {
            let lhs = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let rhs = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
        }
    }

    private func invalidateAnalysis() {
        sensorLock.lock()
        analysisGeneration &+= 1
        depthConnection = nil
        visionConnection = nil
        smoothedDistanceMeters = nil
        latestFaceRect = nil
        sensorLock.unlock()
    }

    private func updateAnalysisOutputs() {
        sensorLock.lock()
        let state = currentThermalState
        sensorLock.unlock()
        let active = runningRequested && isConfigured && !captureSession.isInterrupted
        let vision = videoDataOutput.connection(with: .video)
        let depth = depthDataOutput.connection(with: .depthData)
        let enableVision = active && state != .serious && state != .critical && vision != nil
        let enableDepth = active && state != .critical && depth != nil
        if enableVision && videoDataOutput.sampleBufferDelegate == nil {
            videoDataOutput.setSampleBufferDelegate(self, queue: visionQueue)
        } else if !enableVision && videoDataOutput.sampleBufferDelegate != nil {
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
        }
        if enableDepth && depthDataOutput.delegate == nil {
            depthDataOutput.setDelegate(self, callbackQueue: depthQueue)
        } else if !enableDepth && depthDataOutput.delegate != nil {
            depthDataOutput.setDelegate(nil, callbackQueue: nil)
        }
        vision?.isEnabled = enableVision
        depth?.isEnabled = enableDepth
        if enableDepth, let device = videoDevice {
            limitDepthFrameRate(on: device, fps: state == .nominal ? 15 : 5)
        }
        sensorLock.lock()
        analysisGeneration &+= 1
        depthConnection = enableDepth ? depth : nil
        visionConnection = enableVision ? vision : nil
        if !enableDepth { smoothedDistanceMeters = nil }
        if !enableVision { latestFaceRect = nil }
        sensorLock.unlock()
        DispatchQueue.main.async { self.hudStore.telemetry.hasLidarSupport = enableDepth }
    }

    private func limitDepthFrameRate(on device: AVCaptureDevice, fps: Int32) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard let format = device.activeDepthDataFormat,
                  let range = format.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) else { return }
            let requested = CMTime(value: 1, timescale: fps)
            let duration = min(range.maxFrameDuration, max(range.minFrameDuration, requested))
            if duration != device.activeDepthDataMinFrameDuration { device.activeDepthDataMinFrameDuration = duration }
        } catch {
            // The callback still throttles sampling if the device is busy.
        }
    }

    // MARK: - User Controls (Lenses, Pinch, Focus, Exposure, Quality, Flash, Timer)

    func setCaptureMode(_ mode: CaptureMode) {
        guard !captureBusy else { return }
        captureMode = mode
    }

    func toggleVideoQuality() {
        guard !captureBusy else { return }
        videoQuality = videoQuality.next
    }

    func cycleFlash() {
        flashOption = flashOption.next
    }

    func cycleTimer() {
        timerOption = timerOption.next
    }

    func setLens(_ multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0 else { return }
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
        guard state == .changed, scale.isFinite, scale > 0 else { return }
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
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
        cancelRackFocus()
        DispatchQueue.main.async {
            self.isAEAFLocked = false
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
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
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

    func lockFocusAndExposure(at devicePoint: CGPoint, screenPoint: CGPoint) {
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
        cancelRackFocus()
        DispatchQueue.main.async {
            self.isAEAFLocked = true
            self.focusIndicatorPoint = screenPoint
            self.impactFeedback.impactOccurred()
            self.showToast("AE/AF LOCK ativado — toca para destravar")
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func flipCamera() {
        guard !captureBusy else { return }
        markGeneration &+= 1
        cancelRackFocus()
        requestedPosition = requestedPosition == .back ? .front : .back
        requestConfiguration()
    }

    func setExposureBias(_ ev: Float) {
        guard ev.isFinite else { return }
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
        guard !captureBusy, !isExportingReel else { return }
        packGeneration = UUID()
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

    @MainActor
    func selectMusic(_ url: URL) async throws {
        guard !isExportingReel, !isImportingMusic else { return }
        isImportingMusic = true
        defer { isImportingMusic = false }
        let copy = try await Self.copyMusic(from: url)
        removeMusic()
        selectedMusicURL = copy
    }

    private static func copyMusic(from url: URL) async throws -> URL {
        let destination = try copyImportedFile(from: url, kind: "Music")
        do {
            let asset = AVURLAsset(url: destination)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  try await track.load(.timeRange).duration.seconds > 0 else {
                throw ReelExporter.ExportError.exportFailed("O ficheiro não contém áudio utilizável.")
            }
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    private static func copyImportedFile(from url: URL, kind: String) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("FramePilot-\(kind)-\(UUID().uuidString)",
                                                                      isDirectory: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
                do {
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    try files.copyItem(at: source, to: destination)
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return destination
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    @MainActor
    func removeMusic() {
        guard !isExportingReel, let selectedMusicURL else { return }
        self.selectedMusicURL = nil
        try? FileManager.default.removeItem(at: selectedMusicURL.deletingLastPathComponent())
    }

    @MainActor
    func selectLUT(_ url: URL) async throws {
        guard !isExportingReel, !isImportingLUT else { return }
        isImportingLUT = true
        defer { isImportingLUT = false }
        let copy = try await Self.copyLUT(from: url)
        removeLUT()
        selectedLUTURL = copy
    }

    private static func copyLUT(from url: URL) async throws -> URL {
        guard url.pathExtension.lowercased() == "cube" else { throw CubeLUTLoader.LoadError.invalidCube }
        let destination = try copyImportedFile(from: url, kind: "LUT")
        do {
            _ = try CubeLUTLoader.load(destination)
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    @MainActor
    func removeLUT() {
        guard !isExportingReel, let selectedLUTURL else { return }
        self.selectedLUTURL = nil
        try? FileManager.default.removeItem(at: selectedLUTURL.deletingLastPathComponent())
    }

    func prepareCaptionsForEditing() {
        guard !isPreparingCaptions else { return }
        let orderedURLs = selectedPack.shots
            .compactMap { sessionTakes[$0.id] }
            .filter { $0.isVideo }
            .compactMap { $0.fileURL }
        guard !orderedURLs.isEmpty else { return }

        let missing = orderedURLs.filter { editedTranscriptions[$0] == nil }
        guard !missing.isEmpty else { return }

        isPreparingCaptions = true
        Task {
            guard let recognizer = await CaptionService.localRecognizer() else {
                await MainActor.run {
                    self.isPreparingCaptions = false
                    self.showToast("Reconhecimento de voz indisponível")
                }
                return
            }
            var results: [URL: CaptionService.Transcription] = [:]
            for url in missing {
                if let t = await CaptionService.transcribeClip(url, recognizer: recognizer) {
                    results[url] = t
                }
            }
            await MainActor.run {
                for (url, transcription) in results {
                    self.editedTranscriptions[url] = transcription
                }
                self.isPreparingCaptions = false
            }
        }
    }

    func exportSessionReel(look: ReelLook = .original) {
        guard !isExportingReel, !isImportingMusic, !isImportingLUT, !captureBusy else { return }
        let orderedURLs = selectedPack.shots
            .compactMap { sessionTakes[$0.id] }
            .filter { $0.isVideo }
            .compactMap { $0.fileURL }

        guard !orderedURLs.isEmpty else {
            showToast("Grava pelo menos 1 plano em vídeo primeiro")
            return
        }

        let soundDesign = includeSoundDesign
        let captions = includeDynamicCaptions
        let music = selectedMusicURL
        let beatSync = beatSyncEnabled
        let ducking = autoDuckingEnabled
        let transition = selectedTransition
        let removeSilences = removeSilencesEnabled
        let lut = selectedLUTURL
        let precomputed = editedTranscriptions
        isExportingReel = true
        Task {
            do {
                try await ReelExporter.exportReel(
                    videoURLs: orderedURLs,
                    look: look,
                    includeSoundDesign: soundDesign,
                    includeViralCaptions: captions,
                    musicURL: music,
                    beatSyncEnabled: beatSync,
                    autoDuckingEnabled: ducking,
                    transition: transition,
                    removeSilences: removeSilences,
                    customLUTURL: lut,
                    precomputedTranscriptions: precomputed
                )
                await MainActor.run {
                    self.isExportingReel = false
                    self.notificationFeedback.notificationOccurred(.success)
                    let lookNote = look == .original ? "" : " • \(look.rawValue)"
                    let sfxNote = soundDesign && orderedURLs.count > 1 ? " + SFX" : ""
                    let capNote = captions ? " + Legendas" : ""
                    self.showToast("Reel montado (\(orderedURLs.count) planos\(lookNote)\(sfxNote)\(capNote))!")
                }
            } catch {
                await MainActor.run {
                    self.isExportingReel = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func setFocusMarkA() { setFocusMark("A") }
    func setFocusMarkB() { setFocusMark("B") }

    private func setFocusMark(_ label: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setFocusMark(label) }
            return
        }
        let generation = markGeneration
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice, self.captureSession.isRunning else { return }
            let position = device.lensPosition
            guard (0...1).contains(position) else { return }
            self.sensorLock.lock()
            let distance = self.smoothedDistanceMeters
            self.sensorLock.unlock()
            let mark = FocusMark(label: label, distanceMeters: distance, lensPosition: position)
            DispatchQueue.main.async {
                guard self.startID != nil, self.hudDevice === device, self.markGeneration == generation else { return }
                if label == "A" { self.focusMarkA = mark } else { self.focusMarkB = mark }
                self.impactFeedback.impactOccurred()
                self.showToast("Ponto \(label) marcado (\(mark.formattedDistance))")
            }
        }
    }

    private func cancelHardwareRack(restoreAutofocus: Bool = true) {
        guard let timer = rackFocusTimer else { return }
        timer.cancel()
        rackFocusTimer = nil
        if restoreAutofocus, let device = videoDevice, device.isFocusModeSupported(.continuousAutoFocus) {
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func cancelRackFocus() {
        rackID = nil
        isRackFocusing = false
        currentRackFocusProgress = nil
        currentRackFocusTarget = nil
        sessionQueue.async { [weak self] in self?.cancelHardwareRack() }
    }

    func clearFocusMarks() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clearFocusMarks() }
            return
        }
        markGeneration &+= 1
        focusMarkA = nil
        focusMarkB = nil
        cancelRackFocus()
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.isFocusModeSupported(.continuousAutoFocus) else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            } catch {}
        }
        showToast("Rack Focus reposto em Auto")
    }

    func triggerRackFocus(to target: String, duration: Double = 1.2) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.triggerRackFocus(to: target, duration: duration) }
            return
        }
        guard startID != nil, !isRackFocusing, duration.isFinite, duration > 0 else { return }
        guard let mark = (target == "A" ? focusMarkA : focusMarkB) else {
            showToast("Marca os pontos A e B primeiro")
            return
        }
        let id = UUID()
        let markedDevice = hudDevice
        rackID = id
        isRackFocusing = true
        currentRackFocusTarget = target
        impactFeedback.impactOccurred()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureSession.isRunning, let device = self.videoDevice, device === markedDevice,
                  device.isLockingFocusWithCustomLensPositionSupported, device.isFocusModeSupported(.locked),
                  (0...1).contains(mark.lensPosition), (0...1).contains(device.lensPosition) else {
                self.finishRack(id, message: "Controlo manual de foco indisponível nesta lente")
                return
            }
            let start = device.lensPosition
            let began = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - began) / duration)
                let progress = t * t * (3 - 2 * t)
                let position = min(1, max(0, start + Float(progress) * (mark.lensPosition - start)))
                do {
                    try device.lockForConfiguration()
                    guard device.isLockingFocusWithCustomLensPositionSupported, device.isFocusModeSupported(.locked) else {
                        device.unlockForConfiguration()
                        self.finishRack(id, message: "Controlo manual de foco indisponível nesta lente")
                        return
                    }
                    device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                    device.unlockForConfiguration()
                } catch {
                    self.finishRack(id, message: "Não foi possível ajustar o foco")
                    return
                }
                if t >= 1 {
                    self.finishRack(id, message: "Foco travado no Ponto \(target)", success: true)
                } else {
                    DispatchQueue.main.async {
                        if self.rackID == id { self.currentRackFocusProgress = progress }
                    }
                }
            }
            self.rackFocusTimer = timer
            timer.resume()
        }
    }

    private func finishRack(_ id: UUID, message: String, success: Bool = false) {
        cancelHardwareRack(restoreAutofocus: !success)
        DispatchQueue.main.async {
            guard self.rackID == id else { return }
            self.rackID = nil
            self.isRackFocusing = false
            self.currentRackFocusTarget = nil
            self.currentRackFocusProgress = nil
            if success { self.notificationFeedback.notificationOccurred(.success) }
            self.showToast(message)
        }
    }

    func toggleVirtualDolly() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.toggleVirtualDolly() }
            return
        }
        guard startID != nil else { return }
        isVirtualDollyActive.toggle()
        impactFeedback.impactOccurred()
        showToast(isVirtualDollyActive ? "Dolly Holográfico 3D Ativo" : "Dolly Desativado")
    }

    private func sessionClipURL() -> URL {
        try? FileManager.default.createDirectory(at: clipDirectory, withIntermediateDirectories: true)
        return clipDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    }

    private func clearSessionFiles() {
        try? FileManager.default.removeItem(at: clipDirectory)
    }

    func selectShot(at index: Int) {
        guard !captureBusy, selectedPack.shots.indices.contains(index) else { return }
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
        sensorLock.lock()
        let generation = motionGeneration
        sensorLock.unlock()
        motionManager.deviceMotionUpdateInterval = isThermalEcoActive ? 0.1 : 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let r = motion.rotationRate

            let xyMag = hypot(g.x, g.y)
            let rawPitchDeg = atan2(g.z, xyMag) * 180.0 / .pi
            let rawRollDeg = atan2(g.x, -g.y) * 180.0 / .pi
            let nearestRightAngle = (rawRollDeg / 90.0).rounded() * 90.0
            // Prevent gimbal-lock roll jitter when pointing steeply down (picado/overhead) or up (contrapicado)
            let rollStability = max(0.0, min(1.0, (xyMag - 0.30) / 0.35))
            let horizonErrorDeg = (rawRollDeg - nearestRightAngle) * rollStability
            let angularSpeedDeg = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180.0 / .pi

            self.sensorLock.lock()
            defer { self.sensorLock.unlock() }
            guard generation == self.motionGeneration else { return }
            let pitchDeg = self.isFrontCameraFlag ? -rawPitchDeg : rawPitchDeg
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
        }
    }

    // MARK: - Adaptive HUD Update Loop (20Hz nominal, 10Hz thermal eco)

    private func startHUDLoop() {
        hudTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(isThermalEcoActive ? 100 : 50), leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.publishHUDTick()
        }
        timer.resume()
        hudTimer = timer
    }

    private func publishHUDTick() {
        let orientation = currentVisionOrientation()
        sensorLock.lock()
        visionOrientation = orientation
        let pitch = smoothedPitchDegrees
        let roll = smoothedRollDegrees
        let motionSpeed = smoothedMotionSpeed
        let distance = smoothedDistanceMeters
        let faceRect = latestFaceRect
        let thermal = currentThermalState
        sensorLock.unlock()

        let motionPace = ShotCoachEngine.classifyMotionPace(speedDegPerSec: motionSpeed)
        let iso = Double(hudDevice?.iso ?? 200)
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
                isRecording: isRecording,
                target: currentTargetShot
            )
        }

        let advice = cachedAdvice
        let detected = cachedDetectedShot

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
        next.focusMarkA = self.focusMarkA
        next.focusMarkB = self.focusMarkB
        next.isRackFocusing = self.isRackFocusing
        next.rackFocusProgress = self.currentRackFocusProgress
        next.rackFocusTargetLabel = self.currentRackFocusTarget
        next.isDollyActive = self.isVirtualDollyActive
        if self.isVirtualDollyActive {
            if !isRecording {
                next.dollyProgress = 0
            } else if let targetSec = self.activeShot?.targetDurationSeconds, targetSec.isFinite, targetSec > 0 {
                next.dollyProgress = min(1.0, self.recordingElapsed / targetSec)
            } else {
                next.dollyProgress = 0.5
            }
            next.dollyAlignmentScore = (motionPace == .cinematic) ? 0.95 : (motionPace == .still ? 0.5 : 0.2)
        } else {
            next.dollyProgress = 0
            next.dollyAlignmentScore = 0
        }
        self.hudStore.telemetry = next

        if advice.isLocked && !self.wasLocked {
            self.impactFeedback.impactOccurred()
        }
        self.wasLocked = advice.isLocked
    }

    // MARK: - Shutter & Countdown

    func triggerShutter() {
        guard startID != nil else { return }
        if countdownRemaining > 0 {
            cancelCountdown()
            return
        }

        if isRecording {
            stopVideoRecording()
            return
        }

        guard !captureBusy else { return }
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

    private func beginCapture() -> Bool {
        guard startID != nil, !captureBusy, !isExportingReel else { return false }
        captureBusy = true
        captureContext = ShotContext(id: activeShot?.id ?? UUID().uuidString,
                                     title: activeShot?.title ?? "Plano Livre", generation: packGeneration)
        return true
    }

    private func captureFailed(_ message: String) {
        DispatchQueue.main.async {
            self.resetRecordingUI()
            self.recordingURL = nil
            self.captureContext = nil
            self.captureBusy = false
            self.showToast(message)
        }
    }

    private func capturePhotoNow() {
        guard beginCapture() else { return }
        shutterFlashVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.shutterFlashVisible = false }
        let flash = flashOption.avFlashMode
        let angle = currentVideoRotationAngle()
        sessionQueue.async {
            guard self.isConfigured, self.runningRequested, self.captureSession.isRunning, !self.captureSession.isInterrupted,
                  !self.photoInFlight, !self.movieInFlight, self.requestedMode == .photo,
                  let conn = self.photoOutput.connection(with: .video), conn.isActive, conn.isEnabled else {
                self.captureFailed("Câmara indisponível para fotografia")
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if self.photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            self.photoInFlight = true
            self.processedPhotoData = nil
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startVideoRecording() {
        guard beginCapture() else { return }
        let clipURL = sessionClipURL()
        recordingURL = clipURL
        recordingTarget = activeShot?.targetDurationSeconds
        autoStopRecording = autoStopEnabled
        didHitTargetDurationHaptic = false
        recordingSeconds = 0
        recordingElapsed = 0
        isRecording = true
        let angle = currentVideoRotationAngle()
        sessionQueue.async {
            guard self.isConfigured, self.runningRequested, self.captureSession.isRunning, !self.captureSession.isInterrupted,
                  !self.movieInFlight, !self.photoInFlight, self.requestedMode == .video,
                  let conn = self.movieOutput.connection(with: .video), conn.isActive, conn.isEnabled else {
                self.captureFailed("Câmara indisponível para gravação")
                return
            }
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            self.movieInFlight = true
            self.stopMovieRequested = false
            self.sensorLock.lock()
            self.isRecordingFlag = true
            self.sensorLock.unlock()
            self.movieOutput.startRecording(to: clipURL, recordingDelegate: self)
        }
    }

    private func resetRecordingUI() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func stopVideoRecording() {
        resetRecordingUI()
        sessionQueue.async { self.requestMovieStop() }
    }

    private func requestMovieStop() {
        guard movieInFlight else { return }
        stopMovieRequested = true
        if movieOutput.isRecording { movieOutput.stopRecording() }
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
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { self.processedPhotoData = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        sessionQueue.async {
            let data = self.processedPhotoData
            self.processedPhotoData = nil
            self.photoInFlight = false
            self.resumeSessionIfNeeded()
            guard error == nil, let data else {
                self.captureFailed("Erro ao capturar foto")
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let preview = Self.downscaledGhostImage(from: data)
                DispatchQueue.main.async {
                    self.storeTake(preview: preview, url: nil, duration: 0)
                    self.saveCapture {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    }
                }
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension SpatialCameraEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        sessionQueue.async {
            if self.stopMovieRequested { self.requestMovieStop() }
        }
        DispatchQueue.main.async {
            guard self.isRecording, self.recordingURL == fileURL else { return }
            self.impactFeedback.impactOccurred()
            let began = CACurrentMediaTime()
            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.recordingElapsed = CACurrentMediaTime() - began
                let seconds = Int(self.recordingElapsed)
                if seconds != self.recordingSeconds { self.recordingSeconds = seconds }
                if let target = self.recordingTarget, self.recordingElapsed >= target {
                    if !self.didHitTargetDurationHaptic {
                        self.didHitTargetDurationHaptic = true
                        self.impactFeedback.impactOccurred()
                    }
                    if self.autoStopRecording { self.stopVideoRecording() }
                }
            }
            self.recordingTimer?.tolerance = 0.015
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async {
            self.movieInFlight = false
            self.stopMovieRequested = false
            self.sensorLock.lock()
            self.isRecordingFlag = false
            self.sensorLock.unlock()
            self.resumeSessionIfNeeded()
        }
        DispatchQueue.main.async {
            self.resetRecordingUI()
            if let error = error as NSError?,
               (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.captureFailed("Erro na gravação de vídeo")
                return
            }
            let fallbackDuration = self.recordingElapsed
            Task {
                let asset = AVURLAsset(url: outputFileURL)
                let duration = (try? await asset.load(.duration))?.seconds ?? fallbackDuration
                let seconds = duration.isFinite ? max(0, duration) : fallbackDuration
                let preview = await Self.extractLastVideoFrame(asset: asset, seconds: seconds)
                await MainActor.run {
                    self.storeTake(preview: preview, url: outputFileURL, duration: seconds)
                    self.saveCapture {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
                    }
                }
            }
        }
    }

    private func storeTake(preview: UIImage?, url: URL?, duration: Double) {
        guard let shot = captureContext, shot.generation == packGeneration else { return }
        if let preview { ghostImage = preview }
        if let old = sessionTakes[shot.id]?.fileURL, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        sessionTakes[shot.id] = SessionTake(shotId: shot.id, shotTitle: shot.title, isVideo: url != nil,
                                            fileURL: url, thumbnail: preview, durationSeconds: duration)
    }

    private func saveCapture(_ changes: @escaping () -> Void) {
        let context = captureContext
        let video = recordingURL != nil
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.captureFailed("Permite acesso à galeria nas Definições")
                return
            }
            PHPhotoLibrary.shared().performChanges(changes) { success, _ in
                DispatchQueue.main.async {
                    self.captureBusy = false
                    self.captureContext = nil
                    self.recordingURL = nil
                    if success {
                        self.notificationFeedback.notificationOccurred(.success)
                        if context?.generation == self.packGeneration, context?.id == self.activeShot?.id {
                            self.markActiveShotCaptured()
                        }
                        self.showToast(video ? "Vídeo Pro guardado" : "Foto HD Pro guardada")
                    } else {
                        self.showToast(video ? "Erro ao guardar vídeo" : "Erro ao guardar foto")
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
        sensorLock.lock()
        let generation = analysisGeneration
        let enabled = depthConnection === connection
        let interval = currentThermalState == .nominal ? 1.0 / 15.0 : 0.2
        sensorLock.unlock()
        let now = CACurrentMediaTime()
        guard enabled, now - lastDepthTimestamp >= interval else { return }
        lastDepthTimestamp = now
        let type = kCVPixelFormatType_DepthFloat32
        let depthMap: CVPixelBuffer
        if depthData.depthDataType == type {
            depthMap = depthData.depthDataMap
        } else {
            guard depthData.availableDepthDataTypes.contains(type) else { return }
            depthMap = depthData.converting(toDepthDataType: type).depthDataMap
        }
        guard let rawDistance = Self.sampleCenterDepth(from: depthMap) else { return }

        sensorLock.lock()
        defer { sensorLock.unlock() }
        guard generation == analysisGeneration, depthConnection === connection else { return }
        if let prev = smoothedDistanceMeters {
            smoothedDistanceMeters = prev + 0.35 * (rawDistance - prev)
        } else {
            smoothedDistanceMeters = rawDistance
        }
    }

    private static func sampleCenterDepth(from depthMap: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return nil }
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
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func extractLastVideoFrame(asset: AVAsset, seconds: Double) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 1600)
        let time = CMTime(seconds: max(0, seconds - 0.08), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Thermal-aware Vision)

extension SpatialCameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sensorLock.lock()
        let thermal = currentThermalState
        let recording = isRecordingFlag
        let orientation = visionOrientation
        let enabled = visionConnection === connection
        let generation = analysisGeneration
        sensorLock.unlock()

        // Pause Vision completely if device gets seriously warm to protect battery
        guard enabled else { return }

        // Throttle Vision: 4Hz normal, 2Hz while recording, 1.5Hz if warm (.fair)
        let minInterval: TimeInterval
        if thermal == .fair {
            minInterval = 0.65
        } else if recording {
            minInterval = 0.50
        } else {
            minInterval = 0.25
        }

        let now = CACurrentMediaTime()
        guard now - lastVisionTimestamp >= minInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastVisionTimestamp = now

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([faceRequest])
            sensorLock.lock()
            defer { sensorLock.unlock() }
            guard generation == analysisGeneration, visionConnection === connection else { return }
            if let face = (faceRequest.results ?? []).max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            }) {
                let b = face.boundingBox
                let converted = CGRect(x: b.minX, y: 1.0 - b.maxY, width: b.width, height: b.height)
                latestFaceRect = converted
            } else {
                latestFaceRect = nil
            }
        } catch {}
    }
}
