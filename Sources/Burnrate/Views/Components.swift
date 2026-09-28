import Charts
import SwiftUI

// MARK: - KPI tile

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .helpIfPresent(help)
    }
}

extension View {
    /// `.help("")` can show an empty bubble, so only attach help when there is text.
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}

// MARK: - Tooltip chrome (shared by every chart)

/// Opaque, high-contrast tooltip body. Materials looked washed out over bars in both themes.
struct TooltipBox<Content: View>: View {
    var width: CGFloat? = 230
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(10)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .foregroundStyle(.primary)
    }
}

struct TooltipRow: View {
    let color: Color?
    let label: String
    let value: String
    var bold = false

    var body: some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9) }
            Text(label).lineLimit(1)
            Spacer(minLength: 10)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular)
        }
        .font(.caption)
    }
}

// MARK: - Limit gauge

struct LimitBar: View {
    let window: LimitWindow
    var compact = false

    var body: some View {
        let (color, icon, status) = window.isStale
            ? (Palette.other, "clock", "Stale")
            : Palette.status(for: window.percent)
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(compact ? .caption : .subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.percent(window.percent))
                    .font(compact ? .callout.weight(.semibold) : .system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * min(1, window.percent / 100)))
                }
            }
            .frame(height: compact ? 6 : 9)
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text(status)
                Spacer()
                if window.resetsAt != nil {
                    Text("resets in \(Fmt.countdown(to: window.resetsAt))").monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let detail = window.detail, !compact || window.isStale {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .help(window.detail ?? window.label)
    }
}

// MARK: - Provider quota card

struct ProviderCard: View {
    let status: ProviderStatus

    /// A failed refresh matters less while the last good reading is still recent.
    private var isFresh: Bool {
        status.fetchedAt.map { Date().timeIntervalSince($0) < 2 * status.kind.interval + 60 } ?? false
    }

