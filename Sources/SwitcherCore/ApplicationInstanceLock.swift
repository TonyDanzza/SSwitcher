import Darwin
import Foundation

/// A nonblocking, process-lifetime claim. Never unlink the file: removing it
/// would let another process lock a new inode while this lease is still held.
public final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL) -> ApplicationInstanceLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return ApplicationInstanceLock(descriptor: descriptor)
    }

    deinit { close(descriptor) }
}
