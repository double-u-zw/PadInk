import Foundation
import Darwin
import dnssd

// These tests only call the real, separately compiled G0a executable. No replacement
// HTTP implementation, simulated physical interface, system cache flush or packet capture.
func runSelftests(_ options: Arguments) throws {
    let runtime = try runtimeDirectory(root: options.runtimeRoot)
    var passed = 0
    func pass(_ name: String) { passed += 1; print("SELFTEST_PASS \(name)"); fflush(stdout) }
    func rejects(_ name: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, "selftest expected rejection: \(name)"); pass(name)
    }
    func privateDirectory(_ name: String) throws -> String {
        let path = runtime + "/" + name
        try require(mkdir(path, 0o700) == 0, "fixture mkdir failed"); return path
    }
    func fixture(_ name: String, _ text: String) throws -> String {
        let dir = try privateDirectory(name)
        let fd = open(dir + "/name.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "fixture file creation failed"); defer { close(fd) }
        let data = Data(text.utf8)
        try require(data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } == data.count, "fixture write failed")
        return dir
    }
    func portReleased() throws {
        let output = try commandOutput("/usr/sbin/lsof", ["-nP", "-iTCP:42379", "-sTCP:LISTEN"], allowedStatuses: [0, 1])
        try require(output.isEmpty, "test port still has a listener")
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            try require(fd >= 0, "release-check socket failed"); defer { close(fd) }
            var result: Int32 = -1
            if family == AF_INET {
                var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(42379).bigEndian
                _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
                result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = UInt16(42379).bigEndian
                _ = inet_pton(AF_INET6, "::1", &a.sin6_addr)
                result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            try require(result == -1 && errno == ECONNREFUSED, "expected IPv\(family == AF_INET ? 4 : 6) connection refusal")
        }
    }
    print("SELFTEST_START runtime=\(runtime) physicalUSBAndNameResolution=NOT_TESTED")
    try portReleased()
    let vpn = try connectedVPN(); pass("VPN_connected_read_only")
    let fixed = try NameConfiguration.loadOrCreate(directory: NameConfiguration.directory)
    let saved = try Data(contentsOf: URL(fileURLWithPath: NameConfiguration.directory + "/name.json"))
    try require(try NameConfiguration.loadOrCreate(directory: NameConfiguration.directory) == fixed, "persistent name changed")
    try require(try Data(contentsOf: URL(fileURLWithPath: NameConfiguration.directory + "/name.json")) == saved, "valid configuration rewritten")
    pass("persistent_configuration_created_or_reused_without_rewrite")
    print("FIXED_NAME name=\(fixed.name) config=\(NameConfiguration.directory)/name.json")
    let configDir = try privateDirectory("session-config")
    let testName = try NameConfiguration.loadOrCreate(directory: configDir)
    try require(testName.name != fixed.name, "selftest name must be separate from device name")
    let bad = try fixture("bad-json", "{broken")
    try rejects("malformed_configuration_rejected") { _ = try NameConfiguration.loadOrCreate(directory: bad) }
    try require(try String(contentsOfFile: bad + "/name.json", encoding: .utf8) == "{broken", "invalid config overwritten")
    pass("malformed_configuration_preserved")
    let unknown = try fixture("unknown-fields", "{\"version\":1,\"name\":\"\(testName.name)\",\"extra\":true}")
    try rejects("unknown_configuration_fields_rejected") { _ = try NameConfiguration.loadOrCreate(directory: unknown) }
    let version = try fixture("wrong-version", "{\"version\":2,\"name\":\"\(testName.name)\"}")
    try rejects("unsupported_configuration_version_rejected") { _ = try NameConfiguration.loadOrCreate(directory: version) }
    let duplicate = try fixture("duplicate-key", "{\"version\":1,\"name\":\"\(testName.name)\",\"name\":\"\(testName.name)\"}")
    try rejects("ambiguous_duplicate_configuration_key_rejected") { _ = try NameConfiguration.loadOrCreate(directory: duplicate) }
    let mode = try fixture("wrong-mode", "{\"version\":1,\"name\":\"\(testName.name)\"}")
    chmod(mode + "/name.json", 0o644)
    try rejects("unsafe_configuration_mode_rejected") { _ = try NameConfiguration.loadOrCreate(directory: mode) }
    let linkDir = try privateDirectory("symlink-file")
    try require(symlink(configDir + "/name.json", linkDir + "/name.json") == 0, "fixture symlink failed")
    try rejects("configuration_symlink_rejected") { _ = try NameConfiguration.loadOrCreate(directory: linkDir) }
    let link = runtime + "/symlink-directory"
    try require(symlink(configDir, link) == 0, "fixture directory symlink failed")
    try rejects("directory_symlink_rejected") { _ = try NameConfiguration.loadOrCreate(directory: link) }
    let fifoDir = try privateDirectory("fifo-file")
    try require(mkfifo(fifoDir + "/name.json", 0o600) == 0, "fixture FIFO creation failed")
    try rejects("configuration_FIFO_rejected_without_opening") { _ = try NameConfiguration.loadOrCreate(directory: fifoDir) }
    let hardSource = try fixture("hard-source", "{\"version\":1,\"name\":\"\(testName.name)\"}")
    let hardDir = try privateDirectory("hard-link")
    try require(Darwin.link(hardSource + "/name.json", hardDir + "/name.json") == 0, "fixture hardlink failed")
    try rejects("configuration_hardlink_rejected") { _ = try NameConfiguration.loadOrCreate(directory: hardDir) }
    let unsafeDir = try privateDirectory("unsafe-directory")
    try require(chmod(unsafeDir, 0o755) == 0, "fixture directory chmod failed")
    try rejects("unsafe_directory_mode_rejected_without_repair") { _ = try NameConfiguration.loadOrCreate(directory: unsafeDir) }

    guard let actual = try usbAddress() else { throw CheckError.failed("real DNS callback selftest requires connected iPad USB NCM IPv4") }
    print("SELFTEST_INTERFACE \(actual)")
    var gate = RegistrationGate(); gate.replace(with: actual)
    let old = gate.generation
    try require(gate.accept(RegistrationEvent(generation: old, error: 0)) && gate.ready, "gate ready failed")
    let changed = USBAddress(name: actual.name, index: actual.index, registryID: actual.registryID, provider: actual.provider, ipv4: "192.0.2.1")
    gate.replace(with: changed)
    try require(!gate.accept(RegistrationEvent(generation: old, error: 0)) && !gate.ready, "old address callback accepted")
    pass("LOGIC_ONLY_address_change_retires_old_generation")
    let reattached = USBAddress(name: actual.name, index: actual.index + 1, registryID: actual.registryID + 1, provider: actual.provider, ipv4: actual.ipv4)
    let previous = gate.generation; gate.replace(with: reattached)
    try require(!gate.accept(RegistrationEvent(generation: previous, error: 0)), "old interface callback accepted")
    pass("LOGIC_ONLY_interface_identity_and_index_change")
    try require(gate.accept(RegistrationEvent(generation: gate.generation, error: DNSServiceErrorType(kDNSServiceErr_NameConflict))) && !gate.ready,
                "name conflict was accepted as ready")
    pass("LOGIC_ONLY_name_conflict_and_callback_error")
    let retired = gate.generation; gate.replace(with: nil)
    try require(!gate.accept(RegistrationEvent(generation: retired, error: 0)) && !gate.ready, "retired callback restored readiness")
    pass("LOGIC_ONLY_disconnect_and_late_callback_isolation")

    func waitCallback(_ registration: DNSRegistration) throws -> DNSServiceErrorType {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            var fd = pollfd(fd: registration.fd, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 100) > 0 {
                if let event = try registration.process().first { return event.error }
            }
        }
        throw CheckError.failed("real DNS callback did not arrive")
    }
    do {
        let registration = try DNSRegistration(name: testName.name, address: actual, generation: 1)
        defer { registration.close() }
        let error = try waitCallback(registration)
        try require(error == 0, "real DNS callback error=\(error)")
        pass("REAL_DNS_registration_callback_success_on_verified_USB")
        registration.close()
        try require(registration.fd == -1 && registration.reference == nil, "DNS reference not cleared")
        pass("REAL_DNS_reference_deallocation")
    }
    var realError = ""
    do {
        let registration = try DNSRegistration(name: testName.name, address: actual, generation: 2, malformedForSelftest: true)
        defer { registration.close() }
        let error = try waitCallback(registration)
        try require(error != 0, "malformed A record unexpectedly accepted")
        realError = "callback=\(error)"
    } catch {
        let message = String(describing: error)
        guard message.contains("DNSServiceRegisterRecord error=") else { throw error }
        realError = message
    }
    pass("REAL_DNS_bad_record_rejected \(realError)")

    var sessions = [(Process, String)]()
    defer {
        for (task, _) in sessions where task.isRunning {
            kill(task.processIdentifier, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
        }
    }
    func launch(_ label: String, seconds: Int = 20) throws -> (Process, String) {
        let task = Process(); let path = runtime + "/" + label + ".log"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        try require(fd >= 0, "integration log creation failed")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = ["--http-executable", options.httpExecutable, "--page", options.page,
                          "--lifetime-seconds", String(seconds), "--runtime-root", runtime,
                          "--selftest-fixture", configDir]
        var environment = ProcessInfo.processInfo.environment
        environment["PADINK_NAMECHECK_SELFTEST"] = "1"; task.environment = environment
        task.standardOutput = handle; task.standardError = handle; task.standardInput = FileHandle.nullDevice
        try task.run(); sessions.append((task, path)); try handle.close()
        return (task, path)
    }
    func contents(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    func awaitReady(_ task: Process, _ path: String) throws -> (String, Int32) {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let text = try contents(path)
            if let line = text.split(separator: "\n").first(where: { $0.contains(" NAME_READY ") }),
               let id = value("runID", in: String(line)),
               let childLine = text.split(separator: "\n").first(where: { $0.contains(" HTTP_CHILD ") }),
               let pid = value("pid", in: String(childLine)).flatMap(Int32.init) { return (id, pid) }
            usleep(20_000)
        }
        throw CheckError.failed("integration READY failed; see \(path)")
    }
    func awaitStop(_ task: Process, _ path: String, seconds: Double = 7, checkPort: Bool = true) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        try require(!task.isRunning, "supervisor did not stop")
        task.waitUntilExit()
        let text = try contents(path)
        try require((text.contains("childReaped=true") || text.contains("childStarted=false")) && text.contains("registrations=0"), "cleanup not confirmed")
        if checkPort { try portReleased() }
        return text
    }
    let (abnormal, abnormalLog) = try launch("child-abnormal")
    let (oldRun, childPID) = try awaitReady(abnormal, abnormalLog)
    let url = "http://127.0.0.1:42379/probe?runID=\(oldRun)&nonce=local-selftest-1&phase=pre"
    let echo = try commandOutput("/usr/bin/curl", ["--noproxy", "*", "-sS", "--max-time", "1", url])
    let json = try JSONSerialization.jsonObject(with: Data(echo.utf8)) as? [String: Any]
    try require(json?["runID"] as? String == oldRun && json?["nonce"] as? String == "local-selftest-1", "real G0a echo mismatch")
    pass("REAL_HTTP_original_G0a_entrypoint_nonce_echo_loopback_only")
    kill(childPID, SIGKILL)
    let abnormalText = try awaitStop(abnormal, abnormalLog)
    try require(abnormal.terminationStatus != 0 && abnormalText.contains("reason=http-child-exit") && abnormalText.contains("DNS_RELEASED"), "child abnormal exit not handled")
    pass("REAL_PROCESS_abnormal_HTTP_child_retires_DNS_and_releases_both_ports")

    let (interrupt, interruptLog) = try launch("interrupt")
    let (newRun, _) = try awaitReady(interrupt, interruptLog)
    try require(newRun != oldRun && (try contents(interruptLog)).contains("name=\(testName.name)"), "restart did not preserve name/change runID")
    let stale = try commandOutput("/usr/bin/curl", ["--noproxy", "*", "-sS", "--max-time", "1", "-w", "\n%{http_code}", url])
    try require(stale.hasSuffix("409") && stale.contains("runID changed"), "old run accepted after restart")
    pass("REAL_PROCESS_restart_same_name_new_runID_rejects_old_run")
    kill(interrupt.processIdentifier, SIGINT)
    let interruptText = try awaitStop(interrupt, interruptLog)
    try require(interrupt.terminationStatus == 0 && interruptText.contains("reason=signal-2") && interruptText.contains("DNS_RELEASED"), "SIGINT cleanup failed")
    pass("REAL_PROCESS_SIGINT_cleanup_and_IPv4_IPv6_port_release")

    let (terminate, terminateLog) = try launch("terminate")
    _ = try awaitReady(terminate, terminateLog)
    kill(terminate.processIdentifier, SIGTERM)
    let terminateText = try awaitStop(terminate, terminateLog)
    try require(terminate.terminationStatus == 0 && terminateText.contains("reason=signal-15"), "SIGTERM cleanup failed")
    pass("REAL_PROCESS_SIGTERM_cleanup_and_port_release")

    let (expiry, expiryLog) = try launch("deadline", seconds: 3)
    let expiryText = try awaitStop(expiry, expiryLog)
    try require(expiry.terminationStatus == 0 && expiryText.contains("reason=deadline"), "deadline cleanup failed")
    pass("REAL_PROCESS_deadline_cleanup_and_port_release")

    var blocker = socket(AF_INET, SOCK_STREAM, 0)
    try require(blocker >= 0, "conflict fixture socket failed")
    defer { if blocker >= 0 { close(blocker) } }
    _ = fcntl(blocker, F_SETFD, FD_CLOEXEC)
    var reuse: Int32 = 1
    try require(setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0,
                "cannot configure conflict fixture")
    var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(42379).bigEndian
    _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
    let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    try require(bound == 0, "cannot create occupied-port fixture")
    try require(listen(blocker, 1) == 0, "cannot listen on occupied-port fixture")
    let (conflict, conflictLog) = try launch("port-conflict")
    let conflictText = try awaitStop(conflict, conflictLog, checkPort: false)
    try require(conflict.terminationStatus != 0 && !conflictText.contains("DNS_SUBMITTED") && conflictText.contains("reason=port-in-use") && conflictText.contains("childStarted=false"), "port conflict was not fail closed")
    try require(fcntl(blocker, F_GETFD) >= 0, "supervisor closed a socket it did not own")
    close(blocker); blocker = -1
    try portReleased()
    pass("REAL_PROCESS_port_conflict_no_registration_no_fallback")
    try require(try connectedVPN() == vpn, "VPN state changed during selftest")
    pass("VPN_still_connected")
    print("SELFTEST_DONE passed=\(passed) failed=0 deviceName=\(fixed.name) physicalPlugAndIPAddressChange=NOT_EXERCISED browserNameResolution=NOT_TESTED runtime=\(runtime)")
}