    private var symbol: String {
        switch status.kind {
        case .claude: "sparkle"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .openRouter: "arrow.triangle.branch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(status.kind.title, systemImage: symbol).font(.headline)
                if let plan = status.plan {
                    Text(plan).font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer(minLength: 4)
                if let err = status.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(isFresh ? Color.secondary : Palette.warning)
                        .help(isFresh ? "\(err). Showing a reading from \(status.fetchedAt!.formatted(.relative(presentation: .named)))." : err)
                }
            }
            if status.windows.isEmpty && status.facts.isEmpty {
                Text(status.error ?? "Loading…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(status.windows) { LimitBar(window: $0) }
            if !status.facts.isEmpty {
                VStack(spacing: 5) {
                    ForEach(status.facts) { f in
                        HStack {
                            Text(f.label).foregroundStyle(.secondary)
                            Spacer()
                            if f.warning { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.critical) }
                            Text(f.value).monospacedDigit().fontWeight(f.warning ? .semibold : .regular)
                        }
                        .font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if let via = status.via { Text("via \(via)") }
                if let account = status.account { Text("· \(account)").lineLimit(1).truncationMode(.middle) }
                Spacer()
                if let err = status.error, !isFresh {
                    Text(err).lineLimit(1).foregroundStyle(Palette.serious)
                } else if let t = status.fetchedAt {
                    Text("updated \(t.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct ProviderGrid: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let list = app.providerList
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 240), spacing: 16, alignment: .top), count: max(1, list.count)),
                  spacing: 16) {
            ForEach(list) { ProviderCard(status: $0) }
        }
    }
}

// MARK: - Usage-over-time chart

enum Metric: String, CaseIterable, Identifiable {
    case all = "All tokens", inOut = "Input + output", output = "Output", cost = "Est. cost"
    var id: String { rawValue }

    func value(_ p: BucketPoint) -> Double {
        switch self {
        case .all: Double(p.all)
        case .inOut: Double(p.inOut)
        case .output: Double(p.output)
        case .cost: p.cost
        }
    }

    func format(_ v: Double) -> String { self == .cost ? Fmt.cost(v) : Fmt.tokens(Int(v)) }
}

struct UsageChart: View {
    @EnvironmentObject var app: AppState
    let points: [BucketPoint]
    let metric: Metric
    let hourly: Bool
    /// When set, only this model is charted, as a single unfolded series.
    var focusModel: String?
    var height: CGFloat = 260
    @State private var selected: Date?

    private struct Series: Identifiable {
        var id: String { "\(bucket.timeIntervalSince1970)|\(name)" }
        let bucket: Date
        let name: String
        let value: Double
    }

    private func name(_ model: String) -> String {
        focusModel != nil ? ModelNames.display(model) : app.seriesName(model)
    }

    private var series: [Series] {
        var acc: [String: Series] = [:]
        for p in points where focusModel == nil || p.model == focusModel {
            let name = name(p.model)
            let key = "\(p.bucket.timeIntervalSince1970)|\(name)"
            acc[key] = Series(bucket: p.bucket, name: name, value: (acc[key]?.value ?? 0) + metric.value(p))
        }
        // Stack in legend order inside each bucket, so segments never jump around.
        let order = Dictionary(uniqueKeysWithValues: domain.enumerated().map { ($1, $0) })
        return acc.values.sorted {
            $0.bucket != $1.bucket ? $0.bucket < $1.bucket : (order[$0.name] ?? .max) < (order[$1.name] ?? .max)
        }
    }

    /// Series order = all-time rank, so colors never move when the filter changes.
    private var domain: [String] {
        if let focusModel { return [ModelNames.display(focusModel)] }
        let present = Set(points.map { name($0.model) })
        var names = app.allTime.modelRank.prefix(Palette.series.count).map(ModelNames.display).filter(present.contains)
        if present.contains("Other") { names.append("Other") }
        return names
    }

    private var colors: [Color] {
        if let focusModel {
            return [app.namedModels.contains(focusModel) ? app.color(for: focusModel) : Palette.series[0]]
        }
        return domain.map { name in
            if name == "Other" { return Palette.other }
            let model = app.allTime.modelRank.first { ModelNames.display($0) == name } ?? name
            return app.color(for: model)
        }
    }

    private var unit: Calendar.Component { hourly ? .hour : .day }

    private func bucketed(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: unit, for: date)?.start ?? date
    }

    /// The x domain spans the whole selected range, so sparse data isn't stretched.
    private var xDomain: ClosedRange<Date> {
        let end = Calendar.current.date(byAdding: unit, value: 1, to: bucketed(Date())) ?? Date()
        let start = app.range.since ?? points.map(\.bucket).min() ?? end.addingTimeInterval(-86400)
        return min(start, end.addingTimeInterval(-3600))...end
    }

    var body: some View {
        let data = series
        let names = domain
        let palette = colors
        VStack(alignment: .leading, spacing: 10) {
            if data.isEmpty {
                ContentUnavailableView("No usage in this range", systemImage: "chart.bar",
                                       description: Text("Pick a wider time range or another agent."))
                    .frame(height: height)
            } else {
                Chart {
                    ForEach(data) { s in
                        BarMark(x: .value("Time", s.bucket, unit: unit), y: .value(metric.rawValue, s.value))
                            .foregroundStyle(by: .value("Model", s.name))
                            .cornerRadius(2)
                            .opacity(selected == nil || bucketed(selected!) == s.bucket ? 1 : 0.45)
                    }
                    if let selected {
                        let b = bucketed(selected)
                        RuleMark(x: .value("Selected", b, unit: unit))
                            .foregroundStyle(.secondary.opacity(0.15))
                            .zIndex(-1)
                            .annotation(position: .top, spacing: 0,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                tooltip(for: b, data: data, names: names, palette: palette)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: names, range: palette)
                .chartXScale(domain: xDomain)
                .chartLegend(.hidden)
                .chartXSelection(value: $selected)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(metric.format(d)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                        AxisValueLabel(format: hourly ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: height)

                FlowLegend(items: zip(names, palette).map { ($0, $1) })
            }
        }
    }

    @ViewBuilder
    private func tooltip(for bucket: Date, data: [Series], names: [String], palette: [Color]) -> some View {
        let rows = data.filter { $0.bucket == bucket }.sorted { $0.value > $1.value }
        TooltipBox {
            Text(bucket, format: hourly ? .dateTime.weekday().hour().minute() : .dateTime.weekday(.wide).month().day())
                .font(.caption.weight(.semibold))
            if rows.isEmpty {
                Text("No usage").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { r in
                    TooltipRow(color: palette[names.firstIndex(of: r.name) ?? 0], label: r.name, value: metric.format(r.value))
                }
                if rows.count > 1 {
                    Divider()
                    TooltipRow(color: nil, label: "Total", value: metric.format(rows.reduce(0) { $0 + $1.value }), bold: true)
                }
            }
        }
    }
}

struct FlowLegend: View {
    let items: [(String, Color)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { LegendDot(color: $0.1, label: $0.0) }
        }
    }
}

// MARK: - Model share donut

struct ModelShareDonut: View {
    @EnvironmentObject var app: AppState
    let models: [ModelTotal]
    let metric: Metric
    @State private var angle: Double?
    @State private var hoveredName: String?

    private struct Slice: Identifiable {
        var id: String { name }
        let name: String
        let value: Double
        let color: Color
    }

    private var slices: [Slice] {
        var named: [Slice] = []
        var other = 0.0
        for m in models {
            let v: Double = switch metric {
            case .all: Double(m.totals.all)
            case .inOut: Double(m.totals.input + m.totals.output)
            case .output: Double(m.totals.output)
            case .cost: m.totals.cost
            }
            if app.namedModels.contains(m.model) {
                named.append(Slice(name: ModelNames.display(m.model), value: v, color: app.color(for: m.model)))
            } else {
                other += v
            }
        }
        named.sort { $0.value > $1.value }
        if other > 0 { named.append(Slice(name: "Other", value: other, color: Palette.other)) }
        return named.filter { $0.value > 0 }
    }

    private func slice(at angle: Double?, in data: [Slice]) -> Slice? {
        guard let angle else { return nil }
        var acc = 0.0
        for s in data {
            acc += s.value
            if angle <= acc { return s }
        }
        return nil
    }

    var body: some View {
        let data = slices
        let total = data.reduce(0) { $0 + $1.value }
        let focus = slice(at: angle, in: data)?.name ?? hoveredName
        let focused = data.first { $0.name == focus }
        HStack(alignment: .center, spacing: 20) {
            Chart(data) { s in
                SectorMark(angle: .value("Share", s.value), innerRadius: .ratio(0.62),
                           outerRadius: .ratio(focus == s.name ? 1 : 0.94), angularInset: 1.5)
                    .foregroundStyle(s.color)
                    .cornerRadius(3)
                    .opacity(focus == nil || focus == s.name ? 1 : 0.35)
            }
            .chartAngleSelection(value: $angle)
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text(metric.format(focused?.value ?? total)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(focused.map { total > 0 ? String(format: "%@ · %.1f%%", $0.name, $0.value / total * 100) : $0.name } ?? metric.rawValue)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 100)
                }
            }
            .frame(width: 170, height: 170)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(data) { s in
                    HStack {
                        LegendDot(color: s.color, label: s.name)
                        Spacer(minLength: 10)
                        Text(total > 0 ? String(format: "%.1f%%", s.value / total * 100) : "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(metric.format(s.value)).font(.caption.weight(.medium).monospacedDigit())
                            .frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 4).fill(focus == s.name ? Color.primary.opacity(0.06) : .clear))
                    .onHover { hoveredName = $0 ? s.name : (hoveredName == s.name ? nil : hoveredName) }
                }
            }
        }
    }
}

