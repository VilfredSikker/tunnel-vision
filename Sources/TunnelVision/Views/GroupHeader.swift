import SwiftUI

/// The header of a folding task group ("Done · 3 ▸ show all"): the focus list's
/// Done and Not done groups and the Background section's Done group share it.
struct GroupHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool
    let expandable: Bool

    var body: some View {
        Button {
            guard expandable else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(title) · \(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if expandable {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !expanded {
                        Text("show all")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expandable ? (expanded ? "Show only the latest" : "Show all \(count)") : "")
    }
}
