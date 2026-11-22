import SwiftUI

struct TeleprompterOverlayView: View {
    let scriptText: String
    let isScrolling: Bool
    let speedPointsPerSecond: Double
    let onEditTap: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label("TELEPROMPTER", systemImage: "text.alignleft")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)

                Spacer()

                Button("Editar") {
                    onEditTap()
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.cyan)
            }

            GeometryReader { geo in
                Text(scriptText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .frame(width: geo.size.width, alignment: .top)
                    .offset(y: -scrollOffset)
            }
            .frame(height: 82)
            .clipped()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                )
        )
        .onChange(of: isScrolling) { _, active in
            if active {
                startScrolling()
            } else {
                stopScrolling(reset: true)
            }
        }
        .onDisappear {
            stopScrolling(reset: true)
        }
    }

    private func startScrolling() {
        stopScrolling(reset: true)
        let step = CGFloat(speedPointsPerSecond / 20.0)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            scrollOffset += step
        }
    }

    private func stopScrolling(reset: Bool) {
        timer?.invalidate()
        timer = nil
        if reset {
            scrollOffset = 0
        }
    }
}

struct TeleprompterEditorSheet: View {
    @Binding var scriptText: String
    @Binding var speedPointsPerSecond: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Texto do Hook / Guião") {
                    TextEditor(text: $scriptText)
                        .frame(minHeight: 160)
                        .font(.body)
                }

                Section("Velocidade de Leitura") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Velocidade")
                            Spacer()
                            Text("\(Int(speedPointsPerSecond)) pt/s")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $speedPointsPerSecond, in: 14...60, step: 2)
                            .tint(.yellow)
                    }
                }

                Section {
                    Text("O texto desliza automaticamente assim que carregas em Gravar e fica posicionado junto à lente frontal para manteres o contacto visual.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Teleprompter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluir") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
    }
}
