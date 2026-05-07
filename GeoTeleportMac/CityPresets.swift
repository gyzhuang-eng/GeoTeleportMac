import SwiftUI
import CoreLocation
import Combine

// MARK: - Model

struct CustomCity: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var flag: String
    var latitude: Double
    var longitude: Double
    var colorTag: CityColorTag

    init(
        id: UUID = UUID(),
        name: String,
        flag: String,
        latitude: Double,
        longitude: Double,
        colorTag: CityColorTag
    ) {
        self.id = id
        self.name = name
        self.flag = flag
        self.latitude = latitude
        self.longitude = longitude
        self.colorTag = colorTag
    }
}

enum CityColorTag: String, Codable, CaseIterable, Identifiable {
    case orange, blue, purple, pink, cyan, green, indigo, red, mint, teal

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: return .orange
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .cyan: return .cyan
        case .green: return .green
        case .indigo: return .indigo
        case .red: return .red
        case .mint: return .mint
        case .teal: return .teal
        }
    }
}

// MARK: - Store

@MainActor
final class CityStore: ObservableObject {
    @Published private(set) var cities: [CustomCity] = []
    private let storageKey = "v3.customCities.v1"

    static let defaults: [CustomCity] = [
        .init(name: "Dubai",     flag: "🇦🇪", latitude: 25.185317, longitude: 55.281516,  colorTag: .orange),
        .init(name: "Abu Dhabi", flag: "🇦🇪", latitude: 24.340142, longitude: 54.518667,  colorTag: .blue),
        .init(name: "Hanoi",     flag: "🇻🇳", latitude: 20.992498, longitude: 105.944606, colorTag: .purple),
        .init(name: "Tokyo",     flag: "🇯🇵", latitude: 35.6895,   longitude: 139.6917,   colorTag: .pink),
        .init(name: "New York",  flag: "🇺🇸", latitude: 40.7128,   longitude: -74.0060,   colorTag: .cyan),
        .init(name: "London",    flag: "🇬🇧", latitude: 51.5074,   longitude: -0.1278,    colorTag: .green),
        .init(name: "Paris",     flag: "🇫🇷", latitude: 48.8566,   longitude: 2.3522,     colorTag: .indigo),
        .init(name: "Shenzhen",  flag: "🇨🇳", latitude: 22.5431,   longitude: 114.0579,   colorTag: .red),
    ]

    init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CustomCity].self, from: data) {
            cities = decoded
        } else {
            cities = Self.defaults
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cities) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ city: CustomCity) {
        cities.append(city)
        save()
    }

    func update(_ city: CustomCity) {
        guard let idx = cities.firstIndex(where: { $0.id == city.id }) else { return }
        cities[idx] = city
        save()
    }

    func delete(_ id: UUID) {
        cities.removeAll { $0.id == id }
        save()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let idx = cities.firstIndex(where: { $0.id == id }) else { return }
        let newIdx = max(0, min(cities.count - 1, idx + offset))
        guard newIdx != idx else { return }
        let moved = cities.remove(at: idx)
        cities.insert(moved, at: newIdx)
        save()
    }

    func resetToDefaults() {
        cities = Self.defaults
        save()
    }
}

// Convert ISO country code (e.g., "AE") to flag emoji (e.g., "🇦🇪").
func flagEmoji(forCountryCode code: String) -> String {
    let base: UInt32 = 0x1F1E6 - 0x41
    var result = ""
    for scalar in code.uppercased().unicodeScalars {
        guard scalar.value >= 0x41 && scalar.value <= 0x5A else { return "" }
        if let s = UnicodeScalar(base + scalar.value) {
            result.unicodeScalars.append(s)
        }
    }
    return result
}

// MARK: - Tiles

struct CityPresetTile: View {
    let city: CustomCity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(city.flag.isEmpty ? "📍" : city.flag)
                    .font(.system(size: 20))
                Text(city.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [city.colorTag.color.opacity(0.55), city.colorTag.color.opacity(0.28)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(city.colorTag.color.opacity(0.50), lineWidth: 1)
            )
            .shadow(color: city.colorTag.color.opacity(0.18), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct AddCityTile: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("ADD")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.10 : 0.0))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovering ? 0.45 : 0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Editor sheet

struct CityEditorSheet: View {
    @State private var draft: CustomCity
    @State private var latitudeText: String
    @State private var longitudeText: String

    let title: String
    let onSave: (CustomCity) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    init(
        initialDraft: CustomCity,
        title: String,
        onSave: @escaping (CustomCity) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self._draft = State(initialValue: initialDraft)
        self._latitudeText = State(initialValue: String(format: "%.6f", initialDraft.latitude))
        self._longitudeText = State(initialValue: String(format: "%.6f", initialDraft.longitude))
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                TextField("📍", text: $draft.flag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 22))
                    .help("Use ⌃⌘Space to open the emoji picker")
                TextField("City name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("", text: $latitudeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LON")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("", text: $longitudeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tile color")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(CityColorTag.allCases) { tag in
                        Circle()
                            .fill(tag.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white, lineWidth: tag == draft.colorTag ? 2 : 0)
                            )
                            .contentShape(Circle())
                            .onTapGesture { draft.colorTag = tag }
                    }
                }
            }

            HStack {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await autofillIfNeeded() }
    }

    private var isValid: Bool {
        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else { return false }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else { return }
        var saved = draft
        saved.latitude = lat
        saved.longitude = lon
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.flag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved.flag = "📍"
        }
        onSave(saved)
    }

    private func autofillIfNeeded() async {
        guard draft.name.isEmpty else { return }
        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else { return }
        let location = CLLocation(latitude: lat, longitude: lon)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return }
        if draft.name.isEmpty {
            let suggested = placemark.locality ?? placemark.name ?? placemark.country ?? ""
            draft.name = suggested
        }
        if draft.flag == "📍" || draft.flag.isEmpty,
           let code = placemark.isoCountryCode {
            let flag = flagEmoji(forCountryCode: code)
            if !flag.isEmpty {
                draft.flag = flag
            }
        }
    }
}
