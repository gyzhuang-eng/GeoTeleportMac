import SwiftUI

struct DevicePickerSheet: View {
    let devices: [DevicePickerEntry]
    let selectedUDID: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    let accentBlue = Color(red: 0.2, green: 0.62, blue: 1.0)
    let terminalGreen = Color(red: 0.25, green: 0.9, blue: 0.5)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SELECT DEVICE")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("\(devices.count) iPhones detected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(devices) { entry in
                        deviceRow(entry)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 400, maxWidth: 400, minHeight: 200, maxHeight: 480)
        .background(
            ZStack {
                Color(red: 0.09, green: 0.10, blue: 0.16)
                Rectangle().fill(.regularMaterial)
            }
        )
    }

    private func deviceRow(_ entry: DevicePickerEntry) -> some View {
        let isSelected = entry.udid == selectedUDID
        return Button {
            onSelect(entry.udid)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? accentBlue.opacity(0.22) : Color.white.opacity(0.07))
                        .frame(width: 38, height: 38)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? accentBlue : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name.isEmpty ? "iPhone" : entry.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        if let ios = entry.iosVersion {
                            Text("iOS \(ios)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                    Text(udidSuffix(entry.udid))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(terminalGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accentBlue.opacity(0.10) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? accentBlue.opacity(0.50) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func udidSuffix(_ udid: String) -> String {
        let suffix = String(udid.suffix(12))
        guard udid.count > 12 else { return udid }
        return "···\(suffix)"
    }
}
