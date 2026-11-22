import SwiftUI
import AVKit

struct StoryboardSheet: View {
    @ObservedObject var engine: SpatialCameraEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedLook: ReelLook = .film35mm
    @State private var previewVideoURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if engine.selectedPack.shots.isEmpty {
                    ContentUnavailableView(
                        "Modo livre",
                        systemImage: "film.stack",
                        description: Text("Escolhe um guião com planos para montar automaticamente o teu Reel.")
                    )
                } else {
                    List {
                        plansSection
                        exportOptions
                    }
                    .listStyle(.insetGrouped)
                    .safeAreaInset(edge: .bottom, spacing: 0) { exportBar }
                }
            }
            .navigationTitle("Storyboard da sessão")
            .navigationBarTitleDisplayMode(.inline)
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
                    } else {
                        thumbnail.accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(shot.title)")
                            .font(.headline)
                        Text("\(shot.kind.rawValue) · \(shot.lensLabel) · Alvo \(shot.durationLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let take {
                            let duration = take.durationSeconds.formatted(.number.locale(Locale(identifier: "pt_PT")).precision(.fractionLength(1)))
                            Label(take.isVideo ? "Vídeo · \(duration) s" : "Fotografia captada",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.primary)
                                .font(.caption.weight(.medium))
                        } else {
                            Label("Por gravar", systemImage: "circle.dashed")
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
            Picker(selection: $selectedLook) {
                ForEach(ReelLook.allCases) { look in
                    Text(look.rawValue).tag(look)
                }
            } label: {
                Label("Paleta de cinema", systemImage: "camera.filters")
            }
            .pickerStyle(.menu)

            Toggle(isOn: $engine.includeSoundDesign) {
                Label("Som nas transições", systemImage: "waveform")
            }
            Toggle(isOn: $engine.includeDynamicCaptions) {
                Label("Legendas dinâmicas", systemImage: "captions.bubble")
            }
        }
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
            .disabled(count == 0 || isExporting)

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
