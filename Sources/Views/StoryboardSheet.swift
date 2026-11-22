import SwiftUI
import AVKit

struct StoryboardSheet: View {
    @ObservedObject var engine: SpatialCameraEngine
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLook: ReelLook = .film35mm
    @State private var previewVideoURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if engine.selectedPack.shots.isEmpty {
                    ContentUnavailableView(
                        "Modo Livre",
                        systemImage: "film.stack",
                        description: Text("Escolhe um guião com planos para montar automaticamente o teu Reel.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(Array(engine.selectedPack.shots.enumerated()), id: \.element.id) { index, shot in
                                let take = engine.sessionTakes[shot.id]
                                HStack(spacing: 12) {
                                    // Thumbnail (tap to play if video)
                                    Button {
                                        if let url = take?.fileURL, take?.isVideo == true {
                                            previewVideoURL = url
                                        }
                                    } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.white.opacity(0.08))
                                                .frame(width: 52, height: 68)

                                            if let thumb = take?.thumbnail {
                                                Image(uiImage: thumb)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 52, height: 68)
                                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            } else {
                                                Image(systemName: shot.kind.iconName)
                                                    .font(.system(size: 18))
                                                    .foregroundColor(.secondary)
                                            }

                                            if take?.isVideo == true && take?.fileURL != nil {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundColor(.white)
                                                    .shadow(radius: 4)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text("\(index + 1). \(shot.title)")
                                                .font(.headline)

                                            if take != nil {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                            }
                                        }

                                        Text("\(shot.kind.rawValue) • \(shot.lensLabel) • Alvo \(shot.durationLabel)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        if let take {
                                            Text(take.isVideo ? String(format: "Gravado (%.1fs) • Toca p/ ver", take.durationSeconds) : "Foto capturada")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundColor(.green)
                                        } else {
                                            Text("Por gravar")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                    }

                                    Spacer()

                                    Button(take == nil ? "Gravar" : "Repetir") {
                                        engine.selectShot(at: index)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(take == nil ? .yellow : .cyan)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 3)
                            }
                        } header: {
                            Text(engine.selectedPack.name)
                        }
                    }

                    // Cinematic Look Picker + Sound Design Toggle + 1-Click Auto-Edit Reel Export Footer
                    VStack(spacing: 12) {
                        HStack {
                            Text("Paleta de Cinema:")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ReelLook.allCases) { look in
                                    Button {
                                        selectedLook = look
                                    } label: {
                                        Text(look.rawValue)
                                            .font(.caption.bold())
                                            .foregroundColor(selectedLook == look ? .black : .primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule().fill(selectedLook == look ? Color.yellow : Color.white.opacity(0.12))
                                            )
                                    }
                                }
                            }
                        }

                        Toggle(isOn: $engine.includeSoundDesign) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.badge.plus")
                                    .foregroundColor(.cyan)
                                Text("Sound Design (Whooshes nas transições)")
                                    .font(.caption.bold())
                            }
                        }
                        .tint(.cyan)

                        Button {
                            engine.exportSessionReel(look: selectedLook)
                        } label: {
                            HStack(spacing: 8) {
                                if engine.isExportingReel {
                                    ProgressView()
                                        .tint(.black)
                                    Text("A montar Reel (\(selectedLook.rawValue))...")
                                } else {
                                    Image(systemName: "wand.and.stars")
                                    Text("Exportar Reel (\(engine.recordedVideoCount) planos)")
                                }
                            }
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(engine.recordedVideoCount > 0 ? Color.yellow : Color.gray.opacity(0.4))
                            )
                        }
                        .disabled(engine.recordedVideoCount == 0 || engine.isExportingReel)

                        Text("Monta os clips por ordem com cor uniforme e guarda na galeria.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemBackground))
                }
            }
            .navigationTitle("Storyboard da Sessão")
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
