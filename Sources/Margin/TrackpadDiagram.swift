import AppKit
import MarginCore
import SwiftUI

/// The current levels the diagram's meters show.
struct LiveLevels: Equatable {
    var volume: Float
    var muted: Bool
    var brightness: Float?
    var micVolume: Float?
    var micMuted: Bool

    @MainActor init(_ state: AppState) {
        volume = state.volume
        muted = state.muted
        brightness = state.brightness
        micVolume = state.micVolume
        micMuted = state.micMuted
    }
}

/// The trackpad drawn as its eight zones. Each shows what it does, lights up under the pointer,
/// and opens the zone editor when clicked.
///
/// The corners are drawn as separate squares, although on the glass they overlap the edges; a
/// zone you can point at is easier to edit than an overlap.
struct TrackpadDiagram: View {
    let layout: MarginCore.Layout
    let levels: LiveLevels
    let select: (Zone) -> Void
    @State private var hovered: Zone?

    private static let corner: CGFloat = 38
    private static let height: CGFloat = 170

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, c = Self.corner
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator)

                Text("Click a zone to change it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: w, height: h)

                cell(.leftEdge, CGRect(x: 0, y: c, width: c, height: h - 2 * c))
                cell(.rightEdge, CGRect(x: w - c, y: c, width: c, height: h - 2 * c))
                cell(.topEdge, CGRect(x: c, y: 0, width: w - 2 * c, height: c))
                cell(.bottomEdge, CGRect(x: c, y: h - c, width: w - 2 * c, height: c))
                cell(.topLeft, CGRect(x: 0, y: 0, width: c, height: c))
                cell(.topRight, CGRect(x: w - c, y: 0, width: c, height: c))
                cell(.bottomLeft, CGRect(x: 0, y: h - c, width: c, height: c))
                cell(.bottomRight, CGRect(x: w - c, y: h - c, width: c, height: c))
            }
        }
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.15), value: levels)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private func cell(_ zone: Zone, _ frame: CGRect) -> some View {
        Button { select(zone) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: zone.isCorner ? 10 : 8, style: .continuous)
                    .fill(hovered == zone ? Color.accentColor.opacity(0.18) : .clear)
                ZoneContent(zone: zone, layout: layout, levels: levels, hovered: hovered == zone)
            }
            .padding(3)
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = zone } else if hovered == zone { hovered = nil }
        }
        .help(zone.title)
        .accessibilityLabel(zone.title)
        .position(x: frame.midX, y: frame.midY)
    }
}

/// What one zone draws: a meter for a level, otherwise the symbols of its slide and tap.
private struct ZoneContent: View {
    let zone: Zone
    let layout: MarginCore.Layout
    let levels: LiveLevels
    let hovered: Bool

    var body: some View {
        let slide = zone.isEdge ? layout.edge(zone).slide : .none
        let tap = layout.tap(zone)
        if case .level(let source) = slide {
            EdgeMeter(reading: reading(source), vertical: zone.slidesVertically)
        } else if slide == .none && tap == .none {
            // Unbound: a hint that it can be given something.
            Image(systemName: "plus")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0)
        } else if zone.isCorner {
            CommandIcon(command: tap)
                .font(.caption2)
                .foregroundStyle(isActive(tap) ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
        } else {
            symbols(slide: slide, tap: tap)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(zone.slidesVertically ? .vertical : .horizontal, 8)
                .padding(zone.slidesVertically ? .horizontal : .vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }

    /// A flick shows where each direction goes, as v1.2's media strip did, with the tap between.
    @ViewBuilder private func symbols(slide: SlideAction, tap: Command) -> some View {
        let stack = zone.slidesVertically
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 18))
        stack {
            switch slide {
            case .flick(let forward, let back):
                // Back is left or down; forward is right or up.
                if zone.slidesVertically { CommandIcon(command: forward) } else { CommandIcon(command: back) }
                if tap != .none { CommandIcon(command: tap) }
                if zone.slidesVertically { CommandIcon(command: back) } else { CommandIcon(command: forward) }
            case .none:
                CommandIcon(command: tap)
            default:
                Image(systemName: slide.symbol)
                if tap != .none { CommandIcon(command: tap) }
            }
        }
    }

    /// Mute corners light up while muted, as the v1.2 corner did.
    private func isActive(_ command: Command) -> Bool {
        (command == .toggleOutputMute && levels.muted) || (command == .toggleInputMute && levels.micMuted)
    }

    private func reading(_ source: LevelSource) -> EdgeMeter.Reading {
        switch source {
        case .outputVolume:
            EdgeMeter.Reading(level: levels.muted ? 0 : Double(levels.volume),
                              symbol: levels.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", ramp: .volume)
        case .brightness:
            EdgeMeter.Reading(level: Double(levels.brightness ?? 0), symbol: "sun.max.fill", ramp: .brightness,
                              unavailable: levels.brightness == nil)
        case .inputVolume:
            EdgeMeter.Reading(level: levels.micMuted ? 0 : Double(levels.micVolume ?? 0),
                              symbol: levels.micMuted ? "mic.slash.fill" : "mic.fill", ramp: .microphone,
                              unavailable: levels.micVolume == nil)
        }
    }
}

/// A command's symbol, or the app's own icon for Launch App.
struct CommandIcon: View {
    let command: Command

    var body: some View {
        if case .launchApp(let bundleID) = command, let app = InstalledApp(bundleID: bundleID) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: command.symbol)
        }
    }
}

/// A colour that changes with the level, so a meter reads at a glance.
struct ColorRamp: Equatable {
    let low: [Double]
    let high: [Double]

    /// Deep amber when dim, warm bright yellow when bright.
    static let brightness = ColorRamp(low: [0.85, 0.36, 0.08], high: [1.0, 0.86, 0.32])
    /// Dim navy when quiet, vivid sky blue when loud.
    static let volume = ColorRamp(low: [0.16, 0.26, 0.62], high: [0.36, 0.74, 1.0])
    /// Deep teal to mint, so the mic isn't mistaken for the speakers.
    static let microphone = ColorRamp(low: [0.05, 0.4, 0.38], high: [0.35, 0.9, 0.7])

    func color(at t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return Color(red: low[0] + (high[0] - low[0]) * t,
                     green: low[1] + (high[1] - low[1]) * t,
                     blue: low[2] + (high[2] - low[2]) * t)
    }
}

/// A level bar along an edge: upright on the sides, lying down on the top and bottom.
struct EdgeMeter: View {
    struct Reading: Equatable {
        var level: Double
        var symbol: String
        var ramp: ColorRamp
        var unavailable = false
    }

    let reading: Reading
    let vertical: Bool

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            if vertical { value } else { icon }
            bar
            if vertical { icon } else { value }
        }
    }

    private var level: Double { min(max(reading.level, 0), 1) }

    private var value: some View {
        Text(reading.unavailable ? "–" : "\(Int((reading.level * 100).rounded()))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: vertical ? nil : 22)
    }

    private var icon: some View {
        Image(systemName: reading.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(.quaternary)
                // The bar's far end follows the level's colour; its base stays at the low end of the ramp.
                Capsule()
                    .fill(LinearGradient(colors: [reading.ramp.color(at: 0), reading.ramp.color(at: level)],
                                         startPoint: vertical ? .bottom : .leading,
                                         endPoint: vertical ? .top : .trailing))
                    .frame(width: vertical ? nil : geo.size.width * level,
                           height: vertical ? geo.size.height * level : nil)
            }
        }
        .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
    }
}
