import SwiftUI
import Charts
import MapKit

/// A slot the widget runtime reserved for a native view: its kind, where it sits
/// in the web view, and its props with every binding already resolved.
struct GenUINativeHost: Identifiable {
    let id: Int
    let kind: String
    let rect: CGRect
    let props: [String: Any]

    init?(message: [String: Any]) {
        guard let id = message["id"] as? Int,
              let kind = message["kind"] as? String,
              let rect = message["rect"] as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat { CGFloat((rect[key] as? Double) ?? 0) }
        self.id = id
        self.kind = kind
        self.rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        self.props = message["props"] as? [String: Any] ?? [:]
    }
}

/// Draws one slot. Charts and maps are what ChatGPT iOS draws natively rather
/// than in its widget web view: they are where a web rendering looks least at
/// home — hover, axes, map tiles.
struct GenUINativeHostView: View {
    let host: GenUINativeHost

    var body: some View {
        switch host.kind {
        case "chart": GenUIChart(props: host.props)
        case "pie-chart": GenUIPieChart(props: host.props)
        case "map": GenUIMap(props: host.props)
        default: EmptyView()
        }
    }
}

// MARK: - Values

/// Reads a JSON value the way the runtime's expressions do: numbers from
/// numbers or numeric strings, labels from anything printable.
private enum GenUIValue {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func label(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return String(describing: value!)
        }
    }

    static func rows(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A named colour from the runtime's palette, or a CSS hex colour.
    static func color(_ value: Any?) -> Color? {
        guard let raw = value as? String else { return nil }
        if let index = ["accent", "orange", "green", "purple", "red"].firstIndex(of: raw) {
            return palette[index]
        }
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// The runtime's `--genui-chart-*` colours, so a native chart and an SVG
    /// fallback look alike.
    static let palette: [Color] = [
        Color(red: 0x3A / 255, green: 0x83 / 255, blue: 0xF7 / 255),
        Color(red: 0xF2 / 255, green: 0x99 / 255, blue: 0x4A / 255),
        Color(red: 0x27 / 255, green: 0xAE / 255, blue: 0x60 / 255),
        Color(red: 0x9B / 255, green: 0x51 / 255, blue: 0xE0 / 255),
        Color(red: 0xEB / 255, green: 0x57 / 255, blue: 0x57 / 255),
    ]
}

// MARK: - Chart

private struct GenUIChart: View {
    let props: [String: Any]

    private struct Series: Identifiable {
        let id: Int
        let key: String
        let label: String
        let color: Color
    }

    private struct Point: Identifiable {
        let id: String
        let x: String
        let order: Int
        let y: Double
        let series: String
    }

    private var series: [Series] {
        let raw = (props["series"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let list = raw.isEmpty ? [["key": props["yKey"] as? String ?? "value"]] : raw
        return list.enumerated().map { index, s in
            let key = s["key"] as? String ?? s["dataKey"] as? String ?? "value"
            return Series(id: index, key: key, label: s["label"] as? String ?? key,
                          color: GenUIValue.color(s["color"]) ?? GenUIValue.palette[index % GenUIValue.palette.count])
        }
    }

    private var points: [Point] {
        let xKey = props["xKey"] as? String ?? "x"
        let rows = GenUIValue.rows(props["data"])
        return series.flatMap { s in
            rows.enumerated().compactMap { index, row -> Point? in
                guard let y = GenUIValue.number(row[s.key]) else { return nil }
                return Point(id: "\(s.id)-\(index)", x: GenUIValue.label(row[xKey]), order: index, y: y, series: s.label)
            }
        }
    }

    var body: some View {
        let series = series
        let kind = props["kind"] as? String ?? "line"
        Chart(points) { point in
            switch kind {
            case "bar":
                BarMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series))
                    .cornerRadius(3)
            case "area":
                AreaMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .opacity(0.3)
                LineMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(by: .value("Series", point.series))
            default:
                LineMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.label), range: series.map(\.color))
        .chartLegend(series.count > 1 || props["series"] != nil ? .visible : .hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.caption2)
            }
        }
    }
}

private struct GenUIPieChart: View {
    let props: [String: Any]

    private struct Slice: Identifiable {
        let id: Int
        let label: String
        let value: Double
    }

    var body: some View {
        let valueKey = props["valueKey"] as? String ?? "value"
        let labelKey = props["labelKey"] as? String ?? "label"
        let slices = GenUIValue.rows(props["data"]).enumerated().compactMap { index, row -> Slice? in
            guard let value = GenUIValue.number(row[valueKey]), value > 0 else { return nil }
            return Slice(id: index, label: GenUIValue.label(row[labelKey]), value: value)
        }
        let inner = min(max(GenUIValue.number(props["innerRadius"]) ?? 0, 0), 0.9)
        Chart(slices) { slice in
            SectorMark(angle: .value("Value", slice.value),
                       innerRadius: .ratio(inner),
                       angularInset: 1)
                .foregroundStyle(by: .value("Label", slice.label))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(
            domain: slices.map(\.label),
            range: slices.indices.map { GenUIValue.palette[$0 % GenUIValue.palette.count] })
        .chartLegend(position: .trailing, alignment: .center)
    }
}

// MARK: - Map

private struct GenUIMap: View {
    let props: [String: Any]

    private struct Pin: Identifiable {
        let id: Int
        let title: String
        let coordinate: CLLocationCoordinate2D
    }

    private var pins: [Pin] {
        GenUIValue.rows(props["markers"]).enumerated().compactMap { index, m in
            guard let lat = GenUIValue.number(m["lat"] ?? m["latitude"]),
                  let lng = GenUIValue.number(m["lng"] ?? m["lon"] ?? m["longitude"]),
                  (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
            return Pin(id: index, title: GenUIValue.label(m["title"]), coordinate: .init(latitude: lat, longitude: lng))
        }
    }

    var body: some View {
        let pins = pins
        // Static: a map that pans and zooms would take the scroll wheel from the
        // chat around it. A click opens the places in Maps instead.
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(pins) { pin in
                Marker(pin.title, coordinate: pin.coordinate)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            if !pins.isEmpty {
                Button("Open in Maps") { open(pins) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }

    private func open(_ pins: [Pin]) {
        let items = pins.map { pin in
            let item = MKMapItem(placemark: MKPlacemark(coordinate: pin.coordinate))
            item.name = pin.title
            return item
        }
        MKMapItem.openMaps(with: items)
    }
}
