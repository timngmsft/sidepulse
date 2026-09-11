import CryptoKit
import Foundation

public enum HerdrCommands {
    public static func discovery(override: String = "") -> String {
        let probe = "os=$(uname -s) || exit 1; printf 'SIDEPULSE_REMOTE_OS=%s\\n' \"$os\";"
        if !override.isEmpty { return wrap(probe) }
        let locations = [
            "\"$(command -v herdr 2>/dev/null)\"", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
            "/usr/bin/herdr", "\"$HOME/.local/bin/herdr\"", "\"$HOME/.cargo/bin/herdr\"",
            "\"$HOME/.local/share/mise/shims/herdr\"", "\"$HOME/.nix-profile/bin/herdr\"", "\"$HOME/bin/herdr\""
        ].joined(separator: " ")
        return wrap(probe + " for p in \(locations); do if [ -n \"$p\" ] && [ -x \"$p\" ]; then " +
                    "printf 'SIDEPULSE_HERDR_CANDIDATE=%s\\n' \"$p\"; fi; done")
    }

    public static func parseDiscovery(_ data: Data) throws -> (platform: String, paths: [String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HerdrFailure(.incompatibleResponse, "Remote discovery did not return UTF-8 text.")
        }
        let lines = text.components(separatedBy: .newlines)
        let platforms = lines.filter { $0.hasPrefix("SIDEPULSE_REMOTE_OS=") }
            .map { String($0.dropFirst("SIDEPULSE_REMOTE_OS=".count)) }
        guard platforms.count == 1, let platform = platforms.first, ["Darwin", "Linux"].contains(platform) else {
            throw HerdrFailure(.unsupportedPlatform, "Herdr remotes require macOS or Linux; the remote platform could not be verified.")
        }
        var paths: [String] = []
        for line in lines where line.hasPrefix("SIDEPULSE_HERDR_CANDIDATE=") {
            let path = String(line.dropFirst("SIDEPULSE_HERDR_CANDIDATE=".count))
            try validatePath(path)
            if !paths.contains(path) { paths.append(path) }
            guard paths.count <= 32 else {
                throw HerdrFailure(.incompatibleResponse, "Remote discovery returned too many executable candidates.")
            }
        }
        return (platform, paths)
    }

    public static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HerdrFailure(.invalidPath, "Herdr path must be an absolute path without control characters.")
        }
    }

    public static func agentList(path: String, remote: RemoteConfiguration, polling: Bool) throws -> String {
        try remote.validate()
        try validatePath(path)
        let executable = HookConfiguration.shellQuote(path)
        let session = remote.normalizedSession.isEmpty ? "" : " --session \(HookConfiguration.shellQuote(remote.normalizedSession))"
        let command = "\(executable)\(session) agent list 2>&1"
        if !polling { return wrap(command) }
        // cat forwards error envelopes and ends the loop on a broken SSH output pipe.
        return wrap("while :; do [ -x \(executable) ] || exit 127; \(command) | cat || exit; sleep 2; done")
    }

    public static func sshArguments(remote: RemoteConfiguration, controlPath: URL, command: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
         "-o", "ServerAliveCountMax=3", "-o", "ControlMaster=auto", "-o", "ControlPersist=no",
         "-S", controlPath.path, "--", remote.target, command]
    }

    public static func controlPath(root: URL, remote: RemoteConfiguration, nonce: String = UUID().uuidString) -> URL {
        let key = [root.standardizedFileURL.path, remote.id, remote.target, nonce].joined(separator: "\0")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/io.sidepulse.native-ssh-\(getuid())/\(digest)")
    }

    public static func transportFailure(code: Int32, diagnostics: String) -> HerdrFailure {
        let message = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        let authentication = ["permission denied", "authentication failed", "host key verification failed",
                              "host identification has changed", "no supported authentication methods",
                              "sign_and_send_pubkey", "too many authentication failures"]
        return HerdrFailure(authentication.contains(where: lower.contains) ? .authenticationRequired : .hostUnavailable,
                            message.isEmpty ? "SSH exited with status \(code)." : String(message.suffix(2000)))
    }

    public static func authentication(remote: RemoteConfiguration, controlPath: URL, result: URL,
                                      acknowledgement: URL, cancellation: URL, accepted: URL, finished: URL,
                                      executable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> String {
        try remote.validate()
        let socket = HookConfiguration.shellQuote(controlPath.path)
        let target = HookConfiguration.shellQuote(remote.target)
        let marker = HookConfiguration.shellQuote(result.path)
        let ack = HookConfiguration.shellQuote(acknowledgement.path)
        let cancel = HookConfiguration.shellQuote(cancellation.path)
        let done = HookConfiguration.shellQuote(finished.path)
        let accepted = HookConfiguration.shellQuote(accepted.path)
        let ssh = HookConfiguration.shellQuote(executable.path)
        return """
        #!/bin/sh
        umask 077
        adopted=0
        auth_pid=
        watchdog_pid=
        write_result() {
          printf '%s\\n' "$1" > \(marker + ".tmp") && /bin/mv -f \(marker + ".tmp") \(marker)
        }
        cleanup() {
          if [ -n "$auth_pid" ]; then kill "$auth_pid" 2>/dev/null; wait "$auth_pid" 2>/dev/null; fi
          if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null; fi
          if [ "$adopted" -eq 0 ] || [ -f \(cancel) ]; then
            \(ssh) -T -S \(socket) -O exit -- \(target) >/dev/null 2>&1
          fi
          printf 'finished\\n' > \(done)
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        printf '%s\\n' 'Authenticate the SidePulse Native SSH connection below.'
        \(ssh) -M -S \(socket) -o ControlPersist=600 -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -fN -- \(target) &
        auth_pid=$!
        (
          n=0
          while [ "$n" -lt 600 ] && kill -0 "$auth_pid" 2>/dev/null; do
            if [ -f \(cancel) ]; then kill "$auth_pid" 2>/dev/null; exit; fi
            sleep 1
            n=$((n+1))
          done
          if kill -0 "$auth_pid" 2>/dev/null; then kill "$auth_pid" 2>/dev/null; fi
        ) &
        watchdog_pid=$!
        wait "$auth_pid"
        status=$?
        auth_pid=
        kill "$watchdog_pid" 2>/dev/null
        wait "$watchdog_pid" 2>/dev/null
        watchdog_pid=
        if [ "$status" -eq 0 ] && [ ! -f \(cancel) ]; then
          if ! write_result 0; then printf 'Could not report SSH authentication to SidePulse Native.\\n' >&2; exit 1; fi
          n=0
          while [ "$n" -lt 30 ] && [ ! -f \(cancel) ]; do
            if [ -f \(ack) ]; then
              if ! (: > \(accepted + ".tmp") && /bin/mv -f \(accepted + ".tmp") \(accepted)); then
                printf 'Could not complete the SSH handoff to SidePulse Native.\\n' >&2
                exit 1
              fi
              adopted=1
              printf '%s\\n' 'SSH authentication succeeded. SidePulse Native will check Herdr; you can close this window.'
              exit 0
            fi
            sleep 1
            n=$((n+1))
          done
          printf '%s\\n' 'SidePulse Native did not accept this connection; closing it.'
          exit 1
        else
          if [ "$status" -eq 0 ]; then status=1; fi
          if ! write_result "$status"; then printf 'Could not report SSH authentication failure.\\n' >&2; fi
          printf '%s\\n' 'Authentication failed. Check the SSH error above and retry in SidePulse Native.'
          exit "$status"
        fi
        """
    }

    private static func wrap(_ script: String) -> String { "sh -c \(HookConfiguration.shellQuote(script))" }
}
