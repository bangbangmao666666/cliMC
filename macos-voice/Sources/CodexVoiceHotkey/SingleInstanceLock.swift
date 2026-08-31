import Foundation
import Darwin

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire(at url: URL) throws -> SingleInstanceLock? {
        let fileDescriptor = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fileDescriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }

        return SingleInstanceLock(fileDescriptor: fileDescriptor)
    }
}
