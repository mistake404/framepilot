import SwiftUI

struct ScenePackSheet: View {
    let packs: [ScenePack]
    let selectedPack: ScenePack
    let onSelect: (ScenePack) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(packs) { pack in
                    Button {
                        onSelect(pack)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: pack.iconName)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.yellow)
                                .frame(width: 36, height: 36)
                                .background(Color.yellow.opacity(0.15))
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
            .navigationTitle("Guiões de Cena")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}
