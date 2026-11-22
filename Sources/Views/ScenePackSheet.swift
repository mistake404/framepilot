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

    var body: some View {
        NavigationStack {
            List {
                if !customPacks.isEmpty {
                    Section("Os Teus Guiões") {
                        ForEach(customPacks) { pack in
                            packRow(pack)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                onDeleteCustom(customPacks[index].id)
                            }
                        }
                    }
                }

                Section("Guiões Prontos") {
                    ForEach(presetPacks) { pack in
                        packRow(pack)
                    }
                }
            }
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
                            Text("\(pack.shots.count) planos")
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
