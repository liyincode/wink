import Foundation
import Darwin

public enum AgentCommand: String, Codable {
    case blackout, restore, status

    public static func parse(_ arguments: [String]) -> AgentCommand? {
        guard let first = arguments.first, let command = Self(rawValue: first),
              arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--json") else { return nil }
        return command
    }
}

public struct AgentStatus: Codable {
    public let state: String
    public let target: String
    public let progress: Double
    public let recoveryPending: Bool
    public let scheduleEnabled: Bool

    public init(state: String, target: String, progress: Double, recoveryPending: Bool, scheduleEnabled: Bool) {
        self.state = state; self.target = target; self.progress = progress
        self.recoveryPending = recoveryPending; self.scheduleEnabled = scheduleEnabled
    }
}

public struct AgentResponse: Codable {
    public struct Failure: Codable {
        public let code: String
        public let message: String
    }
    public let version: Int
    public let ok: Bool
    public let status: AgentStatus?
    public let error: Failure?

    public static func success(_ status: AgentStatus) -> Self {
        Self(version: 1, ok: true, status: status, error: nil)
    }
    public static func failure(_ code: String, _ message: String) -> Self {
        Self(version: 1, ok: false, status: nil, error: Failure(code: code, message: message))
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self); data.append(10)
        return data
    }
}

public enum AgentIPC {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenPause/agent", isDirectory: true)
    }
    public static var socketPath: String { directory.appendingPathComponent("control.sock").path }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ScreenError("Local socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
        return address
    }

    static func configure(_ fd: Int32) {
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func readLine(_ fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 4096 {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw ScreenError("Local request timed out or the connection closed. Query status before retrying.") }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw ScreenError("Local request exceeds 4096 bytes.")
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScreenError("Unable to send the local response.") }
                offset += count
            }
        }
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var user: uid_t = 0, group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 && user == geteuid()
    }

    public static func request(_ command: AgentCommand) -> AgentResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure("transport_error", "Unable to create the local connection.") }
        defer { close(fd) }
        configure(fd)
        do {
            var addr = try address(socketPath)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return .failure("unavailable", "Wink is not running or its local control service is unavailable. Open Wink.app first.") }
            guard sameUser(fd) else { return .failure("access_denied", "The local service belongs to another user.") }
            var request = try JSONEncoder().encode(command); request.append(10)
            try write(request, to: fd)
            return try JSONDecoder().decode(AgentResponse.self, from: readLine(fd))
        } catch { return .failure("transport_error", error.localizedDescription) }
    }
}

public final class AgentServer {
    private var source: DispatchSourceRead?

    public init() {}
    public func start(handler: @escaping (AgentCommand, @escaping (AgentResponse) -> Void) -> Void) throws {
        let directory = AgentIPC.directory.path
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT else { throw ScreenError("Unable to inspect the local control directory.") }
            try FileManager.default.createDirectory(at: AgentIPC.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              chmod(directory, 0o700) == 0 else { throw ScreenError("The local control directory must belong to the current user.") }
        let path = AgentIPC.socketPath
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw ScreenError("The local control socket path is occupied.") }
            guard unlink(path) == 0 else { throw ScreenError("Unable to remove the stale control socket.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScreenError("Unable to create the local control socket.") }
        do {
            var addr = try AgentIPC.address(path)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { throw ScreenError("Unable to start the local control socket.") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        } catch { close(fd); throw error }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "wink.agent.accept"))
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                _ = fcntl(client, F_SETFL, 0)
                AgentIPC.configure(client)
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { close(client) }
                    guard AgentIPC.sameUser(client) else { return }
                    do {
                        let command = try JSONDecoder().decode(AgentCommand.self, from: AgentIPC.readLine(client))
                        let deadline = Date().addingTimeInterval(8)
                        let reply = ReplyBox()
                        DispatchQueue.main.async {
                            guard Date() < deadline else { return }
                            handler(command) { reply.complete($0) }
                        }
                        let result = reply.wait() ?? .failure("timeout", "Wink did not finish in time. Query status before retrying.")
                        try AgentIPC.write(result.json(), to: client)
                    } catch {
                        try? AgentIPC.write(AgentResponse.failure("invalid_request", error.localizedDescription).json(), to: client)
                    }
                }
            }
        }
        source.setCancelHandler { close(fd); unlink(path) }
        self.source = source
        source.resume()
    }
    public func stop() { source?.cancel(); source = nil }
    deinit { stop() }
}

private final class ReplyBox {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: AgentResponse?
    func complete(_ response: AgentResponse) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = response; semaphore.signal()
    }
    func wait() -> AgentResponse? {
        guard semaphore.wait(timeout: .now() + 8) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
