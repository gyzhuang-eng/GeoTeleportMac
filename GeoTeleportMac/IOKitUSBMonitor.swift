import Foundation
import Combine
import IOKit
import IOKit.usb

final class IOKitUSBMonitor: ObservableObject {
    static let shared = IOKitUSBMonitor()

    var onDeviceChange: (() -> Void)?
    
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }
        
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)

        guard let addedMatchingDict = IOServiceMatching(kIOUSBDeviceClassName),
              let removedMatchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            return
        }

        let addedCallback: IOServiceMatchingCallback = { (refcon, iterator) in
            let monitor = Unmanaged<IOKitUSBMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.deviceAdded(iterator: iterator)
        }
        
        IOServiceAddMatchingNotification(notifyPort,
                                         kIOFirstMatchNotification,
                                         addedMatchingDict,
                                         addedCallback,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &addedIterator)
        deviceAdded(iterator: addedIterator)

        let removedCallback: IOServiceMatchingCallback = { (refcon, iterator) in
            let monitor = Unmanaged<IOKitUSBMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.deviceRemoved(iterator: iterator)
        }

        IOServiceAddMatchingNotification(notifyPort,
                                         kIOTerminatedNotification,
                                         removedMatchingDict,
                                         removedCallback,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &removedIterator)
        deviceRemoved(iterator: removedIterator)
    }

    private func deviceAdded(iterator: io_iterator_t) {
        var deviceHasChanged = false
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceHasChanged = true
            IOObjectRelease(device)
        }
        if deviceHasChanged {
            DispatchQueue.main.async {
                self.onDeviceChange?()
            }
        }
    }

    private func deviceRemoved(iterator: io_iterator_t) {
        var deviceHasChanged = false
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceHasChanged = true
            IOObjectRelease(device)
        }
        if deviceHasChanged {
            DispatchQueue.main.async {
                self.onDeviceChange?()
            }
        }
    }
}
