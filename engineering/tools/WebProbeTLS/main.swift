import Foundation
import Darwin

var receivedSignal: Int32 = 0

struct Arguments {
    var httpExecutable = ""
    var page = ""
    var lifetime: Double = 1800
    var runtimeRoot: String?
    var selftest = false
    var fixture: String?
    init(_ input: [String]) throws {
        var args = input
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--selftest" { selftest = true; continue }
            try require(!args.isEmpty, "missing value for \(key)")
            let value = args.removeFirst()
            switch key {
            case "--http-executable": httpExecutable = value
            case "--page": page = value
            case "--lifetime-seconds":
                guard let n = Double(value), n >= 1, n <= 1800, n.rounded() == n else {
                    throw CheckError.failed("lifetime must be 1...1800 whole seconds")
                }
                lifetime = n
            case "--runtime-root": runtimeRoot = value
            case "--selftest-fixture": fixture = value
            default: throw CheckError.failed("unknown argument \(key)")
            }
        }
        try require(httpExecutable.hasPrefix("/") && page.hasPrefix("/"),
                    "usage: --http-executable /compiled/WebProbe --page /original/index.html [--lifetime-seconds 1...1800] [--runtime-root /private/directory] [--selftest]")
        for path in [httpExecutable, page] {
            var info = stat()
            try require(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG,
                        "expected regular non-symlink input file: \(path)")
        }
        try require(access(httpExecutable, X_OK) == 0, "HTTP binary is not executable")
        if let fixture {
            try require(ProcessInfo.processInfo.environment["PADINK_NAMECHECK_SELFTEST"] == "1" &&
                        runtimeRoot.map { fixture.hasPrefix($0 + "/") } == true,
                        "fixture configuration is allowed only under the selftest runtime root")
        }
    }
}

func runtimeDirectory(root: String?) throws -> String {
    if let root { let fd = try checkedDirectory(root); close(fd) }
    var template = Array(((root ?? "/private/tmp") + "/padink-name-run-XXXXXXXX").utf8CString)
    guard let p = mkdtemp(&template) else { throw CheckError.failed("cannot create private runtime directory") }
    return String(cString: p)
}

final class BoundedLog {
    let fd: Int32
    var bytes = 0
    private(set) var full = false
    private let limit = 256 * 1024
    init(runtime: String) throws {
        fd = open(runtime + "/namecheck.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "cannot create exclusive log")
    }
    func line(_ text: String) {
        guard !full else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = timestamp + " " + text + "\n"
        let data = Data(line.utf8)
        if bytes + data.count > limit { full = true; return }
        bytes += data.count
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { full = true; return }
            offset += n
        }
        print(line, terminator: ""); fflush(stdout)
    }
    deinit { close(fd) }
}

// Bounded local read-only system command. No shell or configuration mutation.
func commandOutput(_ executable: String, _ args: [String], allowedStatuses: Set<Int32> = [0]) throws -> String {
    let task = Process(); let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: executable); task.arguments = args
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    try task.run(); try pipe.fileHandleForWriting.close()
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
    if task.isRunning {
        kill(task.processIdentifier, SIGKILL); task.waitUntilExit()
        throw CheckError.failed("local status command timed out")
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    try require(data.count <= 16384 && allowedStatuses.contains(task.terminationStatus), "local status command failed or exceeded limit")
    return String(decoding: data, as: UTF8.self)
}

func connectedVPN() throws -> String {
    let output = try commandOutput("/usr/sbin/scutil", ["--nc", "list"])
    let lines = output.split(separator: "\n").filter { $0.contains("(Connected)") }
    try require(lines.count == 1, "expected one connected VPN; cannot confirm required VPN state")
    let ids = lines[0].split(separator: " ").filter { UUID(uuidString: String($0)) != nil }
    try require(ids.count == 1, "cannot identify connected VPN")
    return String(ids[0])
}

func value(_ key: String, in line: String) -> String? {
    line.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}

func listenerOwners() throws -> Set<Int32> {
    let output = try commandOutput("/usr/sbin/lsof", ["-t", "-nP", "-iTCP:42379", "-sTCP:LISTEN"], allowedStatuses: [0, 1])
    let lines = output.split(separator: "\n")
    let pids = lines.compactMap { Int32($0) }
    try require(pids.count == lines.count, "cannot interpret listener ownership")
    return Set(pids)
}

