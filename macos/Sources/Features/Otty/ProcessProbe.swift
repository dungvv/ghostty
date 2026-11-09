import Darwin
import Foundation

/// Facts about the process running in a terminal, for the info panel.
enum ProcessProbe {
    struct Port: Identifiable, Equatable {
        let port: Int
        let process: String
        let pid: pid_t
        var id: String { "\(pid):\(port)" }
    }

    // MARK: - The process table

    /// Every process we can see, as (pid, parent pid).
    ///
    /// One sysctl rather than parsing `ps`: this feeds the port lookup, which
    /// refreshes on a timer, and a subprocess per refresh would be wasteful.
    static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, UInt32(name.count - 1), nil, &size, nil, 0) == 0, size > 0
        else { return [] }

        // The table can grow between sizing and reading it, so allow for that
        // and trust the byte count sysctl reports back rather than the one we
        // asked for.
        size += size / 8
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 1
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actual = capacity * MemoryLayout<kinfo_proc>.stride
        let ok = procs.withUnsafeMutableBytes { buf -> Bool in
            sysctl(&name, UInt32(name.count - 1), buf.baseAddress, &actual, nil, 0) == 0
        }
        guard ok else { return [] }

        let count = actual / MemoryLayout<kinfo_proc>.stride
        return (0..<count).map {
            (procs[$0].kp_proc.p_pid, procs[$0].kp_eproc.e_ppid)
        }
    }

    /// `root` and everything descended from it.
    static func descendants(of root: pid_t) -> Set<pid_t> {
        var childrenOf: [pid_t: [pid_t]] = [:]
        for entry in processTable() {
            childrenOf[entry.ppid, default: []].append(entry.pid)
        }

        var found: Set<pid_t> = [root]
        var queue = [root]
        while let pid = queue.popLast() {
            for child in childrenOf[pid] ?? [] where !found.contains(child) {
                found.insert(child)
                queue.append(child)
            }
        }
        return found
    }

    /// When a process started, or nil if it is gone.
    static func startTime(pid: pid_t) -> Date? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Bool in
            sysctl(&name, UInt32(name.count), ptr, &size, nil, 0) == 0
        }
        guard ok, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970:
            Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    static func isAlive(pid: pid_t) -> Bool {
        // Signal 0 checks for existence without delivering anything. EPERM
        // means the process is there but owned by somebody else, which still
        // counts as alive.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Ports

    /// TCP ports being listened on by `root` or any of its children.
    ///
    /// Scoped to the tab's own process tree so a server started in another
    /// window doesn't show up here.
    static func listeningPorts(under root: pid_t) async -> [Port] {
        let pids = descendants(of: root)
        guard !pids.isEmpty else { return [] }

        let list = pids.map(String.init).joined(separator: ",")
        guard let result = try? await SSHProcess.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list],
            timeout: 5)
        else { return [] }

        // lsof exits non-zero when nothing matches, so the output is what
        // matters, not the status.
        return parseLsof(result.standardOutput)
    }

    /// Parse `lsof -nP -iTCP -sTCP:LISTEN`:
    ///
    ///     node    91234 me   23u  IPv4 0x..  0t0  TCP *:3000 (LISTEN)
    ///     \__/    \___/                           \_/ \____/
    ///     name     pid                           type  addr
    static func parseLsof(_ output: String) -> [Port] {
        var seen: Set<String> = []
        var ports: [Port] = []

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, fields.first != "COMMAND" else { continue }
            guard let address = fields.first(where: { $0.contains(":") && $0 != "TCP" })
            else { continue }
            // The port is whatever follows the last colon, which also handles
            // IPv6 addresses like [::1]:8080.
            guard let portText = address.split(separator: ":").last,
                  let port = Int(portText) else { continue }
            guard let pid = pid_t(fields[1]) else { continue }

            let name = String(fields[0])
            let entry = Port(port: port, process: name, pid: pid)
            // The same socket shows up once per address family.
            if seen.insert(entry.id).inserted { ports.append(entry) }
        }

        return ports.sorted { $0.port < $1.port }
    }

    /// "3m 20s" for a duration, the way the info panel shows uptime.
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
