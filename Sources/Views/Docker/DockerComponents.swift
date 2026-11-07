import SwiftUI

enum DockerTab: String, CaseIterable, Identifiable {
    case overview, containers, compose, images, volumes, networks, events
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .compose: "Compose"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .events: "Events"
        }
    }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .containers: "shippingbox"
        case .compose: "square.stack.3d.up"
        case .images: "opticaldiscdrive"
        case .volumes: "externaldrive"
        case .networks: "globe"
        case .events: "clock.arrow.circlepath"
        }
    }
}

/// Capsule pill row that switches Docker sections.
struct DockerTabBar: View {
    @Binding var selection: DockerTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DockerTab.allCases) { tab in
                    pill(tab)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 10)
        }
        .background(.background)
    }

    private func pill(_ tab: DockerTab) -> some View {
        let active = tab == selection
        return Button { selection = tab } label: {
            Label(tab.title, systemImage: tab.icon)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.35) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// Rounded section container used by every Docker card.
struct DockerCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var tint: Color = .accentColor
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Label(title, systemImage: icon ?? "circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Small stat box: icon + caption over a big value and a sub-line.
struct DockerStatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedLabelStyle(tint: tint))
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TintedLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Proportional stacked bar (container states, disk usage).
struct DockerSegmentBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let color: Color
        let value: Double
    }
    let segments: [Segment]
    var height: CGFloat = 8

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(segments.filter { $0.value > 0 }) { segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: max(geometry.size.width * segment.value / total - 2, 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

/// Dot + label over a value, used under the segmented bars.
struct DockerLegend: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Name + value row with a proportional bar underneath (top consumers).
struct DockerConsumerRow: View {
    let name: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.caption).lineLimit(1)
                Spacer()
                Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(tint)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), 2))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
        }
    }
}

/// Green/gray usage pill ("in use by 1 container" / "Unused").
struct DockerUsageBadge: View {
    let count: Int
    var noun = "container"

    var body: some View {
        let used = count > 0
        Text(used ? "in use by \(count) \(noun)\(count == 1 ? "" : "s")" : "Unused")
            .font(.caption2)
            .foregroundStyle(used ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((used ? Color.green : Color.gray).opacity(0.15), in: Capsule())
    }
}

struct DockerTagBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Filter chip row (All / Running / Stopped …).
struct DockerFilterChips<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.1) { option in
                let active = option.1 == selection
                Button { selection = option.1 } label: {
                    Text(option.0)
                        .font(.caption.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Arrow + number + unit, used for network and block IO pairs.
struct DockerIOValue: View {
    let icon: String
    let bytes: Int64
    var perSecond = false

    var body: some View {
        let parts = split
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(parts.0).font(.callout.weight(.semibold)).monospacedDigit()
            Text(parts.1).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var split: (String, String) {
        let text = Format.precise(bytes)
        let pieces = text.split(separator: " ")
        guard pieces.count == 2 else { return (text, perSecond ? "/s" : "") }
        return (String(pieces[0]), String(pieces[1]) + (perSecond ? "/s" : ""))
    }
}

/// Key/value line for the detail forms.
struct DockerRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension DockerContainer {
    var stateColor: Color {
        switch state {
        case "running": .green
        case "paused": .orange
        case "exited", "dead": .secondary
        case "restarting", "created": .blue
        default: .secondary
        }
    }
}