func runSession(_ options: Arguments) throws -> Int32 {
    let runtime = try runtimeDirectory(root: options.runtimeRoot)
    let logger = try BoundedLog(runtime: runtime)
    let directory = options.fixture ?? NameConfiguration.directory
    let config = try NameConfiguration.loadOrCreate(directory: directory)
    let vpn = try connectedVPN()
    let initial = try usbAddress()
    try require(initial != nil, "no verified active iPad USB NCM IPv4 interface; no service started")
    if try !listenerOwners().isEmpty {
        logger.line("STOP reason=port-in-use registrations=0 childStarted=false name=\(config.name)")
        return 1
    }
    let child = Process(); let pipe = Pipe()
    child.executableURL = URL(fileURLWithPath: options.httpExecutable)
    child.arguments = ["--port", "42379", "--page", options.page, "--lifetime-seconds", String(Int(options.lifetime))]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = pipe
    signal(SIGPIPE, SIG_IGN)
    signal(SIGINT) { receivedSignal = $0 }; signal(SIGTERM) { receivedSignal = $0 }
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = started + options.lifetime
    logger.line("SESSION supervisorPID=\(getpid()) name=\(config.name) config=\(directory)/name.json port=42379 expiresAt=\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(options.lifetime))) runtime=\(runtime)")
    logger.line("VPN_CONFIRMED id=\(vpn) state=Connected")
    try child.run(); try? pipe.fileHandleForWriting.close()
    let out = pipe.fileHandleForReading.fileDescriptor
    logger.line("HTTP_CHILD pid=\(child.processIdentifier) executable=\(options.httpExecutable) port=42379")
    var registration: DNSRegistration?
    var gate = RegistrationGate()
    var buffer = Data()
    var httpReady = false
    var runID = "pending"
    var nextInventory = started
    var nextVPN = started + 5
    var registrationStarted: Double = 0
    var reason = "unknown"
    var exitCode: Int32 = 0
    var pipeOpen = true
    var reaped = false
    func retire() {
        gate.replace(with: nil)
        if let old = registration {
            logger.line("DNS_RETIRE generation=\(old.generation) \(old.address)")
            old.close(); registration = nil
            logger.line("DNS_RELEASED generation=\(old.generation)")
        }
    }
    // Always run after successful spawn, including an error while starting DNS-SD.
    defer {
        retire()
        if child.isRunning { kill(child.processIdentifier, SIGINT) }
        let stopDeadline = ProcessInfo.processInfo.systemUptime + 3
        while child.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { usleep(10_000) }
        if child.isRunning {
            logger.line("HTTP_FORCE_STOP pid=\(child.processIdentifier)")
            kill(child.processIdentifier, SIGKILL)
        }
        child.waitUntilExit(); reaped = true
        try? pipe.fileHandleForReading.close()
        logger.line("STOP reason=\(reason) exitCode=\(exitCode) runID=\(runID) registrations=0 childPID=\(child.processIdentifier) childReaped=\(reaped) childStatus=\(child.terminationStatus)")
        do {
            let listeners = try commandOutput("/usr/sbin/lsof", ["-nP", "-iTCP:42379", "-sTCP:LISTEN"], allowedStatuses: [0, 1])
            logger.line(listeners.isEmpty ? "PORT_CHECK port=42379 no_listener_reported=true" : "PORT_NOT_RELEASED_OR_OTHER_OWNER port=42379")
        } catch { logger.line("PORT_CHECK_UNKNOWN port=42379 error=\(error)") }
    }
    do {
        try require(fcntl(out, F_SETFL, O_NONBLOCK) == 0, "cannot configure child pipe")
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if receivedSignal != 0 { reason = "signal-\(receivedSignal)"; break }
            if now >= deadline { reason = "deadline"; break }
            if !child.isRunning { reason = "http-child-exit"; exitCode = 1; break }
            if logger.full { throw CheckError.failed("log limit or write failure") }
            if !httpReady && now - started > 5 { throw CheckError.failed("HTTP READY timeout") }
            if now >= nextVPN {
                try require(try connectedVPN() == vpn, "required VPN no longer confirmed connected")
                if httpReady { try require(try listenerOwners() == [child.processIdentifier], "HTTP port has another owner or lost its listener") }
                nextVPN = now + 5
            }
            if httpReady && now >= nextInventory {
                let observed = try usbAddress()
                if observed != gate.current {
                    retire()
                    if let observed {
                        gate.replace(with: observed)
                        logger.line("INTERFACE_VERIFIED generation=\(gate.generation) \(observed)")
                        do {
                            registration = try DNSRegistration(name: config.name, address: observed, generation: gate.generation)
                        } catch {
                            if try usbAddress() != observed {
                                logger.line("USB_CHANGED_DURING_REGISTRATION generation=\(gate.generation)")
                                retire(); nextInventory = 0; continue
                            }
                            throw error
                        }
                        registrationStarted = now
                        logger.line("DNS_SUBMITTED generation=\(gate.generation) name=\(config.name) interfaceIndex=\(observed.index)")
                    } else { logger.line("USB_WAIT no_verified_active_IPv4=true") }
                }
                nextInventory = now + 0.25
            }
            if registration != nil && !gate.ready && now - registrationStarted > 10 {
                throw CheckError.failed("DNS registration callback timeout")
            }
            var fds = [pollfd(fd: pipeOpen ? out : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: registration?.fd ?? -1, events: Int16(POLLIN), revents: 0)]
            let polled = poll(&fds, nfds_t(fds.count), 100)
            if polled < 0 { if errno == EINTR { continue }; throw CheckError.failed("poll failed") }
            if fds[0].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let n = read(out, &bytes, bytes.count)
                if n == 0 { pipeOpen = false }
                else if n > 0 {
                    buffer.append(contentsOf: bytes.prefix(n))
                    while let end = buffer.firstIndex(of: 10) {
                        let data = buffer.prefix(upTo: end)
                        try require(data.count <= 8192, "child output line too long")
                        let line = String(decoding: data, as: UTF8.self)
                        buffer.removeSubrange(...end)
                        logger.line("HTTP " + line)
                        if line.hasPrefix("READY ") {
                            guard !httpReady, value("pid", in: line) == String(child.processIdentifier),
                                  value("port", in: line) == "42379", let id = value("runID", in: line), UUID(uuidString: id) != nil else {
                                throw CheckError.failed("unexpected HTTP READY identity")
                            }
                            try require(try listenerOwners() == [child.processIdentifier], "HTTP READY port ownership mismatch")
                            runID = id; httpReady = true
                            logger.line("HTTP_READY childPID=\(child.processIdentifier) runID=\(runID)")
                        }
                    }
                    try require(buffer.count <= 8192, "unterminated child output exceeds limit")
                } else if errno != EAGAIN && errno != EINTR { throw CheckError.failed("child pipe read failed") }
            }
            if fds[1].revents != 0, let active = registration {
                // Recheck physical identity before processing results from a previously polled fd.
                if try usbAddress() != active.address { retire(); nextInventory = 0; continue }
                for event in try active.process() {
                    guard gate.accept(event) else {
                        logger.line("DNS_STALE_CALLBACK generation=\(event.generation)"); continue
                    }
                    logger.line("DNS_CALLBACK generation=\(event.generation) error=\(event.error)")
                    try require(event.error == 0, "DNS callback failure/name conflict error=\(event.error); name unchanged")
                    logger.line("NAME_READY generation=\(event.generation) runID=\(runID) url=http://\(config.name):42379/ direct=http://\(active.address.ipv4):42379/ \(active.address)")
                }
            }
        }
    } catch {
        reason = "error: \(error)"; exitCode = 1
        logger.line("ERROR \(error)")
    }
    return exitCode
}

do {
    let options = try Arguments(Array(CommandLine.arguments.dropFirst()))
    if options.selftest { try runSelftests(options) }
    else { exit(try runSession(options)) }
} catch {
    fputs("NAMECHECK_ERROR \(error)\n", stderr)
    exit(1)
}
