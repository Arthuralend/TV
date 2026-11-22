import Compression
import Foundation

/// Streams a .gz file into a plain file (TV guides are often 100+ MB unpacked, so nothing is held in memory).
enum Gzip {
    static func isGzip(file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 2)) ?? Data()
        return head.count == 2 && head[head.startIndex] == 0x1f && head[head.startIndex + 1] == 0x8b
    }

    static func decompress(file src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let offset = try headerLength(data)
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw URLError(.cannotDecodeContentData)
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw URLError(.cannotDecodeContentData) }
            stream.pointee.src_ptr = base + offset
            stream.pointee.src_size = max(0, data.count - offset - 8)   // the last 8 bytes are CRC32 + size
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { out.write(Data(bytes: buffer, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.pointee.src_size == 0 { return }
                default:
                    throw URLError(.cannotDecodeContentData)
                }
            }
        }
    }

    /// Size of the gzip member header (RFC 1952).
    private static func headerLength(_ d: Data) throws -> Int {
        let b = [UInt8](d.prefix(4096))
        guard b.count > 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw URLError(.cannotDecodeContentData) }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= b.count else { throw URLError(.cannotDecodeContentData) }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FNAME
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                                               // FHCRC
        guard i < d.count else { throw URLError(.cannotDecodeContentData) }
        return i
    }
}
