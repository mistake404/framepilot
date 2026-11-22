import SwiftUI

struct CustomPackBuilderSheet: View {
    let onSave: (ScenePack) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var packName: String = ""
    @State private var draftShots: [DraftShot] = [
        DraftShot(title: "Abertura", kind: .establishing, lens: 0.5, mode: .video, duration: 2.5),
        DraftShot(title: "Ação Principal", kind: .medium, lens: 1.0, mode: .video, duration: 3.0),
        DraftShot(title: "Detalhe", kind: .detail, lens: 2.0, mode: .video, duration: 2.0)
    ]

    struct DraftShot: Identifiable {
        let id = UUID()
        var title: String
        var kind: ShotKind
        var lens: Double
        var mode: CaptureMode
        var duration: Double
    }

    private let lensChoices: [Double] = [0.5, 1.0, 2.0, 5.0]
    private let durationChoices: [Double] = [1.5, 2.0, 2.5, 3.0, 4.0, 5.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome do Guião") {
                    TextField("Ex.: Reel Ginásio, Café, Review...", text: $packName)
                }

                Section {
                    ForEach($draftShots) { $shot in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Nome do plano", text: $shot.title)
                                .font(.headline)

                            HStack {
                                Picker("Tipo", selection: $shot.kind) {
                                    ForEach(ShotKind.allCases) { kind in
                                        Text(kind.rawValue).tag(kind)
                                    }
                                }
                                .labelsHidden()

                                Spacer()

                                Picker("Modo", selection: $shot.mode) {
                                    ForEach(CaptureMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 118)
                            }

                            HStack {
                                Text("Lente:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                ForEach(lensChoices, id: \.self) { lens in
                                    let label = lens == 0.5 ? "0.5x" : "\(Int(lens))x"
                                    Button(label) {
                                        shot.lens = lens
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(shot.lens == lens ? .yellow : .gray)
                                    .controlSize(.mini)
                                }

                                Spacer()

                                Picker("Duração", selection: $shot.duration) {
                                    ForEach(durationChoices, id: \.self) { sec in
                                        Text(sec.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(sec))s" : String(format: "%.1fs", sec))
                                            .tag(sec)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indices in
                        draftShots.remove(atOffsets: indices)
                    }

                    Button {
                        draftShots.append(
                            DraftShot(
                                title: "Plano \(draftShots.count + 1)",
                                kind: .lowAngle,
                                lens: 1.0,
                                mode: .video,
                                duration: 2.5
                            )
                        )
                    } label: {
                        Label("Adicionar Plano", systemImage: "plus.circle.fill")
                            .foregroundColor(.yellow)
                    }
                } header: {
                    Text("Planos (\(draftShots.count))")
                }
            }
            .navigationTitle("Novo Guião")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        savePack()
                    }
                    .fontWeight(.bold)
                    .disabled(packName.trimmingCharacters(in: .whitespaces).isEmpty || draftShots.isEmpty)
                }
            }
        }
    }

    private func savePack() {
        let trimmed = packName.trimmingCharacters(in: .whitespaces)
        let packId = "custom-\(UUID().uuidString)"
        let templates = draftShots.enumerated().map { idx, item in
            ShotTemplate(
                id: "\(packId)-s\(idx)",
                title: item.title.isEmpty ? "Plano \(idx + 1)" : item.title,
                kind: item.kind,
                preferredMode: item.mode,
                recommendedLens: item.lens,
                targetDurationSeconds: item.duration,
                targetDistanceRange: item.kind.defaultDistanceRange,
                targetPitchRange: item.kind.defaultPitchRange,
                maxRollDegrees: 3.0,
                movementHint: item.kind.defaultMovementHint,
                directorTip: "Guião personalizado • \(item.kind.defaultMovementHint)"
            )
        }

        let pack = ScenePack(
            id: packId,
            name: trimmed,
            subtitle: "\(templates.count) planos personalizados",
            iconName: "sparkles",
            shots: templates,
            isCustom: true
        )
        onSave(pack)
        dismiss()
    }
}
