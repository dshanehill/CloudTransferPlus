import Foundation

public protocol SpaceAccess: Sendable { func available(at url: URL) throws -> Int64 }
public struct SystemSpace: SpaceAccess {
    public init() {}
    public func available(at url: URL) throws -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        guard let capacity = try probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else { throw HarborError.invalid("Available disk space could not be read.") }
        return Int64(capacity)
    }
}
