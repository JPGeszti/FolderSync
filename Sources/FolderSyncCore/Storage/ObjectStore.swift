import CryptoKit
import Darwin
import Foundation

public enum ObjectStoreError: Error, CustomStringConvertible, Equatable {
    case wrongKey
    case corrupt(hash: String, reason: String)
    case missing(String)
    case hashMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .wrongKey: return "The version store key does not match this store."
        case let .corrupt(h, r): return "Stored object \(h.prefix(12)) is corrupt: \(r)"
        case let .missing(h): return "Stored object \(h.prefix(12)) is missing"
        case let .hashMismatch(e, a): return "Content hash mismatch: expected \(e.prefix(12)), got \(a.prefix(12))"
        }
    }
}

/// Content-addressed, encrypted, append-only store for historical file versions.
///
/// Layout (directory mode 0700, objects 0400):
/// ```
/// store/
///   store.json                 key check value + format version
///   objects/ab/abcdef…         one file per distinct content (name = SHA-256 of plaintext)
///   tmp/                       in-flight writes, renamed into objects/ atomically
/// ```
///
/// Object format:
/// ```
/// "FSOBJv1\0" | objectID (16 random bytes) | chunkSize (UInt32 BE)
/// repeated: sealedLength (UInt32 BE) | AES-GCM combined (nonce ‖ ciphertext ‖ tag)
/// ```
/// Each chunk's additional authenticated data is `objectID ‖ chunkIndex (UInt64 BE) ‖ isFinal (UInt8)`,
/// so chunks cannot be reordered, moved between objects, dropped, or the object truncated without
/// detection. After decryption the plaintext SHA-256 must equal the object name.
public final class ObjectStore: @unchecked Sendable {
    public let root: URL
    let key: SymmetricKey
    static let magic = Array("FSOBJv1\0".utf8)
    public static let chunkSize = 1 << 20

