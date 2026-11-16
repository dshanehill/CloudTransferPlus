#if INTERFACE_CHECK
import Foundation
import HarborCore
import HarborEngine

/// Compiled only by the isolated native-interface validation build.
@MainActor enum InterfaceCheck {
    final class SimulatedCloud: CloudAccess {
        let root: URL
        init(_ root: URL) { self.root = root }
        func status(of url: URL) -> CloudStatus {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("upload-reported").path) ? .uploaded : .waiting
        }
        func evict(_ url: URL) throws { throw HarborError.invalid("Eviction is disabled in the interface check.") }
    }
    static func makeStore() -> TransferStore {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUD_TRANSFER_INTERFACE_ROOT"]!)
        let store = TransferStore(supportURL: root.appendingPathComponent("history"), preferences: UserDefaults(suiteName: "CloudTransferInterfaceCheck")!, cloud: SimulatedCloud(root), autoDetectMEGA: false)
        store.binaryFolder = root.appendingPathComponent("bin")
        store.destination = root.appendingPathComponent("simulated-cloud")
        store.expectedDestinationPath = store.destination?.path
        if store.transfers.isEmpty {
            store.selectedSourcePath = "/Simulated source"
            store.transfers = [
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGH", relativePath: "first.bin", expectedBytes: 32)),
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGI", relativePath: "second.bin", expectedBytes: 32)),
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGJ", relativePath: "third.bin", expectedBytes: 32))
            ]
            store.selected = store.transfers.first?.id
            store.persist()
        }
        store.tab = "Overview"
        return store
    }
}
#endif