// MARK: - Activity heatmap (weekday x hour)

struct ActivityHeatmap: View {
    let cells: [HeatCell]
    @State private var hovered: (row: Int, hour: Int)?
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        var grid = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for c in cells {
            let row = (c.weekday + 6) % 7 // Monday first
            grid[row][c.hour] += c.tokens
        }
        let maxV = max(1, grid.flatMap { $0 }.max() ?? 1)
        let total = max(1, grid.flatMap { $0 }.reduce(0, +))
        return VStack(alignment: .leading, spacing: 3) {
            // Readout line instead of system tooltips, which appear late and clip at edges.
            HStack {
                if let h = hovered {
                    let v = grid[h.row][h.hour]
                    Text("\(days[h.row]) \(String(format: "%02d:00–%02d:00", h.hour, (h.hour + 1) % 24))")
                        .fontWeight(.semibold)
                    Text("\(Fmt.tokens(v)) tokens · \(String(format: "%.1f%%", Double(v) / Double(total) * 100)) of the period")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hover a cell for details").foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .font(.caption)
            .frame(height: 18)

            ForEach(0..<7, id: \.self) { r in
                HStack(spacing: 3) {
                    Text(days[r]).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let isHovered = hovered?.row == r && hovered?.hour == h
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(grid[r][h], maxV))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(isHovered ? 0.8 : 0), lineWidth: 1.5))
                            .frame(height: 18)
                            .frame(maxWidth: .infinity)
                            .onHover { inside in
                                if inside { hovered = (r, h) } else if isHovered { hovered = nil }
                            }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 28)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 3 == 0 ? "\(h)" : "").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach(Palette.sequential.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Palette.sequential[i]).frame(width: 12, height: 10)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ v: Int, _ maxV: Int) -> Color {
        guard v > 0 else { return Palette.heatEmpty }
        // sqrt scale so a few heavy hours don't wash out everything else
        let t = sqrt(Double(v) / Double(maxV))
        let idx = min(Palette.sequential.count - 1, Int(t * Double(Palette.sequential.count - 1) + 0.5))
        return Palette.sequential[idx]
    }
}

