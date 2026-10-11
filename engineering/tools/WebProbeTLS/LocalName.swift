import Foundation
import Darwin
import IOKit
import dnssd

enum CheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let s) = self { return s }; return "failure" }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.failed(message) }
}

// All filesystem operations below refuse symlinks and existing unexpected objects.
func checkedDirectory(_ path: String, create: Bool = false) throws -> Int32 {
    try require(path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "invalid directory path")
    var current = ""
    let parts = path.split(separator: "/")
    for (i, part) in parts.enumerated() {
        current += "/" + part
        var info = stat()
        if lstat(current, &info) != 0 {
            guard errno == ENOENT, create, i == parts.count - 1 else {
                throw CheckError.failed("directory unavailable: \(current)")
            }
            try require(mkdir(current, 0o700) == 0, "cannot create private directory")
            try require(lstat(current, &info) == 0, "cannot inspect created directory")
        }
        try require(info.st_mode & S_IFMT == S_IFDIR, "non-directory/symlink: \(current)")
        if i == parts.count - 1 {
            try require(info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700,
                        "directory must be owned by current user with mode 0700: \(current)")
        }
    }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "cannot securely open directory")
    return fd
}

struct NameConfiguration: Codable, Equatable {
    let version: Int
    let name: String
    static var directory: String {
        NSHomeDirectory() + "/Library/Application Support/PadInk-WebProbe"
    }
    static func loadOrCreate(directory: String) throws -> NameConfiguration {
        let dir = try checkedDirectory(directory, create: true)
        defer { close(dir) }
        try require(flock(dir, LOCK_EX | LOCK_NB) == 0, "configuration is in use")
        defer { flock(dir, LOCK_UN) }
        var existing = stat()
        if fstatat(dir, "name.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            try require(existing.st_mode & S_IFMT == S_IFREG, "configuration path is not a regular file")
        } else { try require(errno == ENOENT, "cannot inspect configuration path") }
        // NONBLOCK prevents a raced-in FIFO from hanging before the fd is revalidated.
        var fd = openat(dir, "name.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            try require(errno == ENOENT, "configuration path is not a readable regular file")
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
            let config = NameConfiguration(version: 1, name: "padink-\(id).local")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(config); data.append(10)
            fd = openat(dir, "name.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try require(fd >= 0, "configuration appeared concurrently; refusing overwrite")
            defer { close(fd) }
            try require(fchmod(fd, 0o600) == 0, "cannot set configuration permissions")
            var written = 0
            while written < data.count {
                let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: written), data.count - written) }
                if n < 0 && errno == EINTR { continue }
                try require(n > 0, "configuration write failed; inspect partial file before retry")
                written += n
            }
            try require(fsync(fd) == 0, "configuration sync failed")
            return config
        }
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 &&
                    info.st_uid == geteuid() && info.st_mode & 0o777 == 0o600 &&
                    info.st_size > 0 && info.st_size <= 1024, "unexpected configuration type, owner, mode or size")
        var bytes = [UInt8](repeating: 0, count: 1025)
        let n = read(fd, &bytes, bytes.count)
        try require(n == info.st_size, "configuration changed or could not be read")
        let data = Data(bytes.prefix(n))
        let text = String(decoding: data, as: UTF8.self)
        let keys = try NSRegularExpression(pattern: "\"(?:version|name)\"\\s*:")
        try require(keys.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 2,
                    "duplicate or escaped configuration keys")
        let object = try JSONSerialization.jsonObject(with: data)
        try require((object as? [String: Any]).map { Set($0.keys) == Set(["version", "name"]) } == true,
                    "unknown configuration fields")
        let config = try JSONDecoder().decode(NameConfiguration.self, from: data)
        try require(config.version == 1 && config.name.range(of: "^padink-[0-9a-f]{16}\\.local$", options: .regularExpression) != nil,
                    "unsupported configuration version or name")
        return config
    }
}

struct USBAddress: Equatable, CustomStringConvertible {
    let name: String
    let index: UInt32
    let registryID: UInt64
    let provider: String
    let ipv4: String
    var description: String { "interface=\(name) index=\(index) registryID=\(registryID) ipv4=\(ipv4) provider=\(provider)" }
}

