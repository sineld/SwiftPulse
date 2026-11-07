import SwiftUI

struct EmptyStateView: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 20)
            Text(message).font(.headline)
            Button(buttonTitle, action: action)
                .controlSize(.large)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.title3.weight(.semibold))
            .padding(.leading, 6)
    }
}

/// White rounded row card used across resource lists (icon + title + subtitle + trailing).
struct ResourceCard<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var badges: [String] = []
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Spacer()
            trailing
        }
        .padding(14)
        .card()
        .contentShape(Rectangle())
    }
}

extension ResourceCard where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, badges: [String] = []) {
        self.init(icon: icon, title: title, subtitle: subtitle, badges: badges) { EmptyView() }
    }
}

/// Page scaffold: scrollable, padded, titled via navigationTitle.
struct Page<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}
