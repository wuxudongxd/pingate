import Darwin
import Foundation

/// Low-level TCP socket snapshot extracted from Darwin `libproc`.
public struct RawSocketInfo: Sendable, Equatable, Hashable {
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16
    public let tcpState: String
    public let ipVersion: Int

    public init(
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        tcpState: String,
        ipVersion: Int = 4
    ) {
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tcpState = tcpState
        self.ipVersion = ipVersion
    }
}

/// Snapshot of a single macOS process gathered via native Darwin APIs.
public struct InspectedProcess: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let executablePath: String
    public let arguments: [String]
    /// `nil` indicates the environment could not be read (e.g. permission denied or process exited).
    public let environment: [String: String]?
    public let sockets: [RawSocketInfo]

    public init(
        pid: Int32,
        ppid: Int32 = 0,
        name: String,
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        sockets: [RawSocketInfo] = []
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.sockets = sockets
    }
}

/// Abstraction over process & socket inspection so LeakAuditor and AppLauncher are fully unit-testable.
public protocol ProcessInspecting: Sendable {
    func listPIDs() -> [Int32]
    func inspectProcess(pid: Int32, includeSockets: Bool, includeEnvironment: Bool) -> InspectedProcess?
    func inspectAllProcesses(
        matching predicate: @Sendable (_ name: String, _ executablePath: String) -> Bool,
        includeSockets: Bool,
        includeEnvironment: Bool
    ) -> [InspectedProcess]
    func isLocalPortListening(host: String, port: Int, timeout: TimeInterval) -> Bool
}

public extension ProcessInspecting {
    func inspectAllProcesses(
        matching predicate: @Sendable (_ name: String, _ executablePath: String) -> Bool,
        includeSockets: Bool = true,
        includeEnvironment: Bool = true
    ) -> [InspectedProcess] {
        var results: [InspectedProcess] = []
        for pid in listPIDs() where pid > 0 {
            if let snapshot = inspectProcess(
                pid: pid,
                includeSockets: false,
                includeEnvironment: false
            ), predicate(snapshot.name, snapshot.executablePath) {
                if let full = inspectProcess(
                    pid: pid,
                    includeSockets: includeSockets,
                    includeEnvironment: includeEnvironment
                ) {
                    results.append(full)
                }
            }
        }
        return results
    }
}

/// Native macOS process, environment, and TCP socket inspector backed by `libproc` and `sysctl(KERN_PROCARGS2)`.
/// Never spawns external processes such as `lsof` or `ps`.
public struct DarwinProcessInspector: ProcessInspecting, Sendable {
    public init() {}

    /// Enumerates all live PIDs using `proc_listallpids`.
    public func listPIDs() -> [Int32] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        let capacity = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bufferSize = Int32(capacity * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, bufferSize)
        guard actualCount > 0 else { return [] }

