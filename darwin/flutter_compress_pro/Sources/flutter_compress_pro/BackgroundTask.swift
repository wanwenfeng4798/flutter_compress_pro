import Foundation

#if os(iOS)
  import UIKit
#endif

/// Balances the short iOS background execution allowance across attempts.
final class BackgroundTask {
  #if os(iOS)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    func begin() {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        // UIKit retains the expiration handler until the task ends, so a strong
        // `self` here would keep the engine alive for the whole export.
        self.bgTask = UIApplication.shared.beginBackgroundTask(
          withName: "flutter_compress_pro"
        ) { [weak self] in
          self?.end()
        }
      }
    }

    func end() {
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.bgTask)
        self.bgTask = .invalid
      }
    }

    deinit {
      // Now that the handlers above are weak, a task outstanding at dealloc would
      // never be ended — and UIKit kills the app when one expires unended. Capture
      // the identifier only, so this doesn't resurrect `self`.
      let outstanding = bgTask
      if outstanding != .invalid {
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(outstanding) }
      }
    }
  #else
    func begin() {}
    func end() {}
  #endif
}
