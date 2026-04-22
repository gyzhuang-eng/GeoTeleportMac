import Combine
import Foundation

@MainActor
final class V3StatusStore: ObservableObject {
    @Published var status: AppStatus = .idle
    private var successToken: Int = 0

    func set(_ newStatus: AppStatus) {
        status = newStatus
        guard case .success = newStatus else { return }

        successToken &+= 1
        let token = successToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if self.successToken == token, case .success = self.status {
                self.status = .idle
            }
        }
    }
}
