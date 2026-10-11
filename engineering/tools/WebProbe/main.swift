import Foundation
import Darwin
import Dispatch

// Standalone G0a HTTP/IP diagnostics. No PadInk modules or system-setting writes.
let maxConnections = 16
let maxHeaderBytes = 8 * 1024
let connectionSeconds = 5
let maxRequests = 500
let maxLifetimeSeconds = 30 * 60

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

func socketError(_ operation: String) -> String {
    "\(operation): errno=\(errno) \(String(cString: strerror(errno)))"
}

struct Options {
    var port: UInt16 = 42379
    var page: String?
    var lifetime = maxLifetimeSeconds
    var addressesOnly = false

    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--addresses" { addressesOnly = true; continue }
            guard !args.isEmpty else { throw ProbeError.message("missing value for \(key)") }
            let value = args.removeFirst()
            switch key {
            case "--port":
                guard let n = UInt16(value), n >= 1024 else {
                    throw ProbeError.message("port must be 1024...65535")
                }
                port = n
            case "--page": page = value
            case "--lifetime-seconds":
                guard let n = Int(value), (1...maxLifetimeSeconds).contains(n) else {
                    throw ProbeError.message("lifetime must be 1...1800 seconds")
                }
                lifetime = n
            default: throw ProbeError.message("unknown argument \(key)")
            }
        }
        if !addressesOnly && page == nil {
            throw ProbeError.message("usage: WebProbe --port 42379 --page /absolute/index.html [--lifetime-seconds 1800]; or --addresses")
        }
    }
}

enum ProbeError: Error { case message(String) }

struct LocalAddress {
    let name: String
    let family: String
    let host: String
}

func numericEndpoint(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> (host: String, port: String)? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
    guard getnameinfo(address, length, &host, socklen_t(host.count), &port,
                      socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV) == 0 else { return nil }
    return (String(cString: host), String(cString: port))
}

func localAddresses() -> [LocalAddress] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let initial = first else { return [] }
    defer { freeifaddrs(first) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = initial
    var result: [LocalAddress] = []
    while let p = cursor, result.count < 64 {
        defer { cursor = p.pointee.ifa_next }
        let entry = p.pointee
        guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr else { continue }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6,
              let endpoint = numericEndpoint(address, length: socklen_t(address.pointee.sa_len)) else { continue }
        result.append(LocalAddress(name: String(cString: entry.ifa_name),
                                   family: family == AF_INET ? "IPv4" : "IPv6", host: endpoint.host))
    }
    return result
}

func printAddresses(port: UInt16, runID: String) {
    log("ADDRESSES runID=\(runID) evidence=local-address-ownership-only route=unknown")
    let addresses = localAddresses()
    if addresses.isEmpty { log("ADDRESS unknown (no readable UP IP addresses)") }
    for a in addresses {
        let host = a.family == "IPv6" ? "[\(a.host.replacingOccurrences(of: "%", with: "%25"))]" : a.host
        log("ADDRESS interface=\(a.name) family=\(a.family) host=\(a.host) url=http://\(host):\(port)/")
    }
}

func describeEndpoint(fd: Int32, peer: Bool) -> (host: String, display: String) {
    var address = sockaddr_storage()
    var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let status = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            peer ? getpeername(fd, $0, &size) : getsockname(fd, $0, &size)
        }
    }
    guard status == 0 else { return ("unknown", "unknown") }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            guard let e = numericEndpoint($0, length: size) else { return ("unknown", "unknown") }
            let host = e.host.contains(":") ? "[\(e.host)]" : e.host
            return (e.host, "\(host):\(e.port)")
        }
    }
}

func configureSocket(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        throw ProbeError.message(socketError("fcntl"))
    }
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
        throw ProbeError.message(socketError("SO_NOSIGPIPE"))
    }
}

