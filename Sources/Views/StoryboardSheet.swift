import SwiftUI

struct StoryboardSheet: View {
    @ObservedObject var engine: SpatialCameraEngine
    @Environment(\.dismiss) private var dismiss

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
                                    // Thumbnail or placeholder
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
                                    }

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
                                            Text(take.isVideo ? String(format: "Gravado (%.1fs)", take.durationSeconds) : "Foto capturada")
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

                    // 1-Click Auto-Edit Reel Export Footer
                    VStack(spacing: 8) {
                        Button {
                            engine.exportSessionReel()
                        } label: {
                            HStack(spacing: 8) {
                                if engine.isExportingReel {
                                    ProgressView()
                                        .tint(.black)
                                    Text("A montar Reel...")
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

                        Text("Junta os clips gravados pela ordem do guião e guarda o Reel pronto na galeria.")
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
        }
    }
}
