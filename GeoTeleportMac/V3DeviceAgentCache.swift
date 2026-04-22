import Foundation

final class V3DeviceAgentCache {
    struct Entry<Value> {
        let value: Value
        let timestamp: Date
    }

    private let ttl: TimeInterval
    private let queue = DispatchQueue(label: "GeoTeleportMac.V3DeviceAgentCache")
    private var availabilityEntry: Entry<Result<DeviceAgentAvailability, DeviceAgentFailure>>?
    private var deviceEntry: Entry<Result<DeviceAgentDeviceState, DeviceAgentFailure>>?
    private var tunnelEntryByKey: [String: Entry<Result<DeviceAgentTunnelState, DeviceAgentFailure>>] = [:]

    init(ttl: TimeInterval = 3) {
        self.ttl = ttl
    }

    func availability(_ producer: () -> Result<DeviceAgentAvailability, DeviceAgentFailure>) -> Result<DeviceAgentAvailability, DeviceAgentFailure> {
        cached(&availabilityEntry, producer: producer)
    }

    func deviceState(_ producer: () -> Result<DeviceAgentDeviceState, DeviceAgentFailure>) -> Result<DeviceAgentDeviceState, DeviceAgentFailure> {
        cached(&deviceEntry, producer: producer)
    }

    func tunnelState(
        for device: DeviceSnapshot,
        producer: () -> Result<DeviceAgentTunnelState, DeviceAgentFailure>
    ) -> Result<DeviceAgentTunnelState, DeviceAgentFailure> {
        let key = "\(device.isConnected)|\(device.connectionSummary)|\(device.iosVersion ?? "")"
        return queue.sync {
            pruneTunnelEntries(now: Date())
            if let entry = tunnelEntryByKey[key], !isExpired(entry.timestamp, now: Date()) {
                return entry.value
            }
            let value = producer()
            tunnelEntryByKey[key] = Entry(value: value, timestamp: Date())
            return value
        }
    }

    private func cached<Value>(
        _ entry: inout Entry<Value>?,
        producer: () -> Value
    ) -> Value {
        queue.sync {
            let now = Date()
            if let entry, !isExpired(entry.timestamp, now: now) {
                return entry.value
            }
            let value = producer()
            entry = Entry(value: value, timestamp: now)
            return value
        }
    }

    private func isExpired(_ timestamp: Date, now: Date) -> Bool {
        now.timeIntervalSince(timestamp) >= ttl
    }

    private func pruneTunnelEntries(now: Date) {
        tunnelEntryByKey = tunnelEntryByKey.filter { _, entry in
            !isExpired(entry.timestamp, now: now)
        }
    }
}
