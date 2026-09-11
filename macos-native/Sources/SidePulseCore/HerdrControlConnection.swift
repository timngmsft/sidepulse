import Foundation

public final class HerdrControlConnection {
    private let queue = DispatchQueue(label: "io.sidepulse.native.ssh-cleanup", qos: .utility)
    private var command: HerdrProcess?
    private init() {}

    public static func close(remote: RemoteConfiguration, path: URL,
                             executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                             log: @escaping (String) -> Void) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let operation = HerdrControlConnection()
        operation.queue.sync {
            operation.start(remote: remote, path: path, executable: executable, log: log)
        }
    }

    private func start(remote: RemoteConfiguration, path: URL, executable: URL, log: @escaping (String) -> Void) {
        // The command retains its cleanup operation until completion or its bounded timeout.
        let job = HerdrProcess(queue: queue, log: log) { result in
            self.command = nil
            if (result.status != 0 || result.failure != nil) && FileManager.default.fileExists(atPath: path.path) {
                log("Could not close owned SSH connection: \(result.failure?.message ?? result.diagnostics)")
            }
        }
        command = job
        do {
            try job.start(executable: executable, arguments: ["-T", "-S", path.path, "-O", "exit", "--", remote.target],
                          timeout: 2)
        } catch {
            command = nil
            log("Could not close owned SSH connection: \(error.localizedDescription)")
        }
    }
}
