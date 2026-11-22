import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct StoryboardSheet: View {
    @ObservedObject var engine: SpatialCameraEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedLook: ReelLook = .film35mm
    @State private var previewVideoURL: URL?
    @State private var previewPhotoImage: UIImage?
    @State private var importKind: ImportKind = .music
    @State private var showFilePicker = false
    @State private var showImportError = false
    @State private var showCaptionEditor = false

    private enum ImportKind {
        case music, lut

        var contentTypes: [UTType] {
            switch self {
            case .music: return [.audio]
            case .lut: return [UTType(filenameExtension: "cube"), UTType.plainText, UTType.data].compactMap { $0 }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.selectedPack.shots.isEmpty && engine.orderedSessionTakes.isEmpty {
                    ContentUnavailableView(
                        "Modo livre",
                        systemImage: "film.stack",
                        description: Text("Grava 1 ou mais vídeos em Modo Livre para montar, editar legendas e exportar o teu Reel.")
                    )
                } else {
                    List {
                        if engine.selectedPack.shots.isEmpty {
                            freeModeTakesSection
                        } else {
                            plansSection
                        }
                        exportOptions
                        musicSection
                    }
                    .listStyle(.insetGrouped)
                    .safeAreaInset(edge: .bottom, spacing: 0) { exportBar }
                }
            }
            .navigationTitle("Storyboard da sessão")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: importKind.contentTypes) { result in
                let kind = importKind
                Task { @MainActor in
                    do {
                        let url = try result.get()
                        switch kind {
                        case .music: try await engine.selectMusic(url)
                        case .lut: try await engine.selectLUT(url)
                        }
                    } catch let error as CocoaError where error.code == .userCancelled {
                        return
                    } catch {
                        showImportError = true
                    }
                }
            }
            .alert(importKind == .music ? "Não foi possível importar a música" : "Não foi possível importar a LUT",
                   isPresented: $showImportError) {
                Button("Fechar", role: .cancel) {}
            } message: {
                if importKind == .music {
                    Text("Verifica se o ficheiro está disponível e contém uma faixa de áudio que o iPhone consiga ler.")
                } else {
                    Text("Escolhe um ficheiro .cube com uma LUT 3D válida.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(
                get: { previewVideoURL != nil },
                set: { if !$0 { previewVideoURL = nil } }
            )) {
                if let url = previewVideoURL {
                    ClipPreviewSheet(url: url)
                }
            }
            .sheet(isPresented: $showCaptionEditor) {
                CaptionEditorSheet(engine: engine)
            }
            .sheet(isPresented: Binding(
                get: { previewPhotoImage != nil },
                set: { if !$0 { previewPhotoImage = nil } }
            )) {
                if let image = previewPhotoImage {
                    PhotoPreviewSheet(image: image)
                }
            }
        }
    }

    private var freeModeTakesSection: some View {
        Section {
            ForEach(Array(engine.orderedSessionTakes.enumerated()), id: \.element.shotId) { index, take in
                let thumbnail = ShotThumbnail(image: take.thumbnail, symbol: take.isVideo ? "video.fill" : "camera.fill")
                HStack(spacing: 12) {
                    if let url = take.fileURL, take.isVideo {
                        Button {
                            previewVideoURL = url
                        } label: {
                            thumbnail.overlay {
                                Image(systemName: "play.fill")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.72), in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reproduzir take \(index + 1), \(take.shotTitle)")
                    } else if let thumb = take.thumbnail, !take.isVideo {
                        Button {
                            previewPhotoImage = thumb
                        } label: {
                            thumbnail
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ver fotografia do take \(index + 1)")
                    } else {
                        thumbnail.accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(take.shotTitle)")
                            .font(.headline)
                        let duration = take.durationSeconds.formatted(.number.locale(Locale(identifier: "pt_PT")).precision(.fractionLength(1)))
                        Label(take.isVideo ? "Vídeo · \(duration) s" : "Fotografia captada",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(role: .destructive) {
                        engine.removeFreeModeTake(id: take.shotId)
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(engine.isExportingReel)
                    .accessibilityLabel("Remover take \(index + 1)")
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Modo Livre")
        }
    }

    private var plansSection: some View {
        Section {
            ForEach(Array(engine.selectedPack.shots.enumerated()), id: \.element.id) { index, shot in
                let take = engine.sessionTakes[shot.id]
                let thumbnail = ShotThumbnail(image: take?.thumbnail, symbol: shot.kind.iconName)
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                layout {
                    if let url = take?.fileURL, take?.isVideo == true {
                        Button {
                            previewVideoURL = url
                        } label: {
                            thumbnail.overlay {
                                Image(systemName: "play.fill")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.72), in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reproduzir plano \(index + 1), \(shot.title)")
                    } else if let thumb = take?.thumbnail, take?.isVideo == false {
                        Button {
                            previewPhotoImage = thumb
                        } label: {
                            thumbnail.overlay(alignment: .bottomTrailing) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.black.opacity(0.65), in: Circle())
                                    .padding(3)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ver fotografia do plano \(index + 1), \(shot.title)")
                    } else {
                        thumbnail.accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(shot.title)")
                            .font(.headline)
                        let modeMeta = shot.preferredMode == .photo ? "Foto 48MP" : "Alvo \(shot.durationLabel)"
                        Text("\(shot.kind.rawValue) · \(shot.lensLabel) · \(modeMeta)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let take {
                            let duration = take.durationSeconds.formatted(.number.locale(Locale(identifier: "pt_PT")).precision(.fractionLength(1)))
                            Label(take.isVideo ? "Vídeo · \(duration) s" : "Fotografia captada",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.primary)
                                .font(.caption.weight(.medium))
                        } else {
                            Label(shot.preferredMode == .photo ? "Por fotografar" : "Por gravar", systemImage: "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    Button {
                        engine.selectShot(at: index)
                        dismiss()
                    } label: {
                        Text(take == nil ? "Gravar" : "Repetir")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 8)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(take == nil ? "Gravar" : "Repetir") plano \(index + 1)")
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(engine.selectedPack.name)
        }
    }

    private var exportOptions: some View {
        Section("Montagem") {
            Toggle("Preservar 4K na montagem", isOn: $engine.preserve4KInReel)
                .disabled(engine.isExportingReel)
            Picker(selection: $selectedLook) {
                ForEach(ReelLook.allCases) { look in
                    Text(look.rawValue).tag(look)
                }
            } label: {
                Label("Paleta de cinema", systemImage: "camera.filters")
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                Label("Transição", systemImage: "film")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(ReelTransition.allCases) { transition in
                            let selected = engine.selectedTransition == transition
                            Button {
                                engine.selectedTransition = transition
                            } label: {
                                Text(transition.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(selected ? Color.black : Color.primary)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .background(selected ? Color.yellow : Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Toggle(isOn: $engine.removeSilencesEnabled) {
                Label("Smart Jump-Cut (Cortar Silêncios)", systemImage: "scissors")
            }
            Toggle(isOn: $engine.includeSoundDesign) {
                Label("Som nas transições", systemImage: "waveform")
            }
            Toggle(isOn: $engine.includeDynamicCaptions) {
                Label("Legendas dinâmicas", systemImage: "captions.bubble")
            }
            if engine.includeDynamicCaptions && engine.recordedVideoCount > 0 {
                Button {
                    showCaptionEditor = true
                } label: {
                    HStack {
                        Label("Rever / Corrigir Legendas", systemImage: "pencil.line")
                        Spacer()
                        if engine.isPreparingCaptions {
                            ProgressView()
                        } else if engine.editedTranscriptions.count == engine.recordedVideoCount {
                            Text("Pronto")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button { openFilePicker(.lut) } label: {
                    Label(engine.selectedLUTURL?.lastPathComponent ?? "Importar LUT (.cube)", systemImage: "slider.horizontal.3")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Abre o seletor de ficheiros LUT.")
                Spacer()
                if engine.isImportingLUT {
                    ProgressView().accessibilityLabel("A importar LUT")
                } else if engine.selectedLUTURL != nil {
                    Button(role: .destructive) { engine.removeLUT() } label: {
                        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remover LUT")
                }
            }
            .disabled(engine.isImportingLUT || engine.isImportingMusic)
        }
        .disabled(engine.isExportingReel)
    }

    private var musicSection: some View {
        Section("Música & Ritmo") {
            HStack {
                Button { openFilePicker(.music) } label: {
                    Label(engine.selectedMusicURL?.lastPathComponent ?? "Escolher música", systemImage: "music.note")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Abre o seletor de ficheiros de áudio.")
                Spacer()
                if engine.isImportingMusic {
                    ProgressView().accessibilityLabel("A importar música")
                } else if engine.selectedMusicURL != nil {
                    Button(role: .destructive) { engine.removeMusic() } label: {
                        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remover música")
                }
            }
            Toggle("Corte na Batida (Beat-Sync)", isOn: $engine.beatSyncEnabled)
                .disabled(engine.selectedMusicURL == nil)
            Toggle("Auto-Ducking na Voz", isOn: $engine.autoDuckingEnabled)
                .disabled(engine.selectedMusicURL == nil)
        }
        .disabled(engine.isExportingReel || engine.isImportingMusic || engine.isImportingLUT)
    }

    private func openFilePicker(_ kind: ImportKind) {
        importKind = kind
        showFilePicker = true
    }

    private var exportBar: some View {
        let count = engine.recordedVideoCount
        let isExporting = engine.isExportingReel
        return VStack(spacing: 8) {
            Button {
                engine.exportSessionReel(look: selectedLook)
            } label: {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView().tint(.black)
                        Text("A montar o Reel…")
                    } else {
                        Image(systemName: "film.stack")
                        Text("Exportar Reel")
                        if count > 0 {
                            Text(verbatim: count == 1 ? "· 1 plano" : "· \(count) planos")
                                .monospacedDigit()
                        }
                    }
                }
                .font(.headline)
                .foregroundStyle(count > 0 || isExporting ? Color.black : Color.secondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(count > 0 || isExporting ? Color.yellow : Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(count == 0 || isExporting || engine.isImportingMusic || engine.isImportingLUT)

            Text(count == 0 ? "Grava pelo menos um plano em vídeo para exportar." : "Os vídeos são montados pela ordem do guião e guardados num Reel em Fotografias.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ShotThumbnail: View {
    let image: UIImage?
    let symbol: String

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ClipPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Pré-visualização")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }
}

private struct CaptionEditorSheet: View {
    @ObservedObject var engine: SpatialCameraEngine
    @Environment(\.dismiss) private var dismiss

    private var videoTakes: [(shotTitle: String, url: URL)] {
        engine.orderedVideoTakes.compactMap { take in
            guard let url = take.fileURL else { return nil }
            return (take.shotTitle, url)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.isPreparingCaptions {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("A transcrever os planos no iPhone…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if videoTakes.isEmpty {
                    ContentUnavailableView(
                        "Sem planos de vídeo",
                        systemImage: "captions.bubble",
                        description: Text("Grava primeiro um plano em vídeo para rever as legendas.")
                    )
                } else {
                    List {
                        Section {
                            Text("Toca em qualquer palavra para corrigir a ortografia. Para apagar uma palavra mal ouvida, limpa o texto.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(videoTakes, id: \.url) { item in
                            Section(item.shotTitle) {
                                if let transcription = engine.editedTranscriptions[item.url],
                                   !transcription.words.isEmpty {
                                    ForEach(transcription.words.indices, id: \.self) { wordIndex in
                                        let word = transcription.words[wordIndex]
                                        HStack(spacing: 10) {
                                            Text(String(format: "%.1fs", word.start + transcription.sourceOrigin))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 40, alignment: .leading)

                                            TextField(
                                                "Palavra",
                                                text: Binding(
                                                    get: {
                                                        guard let list = engine.editedTranscriptions[item.url]?.words,
                                                              wordIndex < list.count else { return "" }
                                                        return list[wordIndex].text
                                                    },
                                                    set: { newValue in
                                                        guard var t = engine.editedTranscriptions[item.url],
                                                              wordIndex < t.words.count else { return }
                                                        t.words[wordIndex].text = newValue
                                                        engine.editedTranscriptions[item.url] = t
                                                    }
                                                )
                                            )
                                            .textInputAutocapitalization(.characters)
                                            .autocorrectionDisabled(false)

                                            if !word.text.isEmpty {
                                                Button {
                                                    guard var t = engine.editedTranscriptions[item.url],
                                                          wordIndex < t.words.count else { return }
                                                    t.words[wordIndex].text = ""
                                                    engine.editedTranscriptions[item.url] = t
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.borderless)
                                                .accessibilityLabel("Apagar palavra")
                                            }
                                        }
                                    }
                                } else {
                                    Text(engine.editedTranscriptions[item.url] == nil
                                         ? "Transcrição indisponível para este plano."
                                         : "Sem fala detetada neste plano.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Corrigir Legendas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluir") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                engine.prepareCaptionsForEditing()
            }
        }
    }
}

private struct PhotoPreviewSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Fotografia Captada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}