func makeListener(family: Int32, port: UInt16) throws -> Int32 {
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProbeError.message(socketError("socket")) }
    do {
        try configureSocket(fd)
        // No SO_REUSEPORT: a second process must fail, never share this port.
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw ProbeError.message(socketError("SO_REUSEADDR"))
        }
        let bound: Int32
        if family == AF_INET6 {
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw ProbeError.message(socketError("IPV6_V6ONLY"))
            }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0 else { throw ProbeError.message(socketError("bind family=\(family) port=\(port)")) }
        guard listen(fd, Int32(maxConnections)) == 0 else { throw ProbeError.message(socketError("listen")) }
        return fd
    } catch { close(fd); throw error }
}

final class Client {
    let fd: Int32
    let local: (host: String, display: String)
    let remote: (host: String, display: String)
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var timer: DispatchSourceTimer?
    var input = Data()
    var output = Data()
    var written = 0
    var responding = false
    var closed = false
    var finalRequest = false
    var descriptorSources = 0
    init(fd: Int32) {
        self.fd = fd
        local = describeEndpoint(fd: fd, peer: false)
        remote = describeEndpoint(fd: fd, peer: true)
    }
}

final class Probe {
    let options: Options
    let runID = UUID().uuidString.lowercased()
    let queue = DispatchQueue(label: "PadInk.G0a.WebProbe")
    let html: Data
    var listeners: [Int32: DispatchSourceRead] = [:]
    var clients: [Int32: Client] = [:]
    var signals: [DispatchSourceSignal] = []
    var lifetime: DispatchSourceTimer?
    var count = 0
    var stopping = false
    var limitReached = false
    var rejectedConnections = 0
    var stopReason = ""
    var stopCode: Int32 = 0

    init(options: Options) throws {
        self.options = options
        guard let path = options.page, path.hasPrefix("/") else { throw ProbeError.message("--page must be absolute") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProbeError.message("page must be a regular file <=64 KiB")
        }
        let source = try String(contentsOfFile: path, encoding: .utf8)
        guard source.contains("__PADINK_RUN_ID__") else { throw ProbeError.message("page runID template missing") }
        html = Data(source.replacingOccurrences(of: "__PADINK_RUN_ID__", with: runID)
            .replacingOccurrences(of: "__PADINK_PID__", with: String(getpid()))
            .replacingOccurrences(of: "__PADINK_PORT__", with: String(options.port)).utf8)
    }

