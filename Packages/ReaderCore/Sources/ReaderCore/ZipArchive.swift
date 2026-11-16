import CZLIB
import Foundation

public struct ZipEntry: Equatable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipError: Error, Equatable, CustomStringConvertible {
    case truncated
    case signature
    case inflate(Int32)
    case deflate(Int32)
    case unsafePath(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated: return "The ZIP archive is truncated."
        case .signature: return "The ZIP signature is missing."
        case .inflate(let code): return "Could not inflate a ZIP entry (\(code))."
        case .deflate(let code): return "Could not deflate a ZIP entry (\(code))."
        case .unsafePath(let path): return "Refusing to extract \(path)."
        case .unsupported(let message): return message
        }
    }
}

public enum ZipArchive {
    public static func read(_ data: Data) throws -> [ZipEntry] {
        let directory = try centralDirectory(data)
        var entries: [ZipEntry] = []
        for item in directory {
            let local = try localHeader(data, offset: item.offset)
            let payload = data.subdata(in: local.dataStart..<(local.dataStart + item.compressedSize))
            let bytes: Data
            switch item.method {
            case 0:
                bytes = payload
            case 8:
                bytes = try inflateRaw(payload, expected: item.uncompressedSize)
            default:
                throw ZipError.unsupported("ZIP method \(item.method) is not supported.")
            }
            entries.append(ZipEntry(name: item.name, data: bytes))
        }
        return entries
    }

