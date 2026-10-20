import Darwin
import Foundation

/// Shared contract with the Go gateway: an existing <id>.keep marker protects
/// that recording. The permanent lock file must never be replaced or removed.
struct RecordingProtectionStore {
    static let metadataName = ".recording-protection"
    static let lockName = ".recording-protection.lock"
    let directory: URL

    func withExclusiveLock(_ action: () throws -> Void) throws {
        let lockURL = directory.appendingPathComponent(Self.lockName)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ProtectionError.unavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ProtectionError.unavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        try validateMetadataDirectory()
        try action()
    }

    func validateMetadataDirectory() throws {
        let metadata = directory.appendingPathComponent(Self.metadataName)
        var info = stat()
        guard lstat(metadata.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ProtectionError.unavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ProtectionError.unavailable }
    }

    // Call only while holding the shared exclusive lock. Unknown is never false.
    func isProtected(_ file: URL) throws -> Bool {
        let marker = directory.appendingPathComponent(Self.metadataName)
            .appendingPathComponent(file.lastPathComponent + ".keep")
        var info = stat()
        if lstat(marker.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw ProtectionError.unavailable
    }

    enum ProtectionError: Error { case unavailable }
}
