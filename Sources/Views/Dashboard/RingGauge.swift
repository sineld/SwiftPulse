import SwiftUI

/// Circular percentage gauge ("%13" inside a ring), colored by load.
struct RingGauge: View {
    let percent: Double
    let label: String
    var size: CGFloat = 56

    var color: Color { percent > 90 ? .red : percent > 70 ? .orange : percent > 40 ? .green : .accentColor }

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle().trim(from: 0, to: max(min(percent / 100, 1), 0.001))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: percent)
                Text("%\(Int(percent.rounded()))").font(.system(size: size * 0.24, weight: .semibold)).monospacedDigit()
            }
            .frame(width: size, height: size)
        }
    }
}

/// "↓ 140 B/s" style rate line.
struct RateLine: View {
    let icon: String
    let bytesPerSec: Double
    var body: some View {
        let (value, unit) = Format.rate(bytesPerSec)
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct LatencyBadge: View {
    let ms: Int?
    let online: Bool
    @AppStorage("showLatency") private var showLatency = true
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(online ? .green : .red).frame(width: 7, height: 7)
            if let ms, online, showLatency {
                Text("\(ms) ms").font(.caption2).monospacedDigit()
                    .foregroundStyle(UserDefaults.standard.object(forKey: "colorizeLatency") as? Bool ?? true ? (ms < 100 ? .green : ms < 300 ? .orange : .red) : .secondary)
            }
        }
    }
}
