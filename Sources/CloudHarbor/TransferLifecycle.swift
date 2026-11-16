import AppKit
import HarborEngine

@MainActor final class TransferLifecycle: NSObject, NSApplicationDelegate {
    weak var store: TransferStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.running || store.busy || store.autoReleasing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Transfer work is still active"
        alert.informativeText = "Quitting now could leave MEGA service work running. Keep the app open while it stops. Existing iCloud uploads may continue under macOS."
        alert.addButton(withTitle: "Keep app open")
        alert.addButton(withTitle: "Stop work and stay open")
        if alert.runModal() == .alertSecondButtonReturn {
            store.stopNow()
        }
        return .terminateCancel
    }
}