// getifaddrs/IOKit are local inventory reads, not network discovery/scanning.
func usbAddress() throws -> USBAddress? {
    var head: UnsafeMutablePointer<ifaddrs>?
    try require(getifaddrs(&head) == 0, "getifaddrs failed")
    defer { if let head { freeifaddrs(head) } }
    var cursor = head
    var candidates = [USBAddress]()
    while let entry = cursor {
        cursor = entry.pointee.ifa_next
        let e = entry.pointee
        guard let addr = e.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
              e.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST) == UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST),
              e.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
        let name = String(cString: e.ifa_name)
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { continue }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { continue }
        defer { IOObjectRelease(service) }
        var path = [CChar](repeating: 0, count: 4096)
        var rid: UInt64 = 0
        guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS,
              IORegistryEntryGetRegistryEntryID(service, &rid) == KERN_SUCCESS else { continue }
        let provider = String(cString: path)
        guard provider.contains("/iPad@"), provider.contains("/AppleUSBNCM"),
              provider.hasSuffix("/" + name) else { continue }
        let index = if_nametoindex(name)
        guard index != 0 else { continue } // Expected while a physical interface retires.
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        try require(getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                    "cannot read USB IPv4 address")
        let ip = String(cString: host)
        try require(ip != "0.0.0.0" && !ip.hasPrefix("127."), "invalid USB IPv4 address")
        candidates.append(USBAddress(name: name, index: index, registryID: rid, provider: provider, ipv4: ip))
    }
    try require(candidates.count <= 1, "multiple iPad USB NCM IPv4 candidates; explicit selection required")
    return candidates.first
}

struct RegistrationEvent { let generation: UInt64; let error: DNSServiceErrorType }

// A generation is retired before its DNSServiceRef is released. Queued results cannot
// make a retired interface/address current again, even if the BSD name is reused.
struct RegistrationGate {
    private(set) var generation: UInt64 = 0
    private(set) var current: USBAddress?
    private(set) var ready = false
    mutating func replace(with value: USBAddress?) {
        generation += 1; current = value; ready = false
    }
    mutating func accept(_ event: RegistrationEvent) -> Bool {
        guard current != nil, event.generation == generation else { return false }
        ready = event.error == kDNSServiceErr_NoError
        return true
    }
}

final class DNSRegistration {
    private(set) var reference: DNSServiceRef?
    private var record: DNSRecordRef?
    private(set) var events = [RegistrationEvent]()
    let generation: UInt64
    let address: USBAddress
    var fd: Int32 { reference.map { DNSServiceRefSockFD($0) } ?? -1 }

    init(name: String, address: USBAddress, generation: UInt64, malformedForSelftest: Bool = false) throws {
        self.generation = generation; self.address = address
        try require(try usbAddress() == address, "USB identity changed before registration")
        let status = DNSServiceCreateConnection(&reference)
        guard status == kDNSServiceErr_NoError && reference != nil else {
            close(); throw CheckError.failed("DNSServiceCreateConnection error=\(status)")
        }
        var ip = in_addr()
        guard inet_pton(AF_INET, address.ipv4, &ip) == 1 else { close(); throw CheckError.failed("bad IPv4") }
        let callback: DNSServiceRegisterRecordReply = { _, _, _, error, context in
            guard let context else { return }
            let object = Unmanaged<DNSRegistration>.fromOpaque(context).takeUnretainedValue()
            if object.events.count < 8 {
                object.events.append(RegistrationEvent(generation: object.generation, error: error))
            }
        }
        let result = withUnsafePointer(to: &ip) {
            DNSServiceRegisterRecord(reference, &record, DNSServiceFlags(kDNSServiceFlagsUnique), address.index,
                name + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                malformedForSelftest ? 3 : UInt16(MemoryLayout<in_addr>.size), $0, 0, callback,
                Unmanaged.passUnretained(self).toOpaque())
        }
        guard result == kDNSServiceErr_NoError else { close(); throw CheckError.failed("DNSServiceRegisterRecord error=\(result)") }
        do { try require(try usbAddress() == address, "USB identity changed during registration") }
        catch { close(); throw error }
    }
    func process() throws -> [RegistrationEvent] {
        guard let reference else { return [] }
        let result = DNSServiceProcessResult(reference)
        try require(result == kDNSServiceErr_NoError, "DNSServiceProcessResult error=\(result)")
        let resultEvents = events; events.removeAll(); return resultEvents
    }
    // No dispatch queue is attached to DNS-SD: callbacks run only inside process(),
    // on the owner's single poll loop. Deallocation therefore cannot race a callback.
    func close() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil; record = nil; events.removeAll()
    }
    deinit { close() }
}