        let limit = min(Int(actualCount), capacity)
        return pids[0..<limit].filter { $0 > 0 }
    }

    /// Reads the executable path for a PID using `proc_pidpath`.
    public func executablePath(for pid: Int32) -> String? {
        let maxPathSize = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: maxPathSize)
        let length = proc_pidpath(pid, &buffer, UInt32(maxPathSize))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads BSD process metadata (name, parent PID) via `proc_pidinfo(PROC_PIDTBSDINFO)`.
    public func bsdInfo(for pid: Int32) -> (name: String, ppid: Int32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }

        let rawName = withUnsafeBytes(of: info.pbi_name) { bytes -> String in
            let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<nulIndex], as: UTF8.self)
        }
        if !rawName.isEmpty {
            return (rawName, Int32(info.pbi_ppid))
        }

        let rawComm = withUnsafeBytes(of: info.pbi_comm) { bytes -> String in
            let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<nulIndex], as: UTF8.self)
        }
        return (rawComm, Int32(info.pbi_ppid))
    }

    /// Inspects a single PID for name, path, optional arguments/environment, and optional TCP sockets.
    public func inspectProcess(
        pid: Int32,
        includeSockets: Bool = true,
        includeEnvironment: Bool = true
    ) -> InspectedProcess? {
        let path = executablePath(for: pid)
        let bsd = bsdInfo(for: pid)

        guard path != nil || bsd != nil else {
            return nil
        }

        let resolvedPath = path ?? ""
        let resolvedName: String
        if !resolvedPath.isEmpty {
            resolvedName = URL(fileURLWithPath: resolvedPath).lastPathComponent
        } else {
            resolvedName = bsd?.name ?? ""
        }
        let ppid = bsd?.ppid ?? 0

        var arguments: [String] = []
        var environment: [String: String]? = nil
        if includeEnvironment {
            if let procArgs = processArgsAndEnvironment(for: pid) {
                arguments = procArgs.arguments
                environment = procArgs.environment
            }
        }

        let sockets = includeSockets ? tcpSockets(for: pid) : []

        return InspectedProcess(
            pid: pid,
            ppid: ppid,
            name: resolvedName,
            executablePath: resolvedPath,
            arguments: arguments,
            environment: environment,
            sockets: sockets
        )
    }

    /// Inspects all processes matching the lightweight name/path predicate first,
    /// avoiding expensive socket/env queries for unrelated system processes.
    public func inspectAllProcesses(
        matching predicate: @Sendable (_ name: String, _ executablePath: String) -> Bool,
        includeSockets: Bool = true,
        includeEnvironment: Bool = true
    ) -> [InspectedProcess] {
        let pids = listPIDs()
        var results: [InspectedProcess] = []

        for pid in pids where pid > 0 {
            let path = executablePath(for: pid) ?? ""
            let bsd = path.isEmpty ? bsdInfo(for: pid) : nil
            let name: String
            if !path.isEmpty {
                name = URL(fileURLWithPath: path).lastPathComponent
            } else if let bsdName = bsd?.name, !bsdName.isEmpty {
                name = bsdName
            } else {
                continue
            }

            guard predicate(name, path) else { continue }

            let fullBsd = bsd ?? bsdInfo(for: pid)
            let ppid = fullBsd?.ppid ?? 0

            var arguments: [String] = []
            var environment: [String: String]? = nil
            if includeEnvironment, let parsed = processArgsAndEnvironment(for: pid) {
                arguments = parsed.arguments
                environment = parsed.environment
            }

            let sockets = includeSockets ? tcpSockets(for: pid) : []

            results.append(
                InspectedProcess(
                    pid: pid,
                    ppid: ppid,
                    name: name,
                    executablePath: path,
                    arguments: arguments,
                    environment: environment,
                    sockets: sockets
                )
            )
        }

        return results
    }

    /// Lists all live IPv4 and IPv6 TCP sockets held by `pid` using `proc_pidinfo` and `proc_pidfdinfo`.
    public func tcpSockets(for pid: Int32) -> [RawSocketInfo] {
        let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }

        let fdStride = MemoryLayout<proc_fdinfo>.stride
        let count = Int(bytesNeeded) / fdStride + 32
        var fdList = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actualBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdList, Int32(count * fdStride))
        guard actualBytes > 0 else { return [] }

        let fdCount = min(Int(actualBytes) / fdStride, count)
        let sockInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        var sockets: [RawSocketInfo] = []

        for i in 0..<fdCount {
            let fd = fdList[i]
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }

            var socketInfo = socket_fdinfo()
            let returned = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, sockInfoSize)
            guard returned == sockInfoSize else { continue }
            guard socketInfo.psi.soi_kind == SOCKINFO_TCP else { continue }

            let family = socketInfo.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }

            let tcpInfo = socketInfo.psi.soi_proto.pri_tcp
            let inInfo = tcpInfo.tcpsi_ini
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inInfo.insi_lport))
            let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inInfo.insi_fport))
            let stateName = Self.tcpStateName(tcpInfo.tcpsi_state)

            if family == AF_INET {
                let localAddr = Self.formatIPv4(inInfo.insi_laddr.ina_46.i46a_addr4)
                let remoteAddr = Self.formatIPv4(inInfo.insi_faddr.ina_46.i46a_addr4)
                sockets.append(
                    RawSocketInfo(
                        localAddress: localAddr,
                        localPort: localPort,
                        remoteAddress: remoteAddr,
                        remotePort: remotePort,
                        tcpState: stateName,
                        ipVersion: 4
                    )
                )
            } else {
                let localAddr = Self.formatIPv6(inInfo.insi_laddr.ina_6)
                let remoteAddr = Self.formatIPv6(inInfo.insi_faddr.ina_6)
                sockets.append(
                    RawSocketInfo(
                        localAddress: localAddr,
                        localPort: localPort,
                        remoteAddress: remoteAddr,
                        remotePort: remotePort,
                        tcpState: stateName,
                        ipVersion: 6
                    )
                )
            }
        }

        return sockets
    }

    /// Reads argv and environment variables of a live process using `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`.
    /// Returns `nil` when permission is denied or the process has exited.
    public func processArgsAndEnvironment(
        for pid: Int32
    ) -> (execPath: String, arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else {
            return nil
        }

        // Add small headroom in case arguments/env buffer slightly shifts.
        var bufferSize = size + 256
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&mib, 3, &buffer, &bufferSize, nil, 0) == 0, bufferSize >= MemoryLayout<Int32>.size else {
            return nil
        }

        return Self.parseProcArgs2(Data(buffer[0..<bufferSize]))
    }

    /// Pure parser for a raw `KERN_PROCARGS2` byte buffer.
    /// Format: `[argc: Int32][exec_path\0][\0...][argv[0]\0 ... argv[argc-1]\0][env[0]\0 ...][\0\0][apple...]`
    public static func parseProcArgs2(
        _ data: Data
    ) -> (execPath: String, arguments: [String], environment: [String: String])? {
        let int32Size = MemoryLayout<Int32>.size
        guard data.count >= int32Size else { return nil }

        let bytes = [UInt8](data)
        let argc = bytes.withUnsafeBytes { raw -> Int32 in
            raw.loadUnaligned(as: Int32.self)
        }
        guard argc >= 0, argc < 100_000 else { return nil }

        var index = int32Size
        let count = bytes.count

        // 1. Read null-terminated executable path.
        let execStart = index
        while index < count && bytes[index] != 0 {
            index += 1
        }
        let execPath = String(decoding: bytes[execStart..<index], as: UTF8.self)

        // 2. Skip NUL padding bytes between exec_path and argv[0].
        while index < count && bytes[index] == 0 {
            index += 1
        }

        // 3. Read `argc` argument strings.
        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard index < count else { break }
            let argStart = index
            while index < count && bytes[index] != 0 {
                index += 1
            }
            arguments.append(String(decoding: bytes[argStart..<index], as: UTF8.self))
            if index < count {
                index += 1 // consume NUL terminator
            }
        }

        // 4. Skip any padding NULs between argv and envp.
        while index < count && bytes[index] == 0 {
            index += 1
        }

        // 5. Read environment variables (`KEY=VALUE`) until empty NUL separator or end of buffer.
        var environment: [String: String] = [:]
        while index < count {
            if bytes[index] == 0 {
                break
            }
            let envStart = index
            while index < count && bytes[index] != 0 {
                index += 1
            }
            let entry = String(decoding: bytes[envStart..<index], as: UTF8.self)
            if let eqIdx = entry.firstIndex(of: "=") {
                let key = String(entry[..<eqIdx])
                let value = String(entry[entry.index(after: eqIdx)...])
                if !key.isEmpty && environment[key] == nil {
                    environment[key] = value
                }
            }
            if index < count {
                index += 1 // consume NUL terminator
            }
        }

        return (execPath, arguments, environment)
    }

    /// Checks whether a local TCP port is actively accepting connections using non-blocking POSIX sockets.
    public func isLocalPortListening(host: String = "127.0.0.1", port: Int, timeout: TimeInterval = 0.5) -> Bool {
        guard port > 0 && port <= Int(UInt16.max) else { return false }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPtr: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resultPtr)
        guard status == 0, let firstAddr = resultPtr else {
            return false
        }
        defer { freeaddrinfo(firstAddr) }

        var current: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let addrInfo = current {
            let sock = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
            if sock >= 0 {
                defer { close(sock) }
                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

                let connectResult = connect(sock, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
                if connectResult == 0 {
                    return true
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                    let timeoutMs = Int32(max(10, Int(timeout * 1000)))
                    let pollResult = poll(&pfd, 1, timeoutMs)
                    if pollResult > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                        var soError: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 && soError == 0 {
                            return true
                        }
                    }
                }
            }
            current = addrInfo.pointee.ai_next
        }

        return false
    }

    /// Converts Darwin `TSI_S_*` TCP socket states into human-readable state names.
    public static func tcpStateName(_ state: Int32) -> String {
        switch state {
        case TSI_S_CLOSED: return "CLOSED"
        case TSI_S_LISTEN: return "LISTEN"
        case TSI_S_SYN_SENT: return "SYN_SENT"
        case TSI_S_SYN_RECEIVED: return "SYN_RECEIVED"
        case TSI_S_ESTABLISHED: return "ESTABLISHED"
        case TSI_S__CLOSE_WAIT: return "CLOSE_WAIT"
        case TSI_S_FIN_WAIT_1: return "FIN_WAIT_1"
        case TSI_S_CLOSING: return "CLOSING"
        case TSI_S_LAST_ACK: return "LAST_ACK"
        case TSI_S_FIN_WAIT_2: return "FIN_WAIT_2"
        case TSI_S_TIME_WAIT: return "TIME_WAIT"
        default: return "UNKNOWN(\(state))"
        }
    }

    private static func formatIPv4(_ addr: in_addr) -> String {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "0.0.0.0"
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func formatIPv6(_ addr: in6_addr) -> String {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &copy, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return "::"
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
