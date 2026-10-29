import Foundation
import Compression

/// A tiny ZIP extractor (stored + deflate) — enough for .xlsx files on iOS, where `ditto` isn't available.
enum ZipReader {
    enum ZipError: Error { case notZip, unsupported, corrupt }

    static func extract(_ url: URL, to folder: URL) throws {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        // End of central directory: signature 0x06054b50, searched from the end (after an optional comment).
        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)

        let fm = FileManager.default
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt }
            let method = u16(p + 10)
            let compressedSize = u32(p + 20)
            let size = u32(p + 24)
            let nameLength = u16(p + 28)
            let extraLength = u16(p + 30)
            let commentLength = u16(p + 32)
            let localOffset = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            // Skip folders and anything trying to escape the target folder.
            guard !name.hasSuffix("/"), !name.contains("..") else { continue }

            guard localOffset + 30 <= bytes.count, u32(localOffset) == 0x04034b50 else { throw ZipError.corrupt }
            let start = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard start + compressedSize <= bytes.count else { throw ZipError.corrupt }
            let compressed = Data(bytes[start..<(start + compressedSize)])

            let content: Data
            switch method {
            case 0: content = compressed
            case 8: content = try inflate(compressed, size: size)
            default: throw ZipError.unsupported
            }

            let target = folder.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
        }
    }

    /// Raw DEFLATE (what ZIP uses) — Apple's COMPRESSION_ZLIB is exactly that.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return out
    }
}
