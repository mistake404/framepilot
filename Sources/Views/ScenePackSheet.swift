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
    @State private var filter: PackFilter = .all

    private enum PackFilter: String, CaseIterable, Identifiable {
        case all = "Todos"
        case video = "Vídeo / Reels"
        case photo = "Fotografia"

        var id: String { rawValue }
    }

    private func isPhotoPack(_ pack: ScenePack) -> Bool {
        !pack.shots.isEmpty && pack.shots.allSatisfy { $0.preferredMode == .photo }
    }

    private func matchesFilter(_ pack: ScenePack) -> Bool {
        switch filter {
        case .all:
            return true
        case .video:
            return pack.shots.isEmpty || pack.shots.contains { $0.preferredMode == .video }
        case .photo:
            return isPhotoPack(pack)
        }
    }

    private func matchesSearch(_ pack: ScenePack) -> Bool {
        guard matchesFilter(pack) else { return false }
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

    private func packMetaLabel(for pack: ScenePack) -> String? {
        guard !pack.shots.isEmpty else { return nil }
        if isPhotoPack(pack) {
            return "\(pack.shots.count) fotos • 48MP"
        }
        let videoShots = pack.shots.filter { $0.preferredMode == .video }
        let total = videoShots.reduce(0.0) { $0 + $1.targetDurationSeconds }
        if total > 0 {
            return String(format: "%d planos • ~%.0fs", pack.shots.count, total)
        }
        return "\(pack.shots.count) planos"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Tipo de guião", selection: $filter) {
                        ForEach(PackFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

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

                        if let meta = packMetaLabel(for: pack) {
                            Text(meta)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(isPhotoPack(pack) ? .cyan : .secondary)
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
