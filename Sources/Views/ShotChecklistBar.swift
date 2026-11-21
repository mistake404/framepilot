import SwiftUI

struct ShotChecklistBar: View {
    let shots: [ShotTemplate]
    let activeIndex: Int
    let completedIds: Set<String>
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                        let isActive = index == activeIndex
                        let isDone = completedIds.contains(shot.id)

                        Button {
                            onSelect(index)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isDone ? "checkmark.circle.fill" : shot.kind.iconName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(isDone ? .green : (isActive ? .black : .white))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(index + 1). \(shot.title)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(isActive ? .black : .white)

                                    Text(shot.kind.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(isActive ? .black.opacity(0.75) : .white.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isActive ? Color.white : Color.black.opacity(0.55))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(isDone ? Color.green.opacity(0.8) : Color.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                        }
                        .id(shot.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: activeIndex) { _, newIndex in
                if shots.indices.contains(newIndex) {
                    withAnimation {
                        proxy.scrollTo(shots[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }
}