// MARK: - Ranked horizontal bars

struct RankedBars: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let value: Double
        let valueText: String
        var detail: String?
        var color: Color = Palette.series[0]
        var help: String?
    }

    let items: [Item]
    var onSelect: ((Item) -> Void)?
    @State private var hovered: String?

    var body: some View {
        let maxV = max(items.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("Nothing in this range").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.label).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let d = item.detail { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(item.valueText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        if onSelect != nil, hovered == item.id {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    GeometryReader { geo in
                        Capsule().fill(item.color).frame(width: max(3, geo.size.width * item.value / maxV))
                    }
                    .frame(height: 5)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered == item.id ? Color.primary.opacity(0.05) : .clear))
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .onTapGesture { onSelect?(item) }
                .helpIfPresent(item.help)
            }
        }
        .padding(.horizontal, -6)
    }
}

// MARK: - Limit history

struct LimitHistoryChart: View {
    let points: [LimitPoint]
    /// Quota windows that exist right now; readings for retired/renamed windows are not charted.
    var activeKeys: Set<String>?
    @State private var selected: Date?

    /// Fixed series order (Claude first), so each window keeps its color.
    private static let priority = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
                                   "copilot|premium_interactions", "openrouter|credits", "openrouter|key", "openrouter|free_daily"]

    private static func rank(_ key: String) -> Int {
        priority.firstIndex { key == $0 || key.hasPrefix($0 + "|") } ?? 99
    }

    private var series: [(key: String, label: String)] {
        var seen: [String: String] = [:]
        for p in points where activeKeys?.contains(p.key) ?? true { seen[p.key] = p.label }
        return seen.map { ($0.key, $0.value) }.sorted {
            (Self.rank($0.key), $0.key) < (Self.rank($1.key), $1.key)
        }
    }

    /// Readings are only stored when they change, so carry each series' last value to "now";
    /// otherwise a window with one reading would draw nothing.
    private var extended: [LimitPoint] {
        let now = Date()
        var out = points
        for (key, _) in series {
            if let last = points.last(where: { $0.key == key }), now.timeIntervalSince(last.ts) > 1 {
                out.append(LimitPoint(ts: now, key: key, label: last.label, percent: last.percent))
            }
        }
        return out
    }

    var body: some View {
        let keys = series
        let ids = keys.map(\.key)
        let labels = keys.map(\.label)
        // Fixed slots in order; anything past the palette folds to grey rather than cycling.
        let palette = ids.indices.map { $0 < Palette.series.count ? Palette.series[$0] : Palette.other }
        let active = Set(ids)
        let data = extended.filter { active.contains($0.key) }
        let span = (data.map(\.ts).max() ?? Date()).timeIntervalSince(data.map(\.ts).min() ?? Date())
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(data) { p in
                    LineMark(x: .value("Time", p.ts), y: .value("Used %", p.percent), series: .value("Window", p.key))
                        .foregroundStyle(by: .value("Window", p.key))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.stepEnd)
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            TooltipBox(width: 270) {
                                Text(selected, format: .dateTime.weekday().month().day().hour().minute()).font(.caption.weight(.semibold))
                                ForEach(Array(keys.enumerated()), id: \.1.key) { i, k in
                                    // Step chart: the value in effect is the last reading at or before the cursor.
                                    if let v = data.last(where: { $0.key == k.key && $0.ts <= selected }) {
                                        TooltipRow(color: palette[i], label: k.label, value: Fmt.percent(v.percent))
                                    }
                                }
                            }
                        }
                }
            }
            .chartForegroundStyleScale(domain: ids, range: palette)
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                    AxisValueLabel(format: span < 2 * 86400 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 240)
            FlowLegend(items: zip(labels, palette).map { ($0, $1) })
        }
    }
}