    public init(root: URL, keyProvider: KeyProvider) throws {
        self.root = root
        key = try keyProvider.loadOrCreateKey()
        for dir in [root, root.appendingPathComponent("objects"), root.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir.path, 0o700)
        }
        try checkKey()
        cleanTemporaryFiles()
    }

    private struct Manifest: Codable {
        var format: Int
        var keyCheck: String
    }

    private func keyCheckValue() -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("FolderSync key check v1".utf8), using: key)
        return Data(mac).hexString
    }

    private func checkKey() throws {
        let url = root.appendingPathComponent("store.json")
        if let data = try? Data(contentsOf: url) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.keyCheck == keyCheckValue() else { throw ObjectStoreError.wrongKey }
        } else {
            let data = try JSONEncoder().encode(Manifest(format: 1, keyCheck: keyCheckValue()))
            try data.write(to: url, options: [.atomic])
            chmod(url.path, 0o600)
        }
    }

    /// In-flight files can only be left behind by a crash; nothing references them.
    private func cleanTemporaryFiles() {
        let tmp = root.appendingPathComponent("tmp")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] {
            unlink(tmp.appendingPathComponent(name).path)
        }
    }

    static func isValidHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func objectPath(_ hash: String) -> String {
        root.appendingPathComponent("objects").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash).path
    }

    public func contains(_ hash: String) -> Bool {
        guard ObjectStore.isValidHash(hash) else { return false }
        return access(objectPath(hash), F_OK) == 0
    }

    public func storedSize(_ hash: String) -> Int64? {
        (try? lstatPath(objectPath(hash)))??.size
    }

    public func allHashes() -> [String] {
        let objects = root.appendingPathComponent("objects")
        var out: [String] = []
        for prefix in (try? FileManager.default.contentsOfDirectory(atPath: objects.path)) ?? [] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: objects.appendingPathComponent(prefix).path)) ?? []
            where ObjectStore.isValidHash(name) {
                out.append(name)
            }
        }
        return out
    }

    public func totalSize() -> Int64 {
        allHashes().reduce(0) { $0 + (storedSize($1) ?? 0) }
    }

    public func beginWrite() throws -> ObjectWriter {
        try ObjectWriter(store: self)
    }

    /// Stores the bytes read from an open file descriptor (from its current offset to EOF).
    @discardableResult
    public func ingest(fd: Int32, pathForErrors: String, expectedHash: String?) throws -> String {
        let writer = try beginWrite()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: ObjectStore.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        do {
            while true {
                let n = try readFully(fd, buffer, ObjectStore.chunkSize, pathForErrors)
                if n == 0 { break }
                try writer.append(UnsafeRawBufferPointer(start: buffer, count: n))
                if n < ObjectStore.chunkSize { break }
            }
            return try writer.finish(expectedHash: expectedHash)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Streams the verified plaintext of an object to `sink`. The sink may receive data before
    /// verification completes; callers must therefore write to a temporary location and only
    /// publish it once this function returns without throwing.
    public func read(_ hash: String, _ sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard ObjectStore.isValidHash(hash) else { throw ObjectStoreError.missing(hash) }
        let path = objectPath(hash)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw ObjectStoreError.missing(hash) }
            throw posixFail("open", path)
        }
        defer { close(fd) }

        var header = [UInt8](repeating: 0, count: 28)
        guard try readFully(fd, &header, 28, path) == 28, Array(header[0..<8]) == ObjectStore.magic else {
            throw ObjectStoreError.corrupt(hash: hash, reason: "bad header")
        }
        let objectID = Array(header[8..<24])
        let chunkSize = Int(UInt32(bigEndian: header[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard chunkSize > 0, chunkSize <= 64 << 20 else { throw ObjectStoreError.corrupt(hash: hash, reason: "bad chunk size") }

        var hasher = SHA256()
        var index: UInt64 = 0
        var nextLength: Int? = try readLength(fd, path)
        guard nextLength != nil else { throw ObjectStoreError.corrupt(hash: hash, reason: "no chunks") }
        let maxSealed = chunkSize + 12 + 16
        var sealed = [UInt8](repeating: 0, count: maxSealed)
        while let length = nextLength {
            guard length >= 28, length <= maxSealed else { throw ObjectStoreError.corrupt(hash: hash, reason: "bad chunk length") }
            guard try readFully(fd, &sealed, length, path) == length else {
                throw ObjectStoreError.corrupt(hash: hash, reason: "truncated chunk")
            }
            nextLength = try readLength(fd, path)
            let isFinal = nextLength == nil
            let aad = ObjectWriter.aad(objectID: objectID, index: index, isFinal: isFinal)
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(combined: Data(sealed[0..<length]))
                plain = try AES.GCM.open(box, using: key, authenticating: aad)
            } catch {
                throw ObjectStoreError.corrupt(hash: hash, reason: "authentication failed at chunk \(index)")
            }
            hasher.update(data: plain)
            try plain.withUnsafeBytes { try sink($0) }
            index += 1
        }
        let actual = Data(hasher.finalize()).hexString
        guard actual == hash else { throw ObjectStoreError.hashMismatch(expected: hash, actual: actual) }
    }

    private func readLength(_ fd: Int32, _ path: String) throws -> Int? {
        var b = [UInt8](repeating: 0, count: 4)
        let n = try readFully(fd, &b, 4, path)
        if n == 0 { return nil }
        guard n == 4 else { throw FSError.posix(op: "read", path: path, code: EIO) }
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    /// Decrypts and re-hashes an object without writing it anywhere.
    public func verify(_ hash: String) throws {
        try read(hash) { _ in }
    }

    /// Removes an object. Only the garbage collector calls this, for unreferenced objects.
    func remove(_ hash: String) {
        guard ObjectStore.isValidHash(hash) else { return }
        let path = objectPath(hash)
        chmod(path, 0o600)
        unlink(path)
    }

    func publish(tempPath: String, hash: String) throws -> Bool {
        let dir = (objectPath(hash) as NSString).deletingLastPathComponent
        if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw posixFail("mkdir", dir) }
        do {
            try renameExclusive(tempPath, objectPath(hash))
            syncDirectory(dir)
            return true
        } catch FSError.alreadyExists {
            unlink(tempPath) // identical content already stored (deduplicated)
            return false
        }
    }
}

/// Incrementally encrypts a stream into a temporary object file. The final chunk is held back
/// until `finish` so it can be flagged as final in its authenticated data.
public final class ObjectWriter {
    private let store: ObjectStore
    private let fd: Int32
    let tempPath: String
    private let objectID: [UInt8]
    private var pending = Data()
    private var index: UInt64 = 0
    private var hasher = SHA256()
    private var done = false
    public private(set) var plaintextSize: Int64 = 0

    init(store: ObjectStore) throws {
        self.store = store
        tempPath = store.root.appendingPathComponent("tmp").appendingPathComponent(UUID().uuidString).path
        let f = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { throw posixFail("open", tempPath) }
        fd = f
        var idBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes) == errSecSuccess else {
            close(f)
            throw FSError.posix(op: "random", path: tempPath, code: EIO)
        }
        objectID = idBytes
        var header = ObjectStore.magic + idBytes
        let cs = UInt32(ObjectStore.chunkSize).bigEndian
        withUnsafeBytes(of: cs) { header.append(contentsOf: $0) }
        do { try writeFully(fd, header, header.count, tempPath) } catch {
            close(f)
            unlink(tempPath)
            throw error
        }
    }

    deinit { if !done { abort() } }

    static func aad(objectID: [UInt8], index: UInt64, isFinal: Bool) -> Data {
        var d = Data(objectID)
        withUnsafeBytes(of: index.bigEndian) { d.append(contentsOf: $0) }
        d.append(isFinal ? 1 : 0)
        return d
    }

    public func append(_ bytes: UnsafeRawBufferPointer) throws {
        hasher.update(bufferPointer: bytes)
        plaintextSize += Int64(bytes.count)
        pending.append(contentsOf: bytes)
        while pending.count > ObjectStore.chunkSize {
            try seal(pending.prefix(ObjectStore.chunkSize), isFinal: false)
            pending.removeFirst(ObjectStore.chunkSize)
        }
    }

    private func seal(_ plain: Data, isFinal: Bool) throws {
        let box = try AES.GCM.seal(plain, using: store.key, authenticating: ObjectWriter.aad(objectID: objectID, index: index, isFinal: isFinal))
        guard let combined = box.combined else { throw FSError.posix(op: "seal", path: tempPath, code: EIO) }
        var out = Data()
        withUnsafeBytes(of: UInt32(combined.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(combined)
        try out.withUnsafeBytes { try writeFully(fd, $0.baseAddress!, $0.count, tempPath) }
        index += 1
    }

    /// Seals the last chunk, makes the file durable and read-only, and publishes it under its
    /// content hash. Returns the hash. Throws (and discards the data) if `expectedHash` differs.
    @discardableResult
    public func finish(expectedHash: String? = nil) throws -> String {
        do {
            try seal(pending, isFinal: true)
            pending = Data()
            let hash = Data(hasher.finalize()).hexString
            if let e = expectedHash, e != hash { throw ObjectStoreError.hashMismatch(expected: e, actual: hash) }
            try fullSync(fd, tempPath)
            fchmod(fd, 0o400)
            close(fd)
            done = true
            _ = try store.publish(tempPath: tempPath, hash: hash)
            return hash
        } catch {
            abort()
            throw error
        }
    }

    public func abort() {
        guard !done else { return }
        done = true
        close(fd)
        unlink(tempPath)
    }
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