    func start() throws {
        log("START pid=\(getpid()) runID=\(runID) port=\(options.port) bind=IPv4:0.0.0.0,IPv6:[::] v6only=true")
        var opened: [Int32] = []
        do {
            opened.append(try makeListener(family: AF_INET, port: options.port))
            opened.append(try makeListener(family: AF_INET6, port: options.port))
        } catch {
            for fd in opened { close(fd) }
            log("LISTENER_ERROR runID=\(runID) \(error)")
            throw error
        }
        for fd in opened {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(listener: fd) }
            source.setCancelHandler { [weak self] in
                close(fd)
                self?.listeners.removeValue(forKey: fd)
                self?.completeStopIfReady()
            }
            listeners[fd] = source
            source.resume()
        }
        for number in [SIGINT, SIGTERM, SIGUSR1] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if number == SIGUSR1 { printAddresses(port: self.options.port, runID: self.runID) }
                else { self.stop(reason: "signal=\(number)", code: 0) }
            }
            signals.append(source)
            source.resume()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(options.lifetime))
        timer.setEventHandler { [weak self] in self?.stop(reason: "lifetime-limit", code: 0) }
        lifetime = timer
        timer.resume()
        log("READY pid=\(getpid()) runID=\(runID) port=\(options.port) bind=IPv4:0.0.0.0,IPv6:[::] v6only=true")
        log("LIMITS connections=16 headerBytes=8192 connectionSeconds=5 requests=500 lifetimeSeconds=\(options.lifetime)")
        printAddresses(port: options.port, runID: runID)
    }

    func closeListeners() {
        for source in listeners.values { source.cancel() }
    }

    func stop(reason: String, code: Int32) {
        guard !stopping else { return }
        stopping = true
        stopReason = reason
        stopCode = code
        closeListeners()
        for client in Array(clients.values) { finish(client) }
        lifetime?.cancel()
        for source in signals { source.cancel() }
        completeStopIfReady()
    }

    func completeStopIfReady() {
        guard stopping, listeners.isEmpty, clients.isEmpty else { return }
        log("STOP pid=\(getpid()) runID=\(runID) reason=\(stopReason) requests=\(count) rejectedConnections=\(rejectedConnections) listeners=0 connections=0")
        exit(stopCode)
    }

    func acceptClients(listener: Int32) {
        guard !stopping, !limitReached, listeners[listener] != nil else { return }
        // Bound each event's accept work as well as persistent open connections.
        for _ in 0..<32 {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                stop(reason: socketError("listener accept"), code: 1)
                return
            }
            guard clients.count < maxConnections else {
                rejectedConnections += 1
                close(fd)
                if rejectedConnections <= 3 { log("REJECT connection-limit active=\(clients.count)") }
                continue
            }
            do { try configureSocket(fd) }
            catch { close(fd); log("CONNECTION_ERROR \(error)"); continue }
            let client = Client(fd: fd)
            clients[fd] = client
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            client.descriptorSources += 1
            reader.setEventHandler { [weak self, weak client] in
                if let client { self?.receive(client) }
            }
            reader.setCancelHandler { [weak self, weak client] in
                if let client { self?.descriptorSourceCancelled(client) }
            }
            client.reader = reader
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(connectionSeconds))
            timer.setEventHandler { [weak self, weak client] in
                guard let self, let client, !client.closed else { return }
                log("CLOSE connection-timeout local=\(client.local.display) remote=\(client.remote.display)")
                self.finish(client)
            }
            client.timer = timer
            reader.resume()
            timer.resume()
        }
    }

    func finish(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        client.reader?.cancel()
        client.writer?.cancel()
        client.timer?.cancel()
        // Stop IO immediately, but only close after BOTH Dispatch IO sources
        // have relinquished the descriptor. This prevents fd reuse races.
        shutdown(client.fd, SHUT_RDWR)
    }

    func descriptorSourceCancelled(_ client: Client) {
        client.descriptorSources -= 1
        guard client.closed, client.descriptorSources == 0 else { return }
        close(client.fd)
        clients.removeValue(forKey: client.fd)
        if client.finalRequest && !stopping { stop(reason: "request-limit", code: 0) }
        else { completeStopIfReady() }
    }

    func receive(_ client: Client) {
        guard !client.closed, !client.responding, !stopping else { return }
        var bytes = [UInt8](repeating: 0, count: maxHeaderBytes + 1 - client.input.count)
        let received = recv(client.fd, &bytes, bytes.count, 0)
        if received == 0 { finish(client); return }
        if received < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finish(client) }
            return
        }
        client.input.append(contentsOf: bytes.prefix(received))
        let terminator = Data([13, 10, 13, 10])
        if let boundary = client.input.range(of: terminator) {
            if boundary.upperBound > maxHeaderBytes { handle(client, failure: 431); return }
            let header = client.input.prefix(boundary.lowerBound)
            // Bytes after the single header (body or pipeline) are rejected.
            guard boundary.upperBound == client.input.count else { handle(client, failure: 400); return }
            handle(client, header: Data(header))
        } else if client.input.count > maxHeaderBytes { handle(client, failure: 431) }
    }

    func handle(_ client: Client, header: Data? = nil, failure: Int? = nil) {
        guard !limitReached else { finish(client); return }
        count += 1
        client.finalRequest = count == maxRequests
        if client.finalRequest { limitReached = true; closeListeners() }
        client.responding = true
        client.reader?.cancel()
        if let failure { respond(client, status: failure, object: ["error": "request rejected"]); return }
        guard let header, header.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 10 || (32...126).contains($0) }),
              let text = String(data: header, encoding: .ascii) else {
            respond(client, status: 400, object: ["error": "invalid header"]); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").components(separatedBy: " ")
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(first[2]) else {
            respond(client, status: 400, object: ["error": "invalid request line"]); return
        }
        guard first[0] == "GET" else { respond(client, status: 405, object: ["error": "GET only"]); return }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                respond(client, status: 400, object: ["error": "invalid field"]); return
            }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), fields[name] == nil else {
                respond(client, status: 400, object: ["error": "duplicate or invalid field"]); return
            }
            fields[name] = value
        }
        guard fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else {
            respond(client, status: 400, object: ["error": "body not supported"]); return
        }
        let target = first[1]
        if target == "/" {
            respond(client, status: 200, body: html, type: "text/html; charset=utf-8")
            return
        }
        guard target.hasPrefix("/probe?"), target.utf8.count <= 256,
              let components = URLComponents(string: target), components.path == "/probe", components.fragment == nil,
              let items = components.queryItems, items.count == 3 else {
            respond(client, status: 404, object: ["error": "fixed routes only"]); return
        }
        var query: [String: String] = [:]
        for item in items {
            guard query[item.name] == nil, let value = item.value else {
                respond(client, status: 400, object: ["error": "invalid query"]); return
            }
            query[item.name] = value
        }
        guard let nonce = query["nonce"], (1...96).contains(nonce.utf8.count),
              nonce.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let phase = query["phase"], ["pre", "usb", "post", "exit"].contains(phase),
              let expected = query["runID"], UUID(uuidString: expected) != nil else {
            respond(client, status: 400, object: ["error": "invalid nonce/runID/phase"]); return
        }
        guard expected == runID else {
            respond(client, status: 409, object: ["error": "runID changed; restart the whole experiment", "nonce": nonce]); return
        }
        let matches = localAddresses().filter { $0.host.components(separatedBy: "%")[0] == client.local.host.components(separatedBy: "%")[0] }
        let evidence: [String: Any] = ["meaning": "local-address-ownership-only; transport-route-unknown",
                                      "matchingInterfaces": matches.map { ["name": $0.name, "family": $0.family, "address": $0.host] }]
        log("REQUEST runID=\(runID) count=\(count) phase=\(phase) nonce=\(nonce) local=\(client.local.display) remote=\(client.remote.display) candidates=\(matches.map(\.name).joined(separator: ",")) route=unknown")
        respond(client, status: 200, object: ["nonce": nonce, "localEndpoint": client.local.display,
                                            "remoteEndpoint": client.remote.display, "interfaceEvidence": evidence])
    }

    func respond(_ client: Client, status: Int, object: [String: Any]) {
        var payload = object
        payload["runID"] = runID
        payload["count"] = count
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(client, status: status, body: body, type: "application/json; charset=utf-8")
    }

    func respond(_ client: Client, status: Int, body: Data, type: String) {
        let phrase = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 431: "Request Header Fields Too Large"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nExpires: 0\r\nConnection: close\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        client.input.removeAll(keepingCapacity: false)
        client.output = Data(header.utf8)
        client.output.append(body)
        let writer = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        client.descriptorSources += 1
        writer.setEventHandler { [weak self, weak client] in
            if let client { self?.sendResponse(client) }
        }
        writer.setCancelHandler { [weak self, weak client] in
            if let client { self?.descriptorSourceCancelled(client) }
        }
        client.writer = writer
        writer.resume()
    }

    func sendResponse(_ client: Client) {
        guard !client.closed, !stopping else { return }
        let sent = client.output.withUnsafeBytes { buffer in
            send(client.fd, buffer.baseAddress!.advanced(by: client.written), buffer.count - client.written, 0)
        }
        if sent > 0 { client.written += sent }
        else if sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finish(client); return }
        if client.written == client.output.count { finish(client) }
    }
}

do {
    let options = try Options()
    if options.addressesOnly {
        printAddresses(port: options.port, runID: "not-running")
        exit(0)
    }
    let probe = try Probe(options: options)
    try probe.queue.sync { try probe.start() }
    withExtendedLifetime(probe) { dispatchMain() }
} catch {
    log("ERROR \(error)")
    exit(1)
}
