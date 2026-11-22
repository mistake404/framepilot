import SwiftUI

struct ScenePackSheet: View {
    let customPacks: [ScenePack]
    let presetPacks: [ScenePack]
    let selectedPack: ScenePack
    let onSelect: (ScenePack) -> Void
    let onCreateCustom: (ScenePack) -> Void
    let onDeleteCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showBuilder = false
    @State private var searchText = ""

    private func matchesSearch(_ pack: ScenePack) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        if pack.name.lowercased().contains(query) || pack.subtitle.lowercased().contains(query) {
            return true
        }
        return pack.shots.contains { $0.title.lowercased().contains(query) }
    }

    private var filteredCustomPacks: [ScenePack] {
        customPacks.filter(matchesSearch)
    }

    private var filteredPresetPacks: [ScenePack] {
        presetPacks.filter(matchesSearch)
    }

    private func totalDurationLabel(for pack: ScenePack) -> String? {
        let videoShots = pack.shots.filter { $0.preferredMode == .video }
        guard !videoShots.isEmpty else { return nil }
        let total = videoShots.reduce(0.0) { $0 + $1.targetDurationSeconds }
        return String(format: "~%.0fs", total)
    }

    var body: some View {
        NavigationStack {
            List {
                if !filteredCustomPacks.isEmpty {
                    Section("Os Teus Guiões") {
                        ForEach(filteredCustomPacks) { pack in
                            packRow(pack)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                onDeleteCustom(filteredCustomPacks[index].id)
                            }
                        }
                    }
                }

                Section("Guiões Prontos") {
                    ForEach(filteredPresetPacks) { pack in
                        packRow(pack)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Pesquisar guião, nicho ou plano…")
            .navigationTitle("Guiões de Cena")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showBuilder = true
                    } label: {
                        Label("Novo", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .sheet(isPresented: $showBuilder) {
                CustomPackBuilderSheet { newPack in
                    onCreateCustom(newPack)
                    dismiss()
                }
            }
        }
    }

    private func packRow(_ pack: ScenePack) -> some View {
        Button {
            onSelect(pack)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: pack.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(pack.isCustom ? .cyan : .yellow)
                    .frame(width: 36, height: 36)
                    .background((pack.isCustom ? Color.cyan : Color.yellow).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(pack.name)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        if !pack.shots.isEmpty {
                            let dur = totalDurationLabel(for: pack).map { " • \($0)" } ?? ""
                            Text("\(pack.shots.count) planos\(dur)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(pack.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if pack.id == selectedPack.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
