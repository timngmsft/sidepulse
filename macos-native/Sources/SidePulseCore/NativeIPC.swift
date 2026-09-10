import Darwin
import Foundation

public enum NativeIPC {
    public static let requestLimit = 1_048_576
    public static let responseLimit = 4_194_304

    public static func request(_ data: Data, socket: URL, timeout: TimeInterval = 1) throws -> Data {
        guard data.count <= requestLimit else { throw NativeError("Hook event exceeds 1 MiB.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("create socket") }
        defer { Darwin.close(fd) }
        try configure(fd, timeout: timeout)
        var address = try socketAddress(socket.path)
        let flags = fcntl(fd, F_GETFL)
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError("configure socket") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw systemError("connect to SidePulse Native") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else {
                throw NativeError("SidePulse Native connection timed out.")
            }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw NativeError("SidePulse Native is not accepting connections.")
            }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { throw systemError("configure socket") }
        try write(data, to: fd, timeout: timeout)
        Darwin.shutdown(fd, SHUT_WR)
        return try read(from: fd, limit: responseLimit, timeout: timeout)
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw NativeError("Invalid IPC timeout.") }
        let flags = fcntl(fd, F_GETFL)
        // Accepted BSD sockets inherit O_NONBLOCK; use bounded blocking I/O after connection.
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw systemError("configure socket flags") }
        var noSignal: Int32 = 1
        var value = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw systemError("configure socket timeouts")
        }
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NativeError("The native event socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func isListening(at path: String) throws -> Bool {
        var address = try socketAddress(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("inspect socket") }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw systemError("inspect socket") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 || errno == EINPROGRESS || errno == EAGAIN { return true }
        if errno == ECONNREFUSED || errno == ENOENT { return false }
        throw systemError("inspect existing socket")
    }

    static func read(from fd: Int32, limit: Int, timeout: TimeInterval = 1) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeError("Native IPC read timed out.") }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read event")
            }
            guard data.count + count <= limit else { throw NativeError("IPC message is too large.") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func write(_ data: Data, to fd: Int32, timeout: TimeInterval = 1) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeError("Native IPC write timed out.") }
                let count = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError("send event") }
                sent += count
            }
        }
    }

    static func systemError(_ operation: String) -> NativeError {
        NativeError("Could not \(operation): \(String(cString: strerror(errno))).")
    }

    public static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw NativeError("Native event directories must be private and owned by the current user.")
        }
    }
}

public final class UnixEventServer {
    private let queue = DispatchQueue(label: "io.sidepulse.native.ipc")
    private var source: DispatchSourceRead?
    private let path: URL
    private var inode: UInt64?
    private let errorHandler: (String) -> Void

    public init(socket: URL, errorHandler: @escaping (String) -> Void) {
        self.path = socket; self.errorHandler = errorHandler
    }

    public func start(deliveryQueue: DispatchQueue = .main, handler: @escaping (Data) -> Data) throws {
        try queue.sync {
            guard source == nil else { return }
            let directory = path.deletingLastPathComponent()
            try NativeIPC.preparePrivateDirectory(directory)
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                    throw NativeError("Refusing to replace an unexpected file at the event socket path.")
                }
                if try NativeIPC.isListening(at: path.path) {
                    throw NativeError("Another SidePulse Native instance is already using this state directory.")
                }
                guard Darwin.unlink(path.path) == 0 else { throw NativeIPC.systemError("remove stale socket") }
            }
            var address = try NativeIPC.socketAddress(path.path)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NativeIPC.systemError("create event server") }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { Darwin.close(fd); throw NativeIPC.systemError("bind event socket") }
            guard chmod(path.path, 0o600) == 0, listen(fd, 32) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                Darwin.close(fd)
                Darwin.unlink(path.path)
                throw NativeIPC.systemError("listen for hook events")
            }
            if lstat(path.path, &info) == 0 { inode = UInt64(info.st_ino) }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 {
                        if errno != EAGAIN && errno != EWOULDBLOCK { self.errorHandler("Could not accept hook connection.") }
                        break
                    }
                    do {
                        try NativeIPC.configure(client, timeout: 0.5)
                        let request = try NativeIPC.read(from: client, limit: NativeIPC.requestLimit, timeout: 0.5)
                        deliveryQueue.async {
                            let response = handler(request)
                            self.queue.async {
                                do { try NativeIPC.write(response, to: client) }
                                catch { self.errorHandler(error.localizedDescription) }
                                Darwin.close(client)
                            }
                        }
                    } catch {
                        self.errorHandler(error.localizedDescription)
                        Darwin.close(client)
                    }
                }
            }
            reader.setCancelHandler { Darwin.close(fd) }
            source = reader
            reader.resume()
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            var info = stat()
            if lstat(path.path, &info) == 0, inode == UInt64(info.st_ino) {
                if Darwin.unlink(path.path) != 0 { errorHandler("Could not remove the native event socket.") }
            }
            inode = nil
        }
    }
}