    public static func write(_ entries: [ZipEntry], compressed: Bool = true) throws -> Data {
        var locals = Data()
        var central = Data()
        var records: [(name: Data, crc: UInt32, compressed: Data, method: UInt16, offset: UInt32, rawSize: UInt32)] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = checksum(entry.data)
            let stored = entry.data
            let payload: Data
            let method: UInt16
            if compressed, !entry.data.isEmpty, entry.name != "mimetype" {
                payload = try deflateRaw(entry.data)
                method = 8
            } else {
                payload = stored
                method = 0
            }
            let offset = UInt32(locals.count)
            records.append((name, crc, payload, method, offset, UInt32(entry.data.count)))
            locals.append(localHeader(name: name, crc: crc, method: method, compressed: UInt32(payload.count), raw: UInt32(entry.data.count)))
            locals.append(name)
            locals.append(payload)
        }
        let centralStart = UInt32(locals.count)
        for record in records {
            central.append(centralHeader(record))
        }
        var archive = Data()
        archive.append(locals)
        archive.append(central)
        archive.append(endOfCentralDirectory(count: UInt16(records.count), size: UInt32(central.count), offset: centralStart))
        return archive
    }

    public static func extract(_ data: Data, to directory: String, fs: FileSystem) throws {
        let entries = try read(data)
        try fs.createDirectory(directory)
        for entry in entries {
            if entry.name.hasSuffix("/") { continue }
            try assertSafe(entry.name)
            let path = Paths.join(directory, entry.name)
            try fs.createDirectory(Paths.parent(path))
            try fs.write(path, entry.data)
        }
    }

    private struct Item {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var offset: Int
    }

    private static func centralDirectory(_ data: Data) throws -> [Item] {
        guard let eocd = findEOCD(data) else { throw ZipError.signature }
        let count = Int(readU16(data, eocd + 10))
        let offset = Int(readU32(data, eocd + 16))
        var cursor = offset
        var items: [Item] = []
        for _ in 0..<count {
            guard cursor + 46 <= data.count, readU32(data, cursor) == 0x02014b50 else { throw ZipError.signature }
            let method = readU16(data, cursor + 10)
            let compressed = Int(readU32(data, cursor + 20))
            let uncompressed = Int(readU32(data, cursor + 24))
            let nameLength = Int(readU16(data, cursor + 28))
            let extraLength = Int(readU16(data, cursor + 30))
            let commentLength = Int(readU16(data, cursor + 32))
            let local = Int(readU32(data, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipError.truncated }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""
            items.append(Item(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, offset: local))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return items
    }

    private static func localHeader(_ data: Data, offset: Int) throws -> (dataStart: Int, method: UInt16) {
        guard offset + 30 <= data.count, readU32(data, offset) == 0x04034b50 else { throw ZipError.signature }
        let method = readU16(data, offset + 8)
        let nameLength = Int(readU16(data, offset + 26))
        let extraLength = Int(readU16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start <= data.count else { throw ZipError.truncated }
        return (start, method)
    }

    private static func findEOCD(_ data: Data) -> Int? {
        let minimum = 22
        if data.count < minimum { return nil }
        let limit = min(data.count, minimum + 65_535)
        var offset = data.count - minimum
        let start = data.count - limit
        while offset >= start {
            if readU32(data, offset) == 0x06054b50 { return offset }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func localHeader(name: Data, crc: UInt32, method: UInt16, compressed: UInt32, raw: UInt32) -> Data {
        var data = Data()
        data.appendU32(0x04034b50)
        data.appendU16(20)
        data.appendU16(1 << 11)
        data.appendU16(method)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU32(crc)
        data.appendU32(compressed)
        data.appendU32(raw)
        data.appendU16(UInt16(name.count))
        data.appendU16(0)
        return data
    }

    private static func centralHeader(_ record: (name: Data, crc: UInt32, compressed: Data, method: UInt16, offset: UInt32, rawSize: UInt32)) -> Data {
        var data = Data()
        data.appendU32(0x02014b50)
        data.appendU16(20)
        data.appendU16(20)
        data.appendU16(1 << 11)
        data.appendU16(record.method)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU32(record.crc)
        data.appendU32(UInt32(record.compressed.count))
        data.appendU32(record.rawSize)
        data.appendU16(UInt16(record.name.count))
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU32(0)
        data.appendU32(record.offset)
        data.append(record.name)
        return data
    }

    private static func endOfCentralDirectory(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var data = Data()
        data.appendU32(0x06054b50)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(count)
        data.appendU16(count)
        data.appendU32(size)
        data.appendU32(offset)
        data.appendU16(0)
        return data
    }

    private static func assertSafe(_ name: String) throws {
        if name.hasPrefix("/") || name.contains("..") || name.contains("\\") {
            throw ZipError.unsafePath(name)
        }
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Bytef.self).baseAddress
            return UInt32(crc32(0, pointer, uInt(data.count)))
        }
    }

    private static func inflateRaw(_ data: Data, expected: Int) throws -> Data {
        try codec(data, expected: max(expected, data.count * 2 + 64), inflate: true)
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        try codec(data, expected: data.count + 64, inflate: false)
    }

    private static func codec(_ data: Data, expected: Int, inflate inflating: Bool) throws -> Data {
        var stream = z_stream()
        let version = zlibVersion()
        let size = Int32(MemoryLayout<z_stream>.size)
        let status: Int32
        if inflating {
            status = inflateInit2_( &stream, -15, version, size)
        } else {
            status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, version, size)
        }
        guard status == Z_OK else { throw inflating ? ZipError.inflate(status) : ZipError.deflate(status) }
        defer {
            if inflating { inflateEnd(&stream) } else { deflateEnd(&stream) }
        }
        return try data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(data.count)
            var output = Data(count: max(expected, 64))
            var produced = 0
            var code: Int32 = Z_OK
            while code != Z_STREAM_END {
                if produced == output.count {
                    output.append(Data(count: output.count))
                }
                let capacity = output.count
                let written: Int = try output.withUnsafeMutableBytes { outRaw in
                    let base = outRaw.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = base.advanced(by: produced)
                    stream.avail_out = uInt(capacity - produced)
                    code = inflating ? CZLIB.inflate(&stream, Z_NO_FLUSH) : CZLIB.deflate(&stream, Z_FINISH)
                    if code != Z_OK && code != Z_STREAM_END {
                        throw inflating ? ZipError.inflate(code) : ZipError.deflate(code)
                    }
                    return (capacity - produced) - Int(stream.avail_out)
                }
                produced += written
                if stream.avail_in == 0 && code == Z_OK && !inflating {
                    continue
                }
                if inflating && stream.avail_in == 0 && code == Z_OK && stream.avail_out != 0 && produced > 0 && written == 0 {
                    break
                }
            }
            output.removeSubrange(produced..<output.count)
            return output
        }
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
