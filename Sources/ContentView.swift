import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Compression
import CryptoKit

// MARK: - Native UIKit File Picker & Share Helper
@MainActor
final class NativeFilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeFilePicker()
    private var completion: (([URL]) -> Void)?

    static var supportedTypes: [UTType] {
        var list: [UTType] = [.item, .data, .content, .archive, .zip, .json, .propertyList, .plainText, .image, .png, .jpeg]
        for ext in ["ipa", "dylib", "deb", "plist", "mobileprovision", "strings", "xml", "cfg", "lua"] {
            if let t = UTType(filenameExtension: ext) { list.append(t) }
        }
        return list
    }

    func pick(allowsMultiple: Bool = false, types: [UTType]? = nil, completion: @escaping ([URL]) -> Void) {
        guard let presenter = Self.topViewController() else {
            completion([])
            return
        }
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types ?? Self.supportedTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        presenter.present(picker, animated: true)
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            let handler = self.completion
            self.completion = nil
            handler?(urls)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            self.completion = nil
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

@MainActor
enum NativeShareHelper {
    static func share(url: URL) {
        guard let presenter = NativeFilePicker.topViewController() else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
}

// MARK: - Pure Swift ZIP Extractor & Repacker
enum ZIPArchiveError: LocalizedError {
    case invalidArchive(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let msg): return "File IPA không hợp lệ: \(msg)"
        case .ioFailed(let msg): return "Lỗi đọc/ghi tệp: \(msg)"
        }
    }
}

enum ZIPArchive {
    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            for i in 0..<count {
                let idx = Int((crc ^ UInt32(ptr[i])) & 0xFF)
                crc = crc32Table[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func readU16LE(_ d: Data, _ off: Int) -> UInt16 {
        let b = d.startIndex + off
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    private static func readU32LE(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return UInt32(d[b])
            | (UInt32(d[b + 1]) << 8)
            | (UInt32(d[b + 2]) << 16)
            | (UInt32(d[b + 3]) << 24)
    }

    private static func appendU16LE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }

    private static func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else { return nil }
        let dstCapacity = max(expectedSize + 1024, 4096)
        var dst = Data(count: dstCapacity)
        let decoded: Int = dst.withUnsafeMutableBytes { dstRaw in
            data.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, dstCapacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded > 0 else { return nil }
        return dst.prefix(decoded)
    }

    private static func compressDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let dstCapacity = data.count + 1024
        var dst = Data(count: dstCapacity)
        let encoded: Int = dst.withUnsafeMutableBytes { dstRaw in
            data.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstPtr, dstCapacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard encoded > 0, encoded < data.count else { return nil }
        return dst.prefix(encoded)
    }

    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let externalAttr: UInt32
        let localOffset: UInt32
    }

    static func extract(ipaURL: URL, to destinationDir: URL, onProgress: (@Sendable (Double, String) -> Void)? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDir.path) {
            try fm.removeItem(at: destinationDir)
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: ipaURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZIPArchiveError.invalidArchive("File quá nhỏ hoặc rỗng") }

        let scanLen = Int(min(fileSize, 65557))
        let scanStart = fileSize - UInt64(scanLen)
        try handle.seek(toOffset: scanStart)
        guard let tail = try handle.read(upToCount: scanLen), tail.count >= 22 else {
            throw ZIPArchiveError.ioFailed("Không đọc được cuối file")
        }

        var eocdOffset: Int?
        let base = tail.startIndex
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail[base + i] == 0x50 && tail[base + i + 1] == 0x4B && tail[base + i + 2] == 0x05 && tail[base + i + 3] == 0x06 {
                let commentLen = Int(readU16LE(tail, i + 20))
                if i + 22 + commentLen == tail.count {
                    eocdOffset = i
                    break
                }
            }
        }
        guard let eocd = eocdOffset else {
            throw ZIPArchiveError.invalidArchive("Không tìm thấy cấu trúc ZIP EOCD")
        }

        let cdSizeRaw = readU32LE(tail, eocd + 12)
        let cdOffsetRaw = readU32LE(tail, eocd + 16)
        guard cdSizeRaw != 0xFFFFFFFF && cdOffsetRaw != 0xFFFFFFFF else {
            throw ZIPArchiveError.invalidArchive("Chưa hỗ trợ gói ZIP64 vượt quá 4GB")
        }

        let cdSize = Int(cdSizeRaw)
        let cdOffset = UInt64(cdOffsetRaw)
        try handle.seek(toOffset: cdOffset)
        guard let cdData = try handle.read(upToCount: cdSize), cdData.count == cdSize else {
            throw ZIPArchiveError.invalidArchive("Central Directory bị hỏng")
        }

        var entries: [CentralEntry] = []
        var pos = 0
        while pos + 46 <= cdData.count {
            let sig = readU32LE(cdData, pos)
            guard sig == 0x02014B50 else { break }
            let method = readU16LE(cdData, pos + 10)
            let compSize = readU32LE(cdData, pos + 20)
            let uncompSize = readU32LE(cdData, pos + 24)
            let nameLen = Int(readU16LE(cdData, pos + 28))
            let extraLen = Int(readU16LE(cdData, pos + 30))
            let commentLen = Int(readU16LE(cdData, pos + 32))
            let extAttr = readU32LE(cdData, pos + 38)
            let localOffset = readU32LE(cdData, pos + 42)
            let nameStart = cdData.startIndex + pos + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.endIndex else { break }
            let name = String(data: cdData[nameStart..<nameEnd], encoding: .utf8) ?? ""
            entries.append(CentralEntry(
                name: name,
                method: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                externalAttr: extAttr,
                localOffset: localOffset
            ))
            pos += 46 + nameLen + extraLen + commentLen
        }

        let total = max(entries.count, 1)
        for (idx, entry) in entries.enumerated() {
            try autoreleasepool {
                if idx % 25 == 0 || idx == entries.count - 1 {
                    onProgress?(Double(idx + 1) / Double(total), entry.name)
                }
                guard !entry.name.isEmpty,
                      !entry.name.contains(".."),
                      !entry.name.hasPrefix("__MACOSX/") else { return }

                let outURL = destinationDir.appendingPathComponent(entry.name)
                if entry.name.hasSuffix("/") {
                    try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                    return
                }

                try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try handle.seek(toOffset: UInt64(entry.localOffset))
                guard let localHeader = try handle.read(upToCount: 30), localHeader.count == 30 else { return }
                let localNameLen = Int(readU16LE(localHeader, 26))
                let localExtraLen = Int(readU16LE(localHeader, 28))
                try handle.seek(toOffset: UInt64(entry.localOffset) + 30 + UInt64(localNameLen + localExtraLen))

                let rawData: Data = entry.compressedSize == 0
                    ? Data()
                    : ((try handle.read(upToCount: Int(entry.compressedSize))) ?? Data())

                let finalData: Data
                if entry.method == 0 {
                    finalData = rawData
                } else if entry.method == 8 {
                    guard let decoded = decompressDeflate(rawData, expectedSize: Int(entry.uncompressedSize)) else {
                        throw ZIPArchiveError.invalidArchive("Giải nén lỗi tại \(entry.name)")
                    }
                    finalData = decoded
                } else {
                    throw ZIPArchiveError.invalidArchive("Phương thức nén \(entry.method) không hỗ trợ")
                }

                try finalData.write(to: outURL, options: .atomic)
                let unixMode = (entry.externalAttr >> 16) & 0xFFFF
                if (unixMode & 0o111) != 0 {
                    try? fm.setAttributes([.posixPermissions: Int(unixMode & 0o777)], ofItemAtPath: outURL.path)
                }
            }
        }
    }

    private struct WrittenEntry {
        let nameData: Data
        let method: UInt16
        let crc: UInt32
        let compSize: UInt32
        let uncompSize: UInt32
        let externalAttr: UInt32
        let localOffset: UInt32
    }

    static func pack(sourceDir: URL, to outputIPA: URL, compressFiles: Bool = true, onProgress: (@Sendable (Double, String) -> Void)? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputIPA.path) {
            try fm.removeItem(at: outputIPA)
        }
        fm.createFile(atPath: outputIPA.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: outputIPA)
        defer { try? outHandle.close() }

        guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ZIPArchiveError.ioFailed("Không duyệt được thư mục làm việc")
        }

        let allURLs = enumerator.compactMap { $0 as? URL }
        let rootPath = sourceDir.standardizedFileURL.path
        let skipCompressExts: Set<String> = ["png", "jpg", "jpeg", "webp", "mp4", "m4a", "mp3", "ogg", "zip", "gz", "ipa", "mov", "aac"]
        var written: [WrittenEntry] = []
        var currentOffset: UInt32 = 0
        let total = max(allURLs.count, 1)

        for (idx, itemURL) in allURLs.enumerated() {
            try autoreleasepool {
                if itemURL.lastPathComponent == ".DS_Store" { return }
                let fullPath = itemURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath) else { return }
                var relPath = String(fullPath.dropFirst(rootPath.count))
                if relPath.hasPrefix("/") { relPath.removeFirst() }
                guard !relPath.isEmpty else { return }

                if idx % 25 == 0 || idx == allURLs.count - 1 {
                    onProgress?(Double(idx + 1) / Double(total), relPath)
                }

                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let entryName = isDir ? (relPath.hasSuffix("/") ? relPath : relPath + "/") : relPath
                let nameData = Data(entryName.utf8)

                var payload = Data()
                var method: UInt16 = 0
                var crcVal: UInt32 = 0
                var uncompSize: UInt32 = 0
                var posixMode: UInt32 = isDir ? 0o040755 : 0o100644

                if !isDir {
                    let fileData = try Data(contentsOf: itemURL)
                    uncompSize = UInt32(fileData.count)
                    crcVal = crc32(fileData)

                    let perms = (try? fm.attributesOfItem(atPath: itemURL.path)[.posixPermissions] as? Int) ?? 0o644
                    let isMachO = fileData.count >= 4 && (
                        (fileData[0] == 0xCF && fileData[1] == 0xFA && fileData[2] == 0xED && fileData[3] == 0xFE) ||
                        (fileData[0] == 0xCA && fileData[1] == 0xFE && fileData[2] == 0xBA && fileData[3] == 0xBE)
                    )
                    if isMachO || (perms & 0o111) != 0 || itemURL.pathExtension.lowercased() == "dylib" {
                        posixMode = 0o100755
                    } else {
                        posixMode = 0o100644
                    }

                    let ext = itemURL.pathExtension.lowercased()
                    if compressFiles && !skipCompressExts.contains(ext), let deflated = compressDeflate(fileData) {
                        payload = deflated
                        method = 8
                    } else {
                        payload = fileData
                        method = 0
                    }
                }

                var lfh = Data(capacity: 30 + nameData.count)
                appendU32LE(&lfh, 0x04034B50)
                appendU16LE(&lfh, 20)
                appendU16LE(&lfh, 0x0800)
                appendU16LE(&lfh, method)
                appendU16LE(&lfh, 0x0000)
                appendU16LE(&lfh, 0x5821)
                appendU32LE(&lfh, crcVal)
                appendU32LE(&lfh, UInt32(payload.count))
                appendU32LE(&lfh, uncompSize)
                appendU16LE(&lfh, UInt16(nameData.count))
                appendU16LE(&lfh, 0)
                lfh.append(nameData)

                try outHandle.write(contentsOf: lfh)
                if !payload.isEmpty {
                    try outHandle.write(contentsOf: payload)
                }

                written.append(WrittenEntry(
                    nameData: nameData,
                    method: method,
                    crc: crcVal,
                    compSize: UInt32(payload.count),
                    uncompSize: uncompSize,
                    externalAttr: posixMode << 16,
                    localOffset: currentOffset
                ))
                currentOffset &+= UInt32(lfh.count + payload.count)
            }
        }

        let cdStartOffset = currentOffset
        var cdSize: UInt32 = 0
        for item in written {
            var cdh = Data(capacity: 46 + item.nameData.count)
            appendU32LE(&cdh, 0x02014B50)
            appendU16LE(&cdh, 0x031E)
            appendU16LE(&cdh, 20)
            appendU16LE(&cdh, 0x0800)
            appendU16LE(&cdh, item.method)
            appendU16LE(&cdh, 0x0000)
            appendU16LE(&cdh, 0x5821)
            appendU32LE(&cdh, item.crc)
            appendU32LE(&cdh, item.compSize)
            appendU32LE(&cdh, item.uncompSize)
            appendU16LE(&cdh, UInt16(item.nameData.count))
            appendU16LE(&cdh, 0)
            appendU16LE(&cdh, 0)
            appendU16LE(&cdh, 0)
            appendU16LE(&cdh, 0)
            appendU32LE(&cdh, item.externalAttr)
            appendU32LE(&cdh, item.localOffset)
            cdh.append(item.nameData)
            try outHandle.write(contentsOf: cdh)
            cdSize &+= UInt32(cdh.count)
        }

        var eocd = Data(capacity: 22)
        appendU32LE(&eocd, 0x06054B50)
        appendU16LE(&eocd, 0)
        appendU16LE(&eocd, 0)
        appendU16LE(&eocd, UInt16(min(written.count, 65535)))
        appendU16LE(&eocd, UInt16(min(written.count, 65535)))
        appendU32LE(&eocd, cdSize)
        appendU32LE(&eocd, cdStartOffset)
        appendU16LE(&eocd, 0)
        try outHandle.write(contentsOf: eocd)
    }
}

// MARK: - Mach-O Binary Inspector, Entitlements Extractor & LC_LOAD_DYLIB Injector
struct MachOInfo: Sendable {
    let executableName: String
    let executableURL: URL
    let fileSizeBytes: Int64
    let architectures: [String]
    let isEncrypted: Bool?
    let cryptID: UInt32?
    let minOSVersion: String?
    let sdkVersion: String?
    let linkedDylibs: [String]
    let injectedDylibs: [String]
    let rpaths: [String]
    let entitlementsXML: String?
}

enum MachOInspector {
    fileprivate static func readU32LE(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }

    fileprivate static func readU32BE(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    }

    private static func decodeVersion(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFFFF
        let minor = (raw >> 8) & 0xFF
        let patch = raw & 0xFF
        return patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }

    private static func archName(cpuType: UInt32, cpuSubType: UInt32) -> String {
        let sub = cpuSubType & 0x00FFFFFF
        switch cpuType {
        case 0x0100000C: return sub == 2 ? "arm64e" : "arm64"
        case 0x01000007: return "x86_64"
        case 0x0000000C: return "armv7"
        default: return String(format: "0x%X", cpuType)
        }
    }

    private static func extractEntitlements(handle: FileHandle, sliceOffset: UInt64, dataOff: UInt32, dataSize: UInt32) -> String? {
        guard dataSize >= 20, dataSize <= 2_500_000 else { return nil }
        try? handle.seek(toOffset: sliceOffset + UInt64(dataOff))
        guard let sigData = try? handle.read(upToCount: Int(dataSize)), sigData.count >= 20 else { return nil }
        guard readU32BE(sigData, 0) == 0xFADE0CC0 else { return nil }
        let blobCount = Int(readU32BE(sigData, 8))
        for i in 0..<min(blobCount, 32) {
            let entryPos = 12 + i * 8
            guard entryPos + 8 <= sigData.count else { break }
            let blobOffset = Int(readU32BE(sigData, entryPos + 4))
            guard blobOffset >= 0, blobOffset + 8 <= sigData.count else { continue }
            let magic = readU32BE(sigData, blobOffset)
            let length = Int(readU32BE(sigData, blobOffset + 4))
            if magic == 0xFADE7171, length > 8, blobOffset + length <= sigData.count {
                let xmlStart = sigData.startIndex + blobOffset + 8
                let xmlEnd = sigData.startIndex + blobOffset + length
                if let xml = String(data: sigData[xmlStart..<xmlEnd], encoding: .utf8) {
                    return xml.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    static func inspect(binaryURL: URL) -> MachOInfo? {
        guard let handle = try? FileHandle(forReadingFrom: binaryURL) else { return nil }
        defer { try? handle.close() }
        let fileSize = Int64((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
        guard let probe = try? handle.read(upToCount: 4096), probe.count >= 32 else { return nil }

        let magicLE = readU32LE(probe, 0)
        let magicBE = readU32BE(probe, 0)

        var sliceOffsets: [UInt64] = []
        var archs: [String] = []

        if magicBE == 0xCAFEBABE {
            let nfat = Int(readU32BE(probe, 4))
            for i in 0..<min(nfat, 8) {
                let off = 8 + i * 20
                guard off + 20 <= probe.count else { break }
                let cpu = readU32BE(probe, off)
                let sub = readU32BE(probe, off + 4)
                let sliceOff = UInt64(readU32BE(probe, off + 8))
                archs.append(archName(cpuType: cpu, cpuSubType: sub))
                sliceOffsets.append(sliceOff)
            }
        } else if magicLE == 0xFEEDFACF {
            let cpu = readU32LE(probe, 4)
            let sub = readU32LE(probe, 8)
            archs.append(archName(cpuType: cpu, cpuSubType: sub))
            sliceOffsets.append(0)
        } else {
            return nil
        }

        let targetOffset = sliceOffsets.first ?? 0
        try? handle.seek(toOffset: targetOffset)
        guard let header = try? handle.read(upToCount: 32), header.count == 32 else { return nil }
        let ncmds = Int(readU32LE(header, 16))
        let sizeofcmds = Int(readU32LE(header, 20))
        let readLen = min(sizeofcmds, 1_500_000)
        guard let cmdData = try? handle.read(upToCount: readLen) else { return nil }

        var cryptID: UInt32?
        var minOS: String?
        var sdk: String?
        var dylibs: [String] = []
        var rpaths: [String] = []
        var codeSigOff: UInt32?
        var codeSigSize: UInt32?
        var pos = 0

        for _ in 0..<ncmds {
            guard pos + 8 <= cmdData.count else { break }
            let cmd = readU32LE(cmdData, pos)
            let cmdsize = Int(readU32LE(cmdData, pos + 4))
            guard cmdsize >= 8, pos + cmdsize <= cmdData.count else { break }

            if cmd == 0x2C || cmd == 0x21 {
                if pos + 20 <= cmdData.count {
                    cryptID = readU32LE(cmdData, pos + 16)
                }
            } else if cmd == 0x32 {
                if pos + 20 <= cmdData.count {
                    minOS = decodeVersion(readU32LE(cmdData, pos + 12))
                    sdk = decodeVersion(readU32LE(cmdData, pos + 16))
                }
            } else if cmd == 0x1D {
                if pos + 16 <= cmdData.count {
                    codeSigOff = readU32LE(cmdData, pos + 8)
                    codeSigSize = readU32LE(cmdData, pos + 12)
                }
            } else if cmd == 0x0C || cmd == 0x80000018 || cmd == 0x8000001F || cmd == 0x20 {
                if pos + 12 <= cmdData.count {
                    let strOff = Int(readU32LE(cmdData, pos + 8))
                    if strOff < cmdsize {
                        let start = cmdData.startIndex + pos + strOff
                        let end = cmdData.startIndex + pos + cmdsize
                        let slice = cmdData[start..<end]
                        let stop = slice.firstIndex(of: 0) ?? end
                        if let s = String(data: slice[start..<stop], encoding: .utf8), !s.isEmpty {
                            dylibs.append(s)
                        }
                    }
                }
            } else if cmd == 0x8000001C {
                if pos + 12 <= cmdData.count {
                    let strOff = Int(readU32LE(cmdData, pos + 8))
                    if strOff < cmdsize {
                        let start = cmdData.startIndex + pos + strOff
                        let end = cmdData.startIndex + pos + cmdsize
                        let slice = cmdData[start..<end]
                        let stop = slice.firstIndex(of: 0) ?? end
                        if let s = String(data: slice[start..<stop], encoding: .utf8), !s.isEmpty {
                            rpaths.append(s)
                        }
                    }
                }
            }
            pos += cmdsize
        }

        let entitlements: String?
        if let off = codeSigOff, let sz = codeSigSize {
            entitlements = extractEntitlements(handle: handle, sliceOffset: targetOffset, dataOff: off, dataSize: sz)
        } else {
            entitlements = nil
        }

        let injected = dylibs.filter {
            $0.hasPrefix("@executable_path") || $0.hasPrefix("@rpath") || $0.hasPrefix("@loader_path") || $0.contains("Substrate") || $0.contains("ElleKit") || $0.contains("Cydia")
        }

        return MachOInfo(
            executableName: binaryURL.lastPathComponent,
            executableURL: binaryURL,
            fileSizeBytes: fileSize,
            architectures: archs,
            isEncrypted: cryptID.map { $0 != 0 },
            cryptID: cryptID,
            minOSVersion: minOS,
            sdkVersion: sdk,
            linkedDylibs: dylibs,
            injectedDylibs: injected,
            rpaths: rpaths,
            entitlementsXML: entitlements
        )
    }
}

enum MachODylibInjector {
    private static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }

    static func inject(dylibSourceURL: URL, into appBundleURL: URL, executableName: String, weakLoad: Bool = false) throws -> String {
        guard dylibSourceURL.pathExtension.lowercased() == "dylib" else {
            throw ZIPArchiveError.ioFailed("Vui lòng chọn đúng file đuôi .dylib")
        }

        let fm = FileManager.default
        let frameworksDir = appBundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        let dylibName = dylibSourceURL.lastPathComponent
        let destDylibURL = frameworksDir.appendingPathComponent(dylibName)
        if fm.fileExists(atPath: destDylibURL.path) {
            try fm.removeItem(at: destDylibURL)
        }
        try fm.copyItem(at: dylibSourceURL, to: destDylibURL)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDylibURL.path)

        let loadPath = "@executable_path/Frameworks/\(dylibName)"
        let execURL = appBundleURL.appendingPathComponent(executableName)
        let handle = try FileHandle(forUpdating: execURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        guard let probe = try handle.read(upToCount: 4096), probe.count >= 32 else {
            throw ZIPArchiveError.ioFailed("Không đọc được header Mach-O")
        }

        let magicLE = MachOInspector.readU32LE(probe, 0)
        let magicBE = MachOInspector.readU32BE(probe, 0)
        var sliceOffsets: [UInt64] = []

        if magicBE == 0xCAFEBABE {
            let nfat = Int(MachOInspector.readU32BE(probe, 4))
            for i in 0..<min(nfat, 8) {
                let off = 8 + i * 20
                guard off + 20 <= probe.count else { break }
                sliceOffsets.append(UInt64(MachOInspector.readU32BE(probe, off + 8)))
            }
        } else if magicLE == 0xFEEDFACF {
            sliceOffsets.append(0)
        } else {
            throw ZIPArchiveError.ioFailed("Binary không phải định dạng Mach-O 64-bit")
        }

        let pathBytes = Data(loadPath.utf8)
        let rawCmdSize = 24 + pathBytes.count + 1
        let alignedCmdSize = ((rawCmdSize + 7) / 8) * 8

        var newCmd = Data(capacity: alignedCmdSize)
        appendU32LE(&newCmd, weakLoad ? 0x80000018 : 0x0C)
        appendU32LE(&newCmd, UInt32(alignedCmdSize))
        appendU32LE(&newCmd, 24)
        appendU32LE(&newCmd, 2)
        appendU32LE(&newCmd, 0x00010000)
        appendU32LE(&newCmd, 0x00010000)
        newCmd.append(pathBytes)
        while newCmd.count < alignedCmdSize { newCmd.append(0) }

        var modifiedSlices = 0
        for sliceOffset in sliceOffsets {
            try handle.seek(toOffset: sliceOffset)
            guard let header = try handle.read(upToCount: 32), header.count == 32 else { continue }
            guard MachOInspector.readU32LE(header, 0) == 0xFEEDFACF else { continue }

            let ncmds = MachOInspector.readU32LE(header, 16)
            let sizeofcmds = MachOInspector.readU32LE(header, 20)
            guard let cmdData = try handle.read(upToCount: Int(sizeofcmds)), cmdData.count == Int(sizeofcmds) else {
                throw ZIPArchiveError.ioFailed("Không đọc được bảng Load Commands")
            }

            var pos = 0
            var alreadyLoaded = false
            var minSectionOffset = UInt32.max

            for _ in 0..<Int(ncmds) {
                guard pos + 8 <= cmdData.count else { break }
                let cmd = MachOInspector.readU32LE(cmdData, pos)
                let cmdsize = Int(MachOInspector.readU32LE(cmdData, pos + 4))
                guard cmdsize >= 8, pos + cmdsize <= cmdData.count else { break }

                if cmd == 0x0C || cmd == 0x80000018 || cmd == 0x8000001F || cmd == 0x20 {
                    let strOff = Int(MachOInspector.readU32LE(cmdData, pos + 8))
                    if strOff < cmdsize {
                        let start = cmdData.startIndex + pos + strOff
                        let end = cmdData.startIndex + pos + cmdsize
                        let slice = cmdData[start..<end]
                        let stop = slice.firstIndex(of: 0) ?? end
                        if let existing = String(data: slice[start..<stop], encoding: .utf8), existing == loadPath {
                            alreadyLoaded = true
                        }
                    }
                } else if cmd == 0x19 && cmdsize >= 72 {
                    let nsects = Int(MachOInspector.readU32LE(cmdData, pos + 64))
                    for s in 0..<nsects {
                        let sectPos = pos + 72 + s * 80
                        guard sectPos + 52 <= pos + cmdsize else { break }
                        let fileOff = MachOInspector.readU32LE(cmdData, sectPos + 48)
                        if fileOff > 0 && fileOff < minSectionOffset {
                            minSectionOffset = fileOff
                        }
                    }
                }
                pos += cmdsize
            }

            if alreadyLoaded { continue }

            let endOfCmds = 32 + Int(sizeofcmds)
            guard minSectionOffset == UInt32.max || endOfCmds + alignedCmdSize <= Int(minSectionOffset) else {
                throw ZIPArchiveError.ioFailed("Không đủ khoảng trống header Mach-O để chèn \(dylibName)")
            }

            try handle.seek(toOffset: sliceOffset + UInt64(endOfCmds))
            try handle.write(contentsOf: newCmd)

            var updatedCounts = Data(capacity: 8)
            appendU32LE(&updatedCounts, ncmds + 1)
            appendU32LE(&updatedCounts, sizeofcmds + UInt32(alignedCmdSize))
            try handle.seek(toOffset: sliceOffset + 16)
            try handle.write(contentsOf: updatedCounts)
            modifiedSlices += 1
        }

        let sigDir = appBundleURL.appendingPathComponent("_CodeSignature")
        if fm.fileExists(atPath: sigDir.path) {
            try? fm.removeItem(at: sigDir)
        }

        return modifiedSlices > 0
            ? "Đã inject \(dylibName) (\(weakLoad ? "Weak" : "Load")) vào Mach-O"
            : "Đã cập nhật \(dylibName) (lệnh load đã tồn tại sẵn)"
    }
}

enum BinaryStringsScanner {
    static func scanURLs(binaryURL: URL, maxResults: Int = 150) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: binaryURL) else { return [] }
        defer { try? handle.close() }

        let ignoredSubstrings = [
            "apple.com/DTDs", "w3.org/2000", "w3.org/1999", "ns.adobe.com",
            "schemas.openxmlformats", "purl.org/dc", "xml.org/sax"
        ]
        var results: [String] = []
        var seen: Set<String> = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(256)

        let chunkSize = 512 * 1024
        let maxBytesToScan = 64 * 1024 * 1024
        var scanned = 0

        func flushBuffer() {
            guard buffer.count >= 12 && buffer.count <= 260 else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            if let s = String(bytes: buffer, encoding: .ascii),
               let range = s.range(of: "https://") ?? s.range(of: "http://") {
                var candidate = String(s[range.lowerBound...])
                let stopChars = CharacterSet(charactersIn: " \"'<>\\)}\n\r\t")
                if let stop = candidate.rangeOfCharacter(from: stopChars) {
                    candidate = String(candidate[..<stop.lowerBound])
                }
                if candidate.count >= 12,
                   candidate.contains("."),
                   !ignoredSubstrings.contains(where: { candidate.contains($0) }),
                   !seen.contains(candidate) {
                    seen.insert(candidate)
                    results.append(candidate)
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }

        while scanned < maxBytesToScan && results.count < maxResults {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            scanned += chunk.count
            chunk.withUnsafeBytes { raw in
                guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<raw.count {
                    let b = ptr[i]
                    if b >= 33 && b <= 126 {
                        if buffer.count < 260 { buffer.append(b) }
                    } else if !buffer.isEmpty {
                        flushBuffer()
                        if results.count >= maxResults { break }
                    }
                }
            }
        }
        flushBuffer()
        return results
    }
}

// MARK: - Plist, Provision, Localization & Icon Helpers
enum PlistHelper {
    static func readDict(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func writeDict(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func plistToXMLString(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xmlData = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) else {
            return nil
        }
        return String(data: xmlData, encoding: .utf8)
    }

    static func validateAndSaveXMLPlist(_ xml: String, to url: URL) throws {
        let data = Data(xml.utf8)
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        try data.write(to: url, options: .atomic)
    }

    static func parseEmbeddedProvisionSummary(appBundleURL: URL) -> String? {
        let provURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: provURL),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let xmlData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let team = (plist["TeamName"] as? String) ?? "N/A"
        let tid = ((plist["TeamIdentifier"] as? [String])?.first) ?? "N/A"
        let exp = (plist["ExpirationDate"] as? Date)?.formatted(date: .abbreviated, time: .omitted) ?? "N/A"
        return "\(team) (\(tid)) • Hết hạn: \(exp)"
    }
}

enum LocalizationCleaner {
    static let keepSet: Set<String> = ["base.lproj", "en.lproj", "en-us.lproj", "en_us.lproj", "vi.lproj", "vi-vn.lproj", "vi_vn.lproj"]

    static func removableURLs(in appBundleURL: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: appBundleURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { url in
            let lower = url.lastPathComponent.lowercased()
            return lower.hasSuffix(".lproj") && !keepSet.contains(lower)
        }
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let file as URL in e {
            sum += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return sum
    }
}

enum AppIconBatchReplacer {
    static func replaceAllIcons(in appBundleURL: URL, with sourceImageURL: URL) throws -> Int {
        guard let rawData = try? Data(contentsOf: sourceImageURL),
              let sourceImage = UIImage(data: rawData) else {
            throw ZIPArchiveError.ioFailed("Không đọc được file ảnh bạn chọn")
        }

        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: appBundleURL, includingPropertiesForKeys: nil)) ?? []
        let iconFiles = items.filter {
            $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.lowercased().contains("icon")
        }

        var replacedCount = 0
        for fileURL in iconFiles {
            var targetPxW: CGFloat = 180
            var targetPxH: CGFloat = 180
            if let existing = UIImage(contentsOfFile: fileURL.path) {
                let w = existing.size.width * existing.scale
                let h = existing.size.height * existing.scale
                if w >= 20 && h >= 20 {
                    targetPxW = w
                    targetPxH = h
                }
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetPxW, height: targetPxH), format: format)
            let resized = renderer.image { _ in
                sourceImage.draw(in: CGRect(x: 0, y: 0, width: targetPxW, height: targetPxH))
            }
            if let png = resized.pngData() {
                try png.write(to: fileURL, options: .atomic)
                replacedCount += 1
            }
        }
        return replacedCount
    }
}

// MARK: - Workspace Models
struct IPAFileNode: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let sizeBytes: Int64

    var formattedSize: String {
        isDirectory ? "Thư mục" : ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var isTextEditable: Bool {
        let ext = url.pathExtension.lowercased()
        return ["plist", "json", "txt", "xml", "strings", "entitlements", "cfg", "ini", "lua", "js", "html", "css", "md", "yaml", "yml"].contains(ext)
    }

    var isImageFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isImageFile { return "photo.fill" }
        if isTextEditable { return "doc.text.fill" }
        let ext = url.pathExtension.lowercased()
        if ext == "dylib" || ext == "framework" { return "puzzlepiece.extension.fill" }
        return "doc.fill"
    }

    var iconColor: Color {
        if isDirectory { return .accentColor }
        if isImageFile { return .orange }
        if isTextEditable { return .green }
        let ext = url.pathExtension.lowercased()
        if ext == "dylib" || ext == "framework" { return .purple }
        return .secondary
    }
}

struct IPAWorkspaceSummary: Sendable {
    let sourceFileName: String
    let originalIPASize: Int64
    let workspaceRoot: URL
    let appBundleURL: URL
    let infoPlistURL: URL
    let displayName: String
    let bundleID: String
    let version: String
    let buildNumber: String
    let minOS: String
    let executableName: String
    let fileSharingEnabled: Bool
    let hasSupportedDevicesLimit: Bool
    let hasPlugIns: Bool
    let hasWatchDir: Bool
    let hasCodeSignature: Bool
    let urlSchemeCount: Int
    let removableLprojCount: Int
    let pluginNames: [String]
    let frameworkNames: [String]
    let totalFilesCount: Int
    let provisionSummary: String?
    let machO: MachOInfo?
    let sha256Short: String
    let iconPath: URL?
}

struct UndoSnapshotEntry {
    let targetURL: URL
    let backupURL: URL?
    let existedBefore: Bool
}

struct ToastBannerData: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

// MARK: - AI Providers & High-Speed Resilient Engine (v5.5)
enum GeminiEndpointMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "Tự động"
    case vertex = "Vertex AI (aiplatform)"
    case aiStudio = "AI Studio (generativelanguage)"

    var id: String { rawValue }
}

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini = "Google Gemini"
    case openrouter = "OpenRouter (Free / All)"
    case groq = "Groq (Siêu nhanh)"
    case openai = "OpenAI"
    case claude = "Anthropic Claude"
    case deepseek = "DeepSeek"
    case grok = "xAI Grok"
    case custom = "Custom OpenAI API"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gemini: return "sparkles"
        case .openrouter: return "network"
        case .groq: return "bolt.fill"
        case .openai: return "brain.head.profile"
        case .claude: return "cpu"
        case .deepseek: return "magnifyingglass.circle"
        case .grok: return "flame.fill"
        case .custom: return "server.rack"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .gemini: return "https://aiplatform.googleapis.com/v1/publishers/google/models"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .grok: return "https://api.x.ai/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        }
    }

    var presetModels: [String] {
        switch self {
        case .gemini:
            return ["gemini-3.8-flash", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .openrouter:
            return ["google/gemma-3-27b-it:free", "deepseek/deepseek-r1-0528:free", "meta-llama/llama-3.3-70b-instruct:free", "google/gemini-3.8-flash"]
        case .groq:
            return ["openai/gpt-oss-120b", "qwen/qwen3.8-27b", "llama-3.3-70b-versatile"]
        case .openai:
            return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o", "o4-mini"]
        case .claude:
            return ["claude-sonnet-4-20250514", "claude-3-5-haiku-latest"]
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .grok:
            return ["grok-3-mini", "grok-3"]
        case .custom:
            return ["gemini-3.8-flash", "gpt-4o", "claude-sonnet-4"]
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: return "AQ.Ab8RN... hoặc AIza..."
        case .openrouter: return "sk-or-v1-..."
        case .groq: return "gsk_..."
        case .openai: return "sk-proj-..."
        case .claude: return "sk-ant-..."
        case .deepseek: return "sk-..."
        case .grok: return "xai-..."
        case .custom: return "Bearer API Key..."
        }
    }
}

enum AIContextDepth: String, CaseIterable, Identifiable {
    case fast = "Nhanh"
    case deep = "Sâu"

    var id: String { rawValue }
}

struct AIPatchAction: Codable, Identifiable, Sendable {
    var id: String { "\(type)|\(key ?? "")|\(path ?? "")|\(value ?? "")|\(find ?? "")" }
    let type: String
    let key: String?
    let value: String?
    let valueType: String?
    let path: String?
    let content: String?
    let find: String?
    let replace: String?
    let note: String?

    var displayTitle: String {
        switch type {
        case "set_plist": return "Sửa Info.plist: \(key ?? "?") = \(value ?? "")"
        case "delete_plist": return "Xóa key Info.plist: \(key ?? "?")"
        case "patch_plist_file": return "Sửa Plist \(path ?? ""): \(key ?? "?") = \(value ?? "")"
        case "delete_path": return "Xóa tệp/thư mục: \(path ?? "?")"
        case "write_text_file": return "Ghi tệp: \(path ?? "?")"
        case "replace_in_file": return "Thay chuỗi trong \(path ?? "?")"
        default: return note ?? type
        }
    }
}

struct AIPatchEnvelope: Codable, Sendable {
    let summary: String?
    let actions: [AIPatchAction]
}

struct AIMessage: Identifiable, Sendable {
    let id = UUID()
    let isUser: Bool
    var text: String
    var modelBadge: String?
    var patch: AIPatchEnvelope?
    var patchApplied: Bool = false
    var isStreaming: Bool = false
    var failedPrompt: String? = nil
}

struct AIChatTurn: Sendable {
    let isUser: Bool
    let text: String
}

enum AIClient {
    private static func sanitizeAlternatingTurns(_ history: [AIChatTurn]) -> [AIChatTurn] {
        var cleaned: [AIChatTurn] = []
        for turn in history {
            let t = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if cleaned.isEmpty && !turn.isUser { continue }
            if let last = cleaned.last, last.isUser == turn.isUser {
                cleaned[cleaned.count - 1] = AIChatTurn(isUser: last.isUser, text: last.text + "\n\n" + t)
            } else {
                cleaned.append(AIChatTurn(isUser: turn.isUser, text: t))
            }
        }
        return cleaned
    }

    static func send(
        provider: AIProvider,
        model: String,
        apiKey: String,
        geminiMode: GeminiEndpointMode,
        customEndpoint: String,
        useStreaming: Bool,
        systemPrompt: String,
        history: [AIChatTurn],
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "AIClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Chưa nhập API Key cho \(provider.rawValue). Bấm nút Model ở góc trên để dán key."])
        }

        switch provider {
        case .gemini:
            return try await callGemini(model: model, apiKey: cleanKey, mode: geminiMode, useStreaming: useStreaming, systemPrompt: systemPrompt, history: history, onChunk: onChunk)
        case .claude:
            return try await callClaude(model: model, apiKey: cleanKey, useStreaming: useStreaming, systemPrompt: systemPrompt, history: history, onChunk: onChunk)
        case .openrouter, .groq, .openai, .deepseek, .grok, .custom:
            let customClean = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = (provider == .custom && !customClean.isEmpty) ? customClean : provider.defaultEndpoint
            return try await callOpenAI(endpoint: endpoint, model: model, apiKey: cleanKey, useStreaming: useStreaming, systemPrompt: systemPrompt, history: history, onChunk: onChunk)
        }
    }

    private static func callGemini(
        model: String,
        apiKey: String,
        mode: GeminiEndpointMode,
        useStreaming: Bool,
        systemPrompt: String,
        history: [AIChatTurn],
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedModel = cleanModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanModel
        let methodAction = useStreaming ? "streamGenerateContent" : "generateContent"

        let vertexBase = "https://aiplatform.googleapis.com/v1/publishers/google/models/\(encodedModel):\(methodAction)"
        let aiStudioBase = "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):\(methodAction)"

        let candidateBases: [String]
        switch mode {
        case .vertex: candidateBases = [vertexBase]
        case .aiStudio: candidateBases = [aiStudioBase]
        case .auto: candidateBases = apiKey.hasPrefix("AQ.") ? [vertexBase, aiStudioBase] : [aiStudioBase, vertexBase]
        }

        let safeHistory = sanitizeAlternatingTurns(history)
        let contents: [[String: Any]] = safeHistory.map { turn in
            ["role": turn.isUser ? "user" : "model", "parts": [["text": turn.text]]]
        }

        let fastBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ] as [String: Any])

        let plainBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 2048
            ]
        ] as [String: Any])

        let bodies = [fastBody, plainBody]
        var lastError: Error?

        for (baseIdx, baseStr) in candidateBases.enumerated() {
            guard var comps = URLComponents(string: baseStr) else { continue }
            var qItems = [URLQueryItem(name: "key", value: apiKey)]
            if useStreaming { qItems.insert(URLQueryItem(name: "alt", value: "sse"), at: 0) }
            comps.queryItems = qItems
            guard let url = comps.url else { continue }

            for (bodyIdx, payload) in bodies.enumerated() {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload

                do {
                    if useStreaming {
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        try await validateStreamHTTP(response: response, bytes: bytes)
                        var accumulated = ""
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.hasPrefix("data:") else { continue }
                            let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            guard !jsonStr.isEmpty, jsonStr != "[DONE]",
                                  let data = jsonStr.data(using: .utf8),
                                  let text = extractGeminiText(from: data), !text.isEmpty else { continue }
                            accumulated += text
                            await onChunk(text)
                        }
                        if accumulated.isEmpty && !Task.isCancelled {
                            throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Máy chủ không trả về dữ liệu."])
                        }
                        return accumulated
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        try validateDataHTTP(response: response, data: data)
                        let text = extractGeminiText(from: data) ?? ""
                        if !text.isEmpty { await onChunk(text) }
                        return text
                    }
                } catch {
                    lastError = error
                    let code = (error as NSError).code
                    if code == 400 && bodyIdx == 0 && !Task.isCancelled {
                        continue
                    }
                    break
                }
            }

            let code = (lastError as NSError?)?.code ?? 0
            let canTryNextBase = (baseIdx + 1 < candidateBases.count) && (code == 403 || code == 401 || code == 404 || code == 400)
            if canTryNextBase && !Task.isCancelled {
                continue
            }
            break
        }

        throw enrichError(lastError ?? NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Không kết nối được Google API."]))
    }

    private static func extractGeminiText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        var out = ""
        for part in parts {
            if (part["thought"] as? Bool) == true { continue }
            if let piece = part["text"] as? String { out += piece }
        }
        return out
    }

    private static func callClaude(
        model: String,
        apiKey: String,
        useStreaming: Bool,
        systemPrompt: String,
        history: [AIChatTurn],
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard let url = URL(string: AIProvider.claude.defaultEndpoint) else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "URL Claude không hợp lệ."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 35
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let safeHistory = sanitizeAlternatingTurns(history)
        let messages: [[String: Any]] = safeHistory.map { ["role": $0.isUser ? "user" : "assistant", "content": $0.text] }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": useStreaming,
            "system": systemPrompt,
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        if useStreaming {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            try await validateStreamHTTP(response: response, bytes: bytes)
            var accumulated = ""
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "content_block_delta",
                      let delta = json["delta"] as? [String: Any],
                      let piece = delta["text"] as? String, !piece.isEmpty else { continue }
                accumulated += piece
                await onChunk(piece)
            }
            return accumulated
        } else {
            let (data, response) = try await URLSession.shared.data(for: req)
            try validateDataHTTP(response: response, data: data)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { await onChunk(text) }
                return text
            }
            return ""
        }
    }

    private static func callOpenAI(
        endpoint: String,
        model: String,
        apiKey: String,
        useStreaming: Bool,
        systemPrompt: String,
        history: [AIChatTurn],
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Endpoint API không hợp lệ."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 35
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in sanitizeAlternatingTurns(history) {
            messages.append(["role": turn.isUser ? "user" : "assistant", "content": turn.text])
        }
        let body: [String: Any] = [
            "model": model,
            "stream": useStreaming,
            "messages": messages,
            "temperature": 0.2
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        if useStreaming {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            try await validateStreamHTTP(response: response, bytes: bytes)
            var accumulated = ""
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !jsonStr.isEmpty, jsonStr != "[DONE]",
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                accumulated += piece
                await onChunk(piece)
            }
            return accumulated
        } else {
            let (data, response) = try await URLSession.shared.data(for: req)
            try validateDataHTTP(response: response, data: data)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let text = msg["content"] as? String {
                if !text.isEmpty { await onChunk(text) }
                return text
            }
            return ""
        }
    }

    static func fetchModels(provider: AIProvider, apiKey: String, geminiMode: GeminiEndpointMode, customEndpoint: String) async throws -> [String] {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "AIClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Hãy dán API Key trước khi quét danh sách model."])
        }

        if provider == .gemini {
            let vertexBase = "https://aiplatform.googleapis.com/v1/publishers/google/models"
            let aiStudioBase = "https://generativelanguage.googleapis.com/v1beta/models"
            let bases: [String]
            switch geminiMode {
            case .vertex: bases = [vertexBase]
            case .aiStudio: bases = [aiStudioBase]
            case .auto: bases = cleanKey.hasPrefix("AQ.") ? [vertexBase, aiStudioBase] : [aiStudioBase, vertexBase]
            }

            var lastErr: Error?
            for base in bases {
                guard var comps = URLComponents(string: base) else { continue }
                comps.queryItems = [URLQueryItem(name: "key", value: cleanKey)]
                guard let url = comps.url else { continue }
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 18
                    let (data, response) = try await URLSession.shared.data(for: req)
                    try validateDataHTTP(response: response, data: data)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["models"] as? [[String: Any]] {
                        let names = models.compactMap { item -> String? in
                            guard let raw = item["name"] as? String else { return nil }
                            if let methods = item["supportedGenerationMethods"] as? [String],
                               !methods.contains("generateContent") { return nil }
                            return raw.components(separatedBy: "/").last
                        }
                        if !names.isEmpty { return names }
                    }
                } catch {
                    lastErr = error
                }
            }
            if let err = lastErr { throw enrichError(err) }
            return provider.presetModels
        }

        let modelsEndpoint: String
        switch provider {
        case .openai: modelsEndpoint = "https://api.openai.com/v1/models"
        case .groq: modelsEndpoint = "https://api.groq.com/openai/v1/models"
        case .deepseek: modelsEndpoint = "https://api.deepseek.com/models"
        case .grok: modelsEndpoint = "https://api.x.ai/v1/models"
        case .openrouter: modelsEndpoint = "https://openrouter.ai/api/v1/models"
        case .claude: modelsEndpoint = "https://api.anthropic.com/v1/models"
        case .custom:
            let base = customEndpoint.replacingOccurrences(of: "/chat/completions", with: "")
            modelsEndpoint = base.hasSuffix("/") ? "\(base)models" : "\(base)/models"
        case .gemini:
            modelsEndpoint = ""
        }

        guard let url = URL(string: modelsEndpoint) else { return provider.presetModels }
        var req = URLRequest(url: url)
        req.timeoutInterval = 18
        if provider == .claude {
            req.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateDataHTTP(response: response, data: data)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [[String: Any]] {
            let ids = list.compactMap { $0["id"] as? String }.sorted()
            if !ids.isEmpty { return ids }
        }
        return provider.presetModels
    }

    private static func validateStreamHTTP(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        var errText = ""
        for try await line in bytes.lines {
            errText += line
            if errText.count > 460 { break }
        }
        throw NSError(domain: "AIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi API (\(http.statusCode)): \(errText)"])
    }

    private static func validateDataHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        let errText = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "AIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi API (\(http.statusCode)): \(String(errText.prefix(460)))"])
    }

    private static func enrichError(_ error: Error) -> Error {
        let ns = error as NSError
        let msg = ns.localizedDescription
        if ns.code == NSURLErrorTimedOut {
            return NSError(domain: "AIClient", code: ns.code, userInfo: [NSLocalizedDescriptionKey: "Quá thời gian phản hồi (30s). Hãy bấm Thử lại hoặc vào AI API tắt Streaming."])
        }
        if ns.code == 403 && (msg.contains("aiplatform.googleapis.com") || msg.contains("PERMISSION_DENIED")) {
            return NSError(domain: "AIClient", code: 403, userInfo: [NSLocalizedDescriptionKey: "Dự án Google Cloud chưa bật Vertex AI API (aiplatform.googleapis.com). Hãy bật trong Google Cloud Console hoặc chuyển sang dùng OpenRouter.\n\nChi tiết: \(msg)"])
        }
        return error
    }
}

// MARK: - AI Patch Parser & Executor
enum AIPatchEngine {
    static func extractPatch(from text: String) -> (cleanText: String, patch: AIPatchEnvelope?) {
        let markers = ["```ipa_patch", "```json"]
        for marker in markers {
            guard let startRange = text.range(of: marker) else { continue }
            let afterStart = startRange.upperBound
            guard let endRange = text.range(of: "```", range: afterStart..<text.endIndex) else { continue }
            let rawJSON = String(text[afterStart..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = rawJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(AIPatchEnvelope.self, from: data),
               !decoded.actions.isEmpty {
                var stripped = text
                stripped.removeSubrange(startRange.lowerBound..<endRange.upperBound)
                return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), decoded)
            }
        }
        return (text, nil)
    }

    static func resolveSafeURL(_ relPath: String, appBundleURL: URL, workspaceRoot: URL) -> URL? {
        let clean = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty, !clean.contains("..") else { return nil }
        let candidate = clean.hasPrefix("Payload/")
            ? workspaceRoot.appendingPathComponent(clean)
            : appBundleURL.appendingPathComponent(clean)
        guard candidate.standardizedFileURL.path.hasPrefix(workspaceRoot.standardizedFileURL.path) else { return nil }
        return candidate
    }

    static func targetURLs(for actions: [AIPatchAction], appBundleURL: URL, workspaceRoot: URL) -> [URL] {
        var urls: [URL] = []
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        for action in actions {
            switch action.type {
            case "set_plist", "delete_plist":
                if !urls.contains(infoURL) { urls.append(infoURL) }
            case "patch_plist_file", "delete_path", "write_text_file", "replace_in_file":
                if let p = action.path, let u = resolveSafeURL(p, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot), !urls.contains(u) {
                    urls.append(u)
                }
            default:
                break
            }
        }
        return urls
    }

    static func apply(actions: [AIPatchAction], appBundleURL: URL, workspaceRoot: URL) -> [String] {
        var logs: [String] = []
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        let fm = FileManager.default

        func convertValue(_ raw: String, type: String?) -> Any {
            switch (type ?? "string").lowercased() {
            case "bool", "boolean":
                return ["true", "1", "yes"].contains(raw.lowercased())
            case "int", "integer", "number":
                return Int(raw) ?? 0
            case "array", "array_string":
                return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            default:
                return raw
            }
        }

        for action in actions {
            switch action.type {
            case "set_plist":
                guard let key = action.key, let val = action.value, var dict = PlistHelper.readDict(url: infoURL) else {
                    logs.append("⚠️ Bỏ qua set_plist (thiếu key/value)")
                    continue
                }
                dict[key] = convertValue(val, type: action.valueType)
                do {
                    try PlistHelper.writeDict(dict, to: infoURL)
                    logs.append("✓ Sửa Info.plist: \(key) = \(val)")
                } catch {
                    logs.append("❌ Lỗi ghi Info.plist: \(error.localizedDescription)")
                }

            case "delete_plist":
                guard let key = action.key, var dict = PlistHelper.readDict(url: infoURL) else { continue }
                dict.removeValue(forKey: key)
                do {
                    try PlistHelper.writeDict(dict, to: infoURL)
                    logs.append("✓ Đã xóa key Info.plist: \(key)")
                } catch {
                    logs.append("❌ Lỗi xóa key \(key): \(error.localizedDescription)")
                }

            case "patch_plist_file":
                guard let rel = action.path, let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                      let key = action.key, var dict = PlistHelper.readDict(url: target) else {
                    logs.append("⚠️ Không đọc được Plist: \(action.path ?? "")")
                    continue
                }
                if let val = action.value {
                    dict[key] = convertValue(val, type: action.valueType)
                } else {
                    dict.removeValue(forKey: key)
                }
                do {
                    try PlistHelper.writeDict(dict, to: target)
                    logs.append("✓ Sửa \(rel): \(key)")
                } catch {
                    logs.append("❌ Lỗi lưu \(rel): \(error.localizedDescription)")
                }

            case "delete_path":
                guard let rel = action.path, let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot) else {
                    logs.append("⚠️ Đường dẫn không hợp lệ: \(action.path ?? "")")
                    continue
                }
                if fm.fileExists(atPath: target.path) {
                    do {
                        try fm.removeItem(at: target)
                        logs.append("✓ Đã xóa: \(rel)")
                    } catch {
                        logs.append("❌ Lỗi xóa \(rel): \(error.localizedDescription)")
                    }
                } else {
                    logs.append("• Không tồn tại: \(rel)")
                }

            case "write_text_file":
                guard let rel = action.path, let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                      let content = action.content else {
                    logs.append("⚠️ Thiếu nội dung cho write_text_file")
                    continue
                }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(content.utf8).write(to: target, options: .atomic)
                    logs.append("✓ Đã ghi tệp: \(rel)")
                } catch {
                    logs.append("❌ Lỗi ghi \(rel): \(error.localizedDescription)")
                }

            case "replace_in_file":
                guard let rel = action.path, let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                      let find = action.find, let replace = action.replace,
                      let text = try? String(contentsOf: target, encoding: .utf8) else {
                    logs.append("⚠️ Không đọc được tệp để thay chuỗi: \(action.path ?? "")")
                    continue
                }
                let updated = text.replacingOccurrences(of: find, with: replace)
                do {
                    try Data(updated.utf8).write(to: target, options: .atomic)
                    logs.append("✓ Đã thay chuỗi trong \(rel)")
                } catch {
                    logs.append("❌ Lỗi ghi \(rel): \(error.localizedDescription)")
                }

            default:
                logs.append("⚠️ Không hỗ trợ lệnh: \(action.type)")
            }
        }
        return logs
    }
}

// MARK: - Studio Store Manager (v5.5)
@MainActor
final class IPAStudioManager: ObservableObject {
    @Published var summary: IPAWorkspaceSummary?
    @Published var isBusy = false
    @Published var busyTitle = ""
    @Published var busyProgress: Double = 0
    @Published var busyDetail = ""
    @Published var alertMessage: String?
    @Published var toast: ToastBannerData?
    @Published var changeLog: [String] = []
    @Published var pinnedFilesForAI: [String] = []
    @Published var scannedBinaryURLs: [String] = []
    @Published var includeBinaryURLsInAI = false
    @Published var includeEntitlementsInAI = false
    @Published var isScanningBinary = false
    @Published var canUndo = false
    @Published var iconRefreshID = UUID()

    // AI Config
    @Published var selectedProvider: AIProvider = .gemini {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: providerKey) }
    }
    @Published var selectedModel: String = "gemini-3.8-flash" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: modelKey) }
    }
    @Published var geminiEndpointMode: GeminiEndpointMode = .auto {
        didSet { UserDefaults.standard.set(geminiEndpointMode.rawValue, forKey: geminiModeKey) }
    }
    @Published var contextDepth: AIContextDepth = .fast {
        didSet { UserDefaults.standard.set(contextDepth.rawValue, forKey: depthKey) }
    }
    @Published var useStreaming: Bool = true {
        didSet { UserDefaults.standard.set(useStreaming, forKey: streamingKey) }
    }
    @Published var apiKeys: [String: String] = [:] {
        didSet { UserDefaults.standard.set(apiKeys, forKey: keysStorageKey) }
    }
    @Published var customEndpoint: String = "" {
        didSet { UserDefaults.standard.set(customEndpoint, forKey: customEndpointKey) }
    }
    @Published var compressOnExport: Bool = true {
        didSet { UserDefaults.standard.set(compressOnExport, forKey: compressKey) }
    }
    @Published var messages: [AIMessage] = []
    @Published var isAIThinking = false
    @Published var waitingSeconds = 0

    private var aiStreamTask: Task<Void, Never>?
    private var waitTimerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastUndoEntries: [UndoSnapshotEntry] = []

    private let providerKey = "IPAStudio_v55_Provider"
    private let modelKey = "IPAStudio_v55_Model"
    private let geminiModeKey = "IPAStudio_v55_GeminiMode"
    private let depthKey = "IPAStudio_v55_Depth"
    private let streamingKey = "IPAStudio_v55_Streaming"
    private let keysStorageKey = "IPAStudio_v55_APIKeys"
    private let customEndpointKey = "IPAStudio_CustomEndpoint"
    private let compressKey = "IPAStudio_Compress"
    private let lastSourceNameKey = "IPAStudio_v55_LastSource"
    private let lastSourceSizeKey = "IPAStudio_v55_LastSize"
    private let lastSourceSHAKey = "IPAStudio_v55_LastSHA"

    var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var workspaceDir: URL {
        documentsDir.appendingPathComponent("ActiveIPAWorkspace", isDirectory: true)
    }

    var undoBackupDir: URL {
        documentsDir.appendingPathComponent("UndoBackup", isDirectory: true)
    }

    var exportsDir: URL {
        let dir = documentsDir.appendingPathComponent("ExportedIPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var currentAPIKey: String {
        apiKeys[selectedProvider.rawValue] ?? ""
    }

    init() {
        if let rawP = UserDefaults.standard.string(forKey: providerKey),
           let parsed = AIProvider(rawValue: rawP) {
            selectedProvider = parsed
        }
        if let savedM = UserDefaults.standard.string(forKey: modelKey), !savedM.isEmpty {
            selectedModel = savedM
        }
        if let rawMode = UserDefaults.standard.string(forKey: geminiModeKey),
           let parsedMode = GeminiEndpointMode(rawValue: rawMode) {
            geminiEndpointMode = parsedMode
        }
        if let rawD = UserDefaults.standard.string(forKey: depthKey),
           let parsedD = AIContextDepth(rawValue: rawD) {
            contextDepth = parsedD
        }
        if UserDefaults.standard.object(forKey: streamingKey) != nil {
            useStreaming = UserDefaults.standard.bool(forKey: streamingKey)
        }
        if let savedKeys = UserDefaults.standard.dictionary(forKey: keysStorageKey) as? [String: String] {
            apiKeys = savedKeys
        } else if let legacyKeys = UserDefaults.standard.dictionary(forKey: "IPAStudio_v5_APIKeys") as? [String: String]
                    ?? UserDefaults.standard.dictionary(forKey: "IPAStudio_v45_APIKeys") as? [String: String] {
            var migrated: [String: String] = [:]
            for (k, v) in legacyKeys {
                if k.contains("Gemini") { migrated[AIProvider.gemini.rawValue] = v }
                else if k.contains("OpenRouter") { migrated[AIProvider.openrouter.rawValue] = v }
                else if k.contains("Groq") { migrated[AIProvider.groq.rawValue] = v }
                else { migrated[k] = v }
            }
            apiKeys = migrated
        }
        customEndpoint = UserDefaults.standard.string(forKey: customEndpointKey) ?? ""
        if UserDefaults.standard.object(forKey: compressKey) != nil {
            compressOnExport = UserDefaults.standard.bool(forKey: compressKey)
        }

        // Tự khôi phục IPA đang làm việc từ phiên trước
        Task { await restoreExistingWorkspaceIfNeeded() }
    }

    func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.snappy) {
            toast = ToastBannerData(text: text, isError: isError)
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled {
                withAnimation(.snappy) { self.toast = nil }
            }
        }
    }

    func setAPIKey(_ value: String, for provider: AIProvider) {
        apiKeys[provider.rawValue] = value
    }

    func switchProvider(_ provider: AIProvider) {
        selectedProvider = provider
        if !provider.presetModels.contains(selectedModel) {
            selectedModel = provider.presetModels.first ?? ""
        }
    }

    private func restoreExistingWorkspaceIfNeeded() async {
        let root = workspaceDir
        let payloadDir = root.appendingPathComponent("Payload")
        guard FileManager.default.fileExists(atPath: payloadDir.path) else { return }
        let srcName = UserDefaults.standard.string(forKey: lastSourceNameKey) ?? "Restored.ipa"
        let origSize = Int64(UserDefaults.standard.integer(forKey: lastSourceSizeKey))
        let sha = UserDefaults.standard.string(forKey: lastSourceSHAKey) ?? "N/A"
        if let analyzed = try? await Task.detached(priority: .utility, operation: {
            try Self.analyzeWorkspace(root: root, sourceName: srcName, originalSize: origSize, shaShort: sha)
        }).value {
            self.summary = analyzed
        }
    }

    // MARK: - Undo Snapshot System
    private func recordUndoSnapshot(for targets: [URL]) {
        let fm = FileManager.default
        try? fm.removeItem(at: undoBackupDir)
        try? fm.createDirectory(at: undoBackupDir, withIntermediateDirectories: true)

        var entries: [UndoSnapshotEntry] = []
        for (i, target) in targets.enumerated() {
            if fm.fileExists(atPath: target.path) {
                let backup = undoBackupDir.appendingPathComponent("bak_\(i)_\(target.lastPathComponent)")
                if (try? fm.copyItem(at: target, to: backup)) != nil {
                    entries.append(UndoSnapshotEntry(targetURL: target, backupURL: backup, existedBefore: true))
                }
            } else {
                entries.append(UndoSnapshotEntry(targetURL: target, backupURL: nil, existedBefore: false))
            }
        }
        lastUndoEntries = entries
        canUndo = !entries.isEmpty
    }

    func performUndo() {
        guard !lastUndoEntries.isEmpty else { return }
        let fm = FileManager.default
        for entry in lastUndoEntries.reversed() {
            if fm.fileExists(atPath: entry.targetURL.path) {
                try? fm.removeItem(at: entry.targetURL)
            }
            if entry.existedBefore, let backup = entry.backupURL, fm.fileExists(atPath: backup.path) {
                try? fm.createDirectory(at: entry.targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: backup, to: entry.targetURL)
            }
        }
        lastUndoEntries = []
        canUndo = false
        changeLog.insert("↩️ Đã hoàn tác thay đổi gần nhất", at: 0)
        iconRefreshID = UUID()
        refreshWorkspace()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("Đã hoàn tác thay đổi gần nhất")
    }

    // MARK: - Import & Analyze IPA
    func importIPA(from pickedURL: URL) {
        let ext = pickedURL.pathExtension.lowercased()
        guard ext == "ipa" || ext == "zip" else {
            showToast("Vui lòng chọn đúng file đuôi .ipa", isError: true)
            return
        }

        let sourceName = pickedURL.lastPathComponent
        let destRoot = workspaceDir
        isBusy = true
        busyTitle = "Đang giải nén \(sourceName)"
        busyProgress = 0.05
        busyDetail = "Đọc cấu trúc ZIP..."

        Task {
            do {
                let originalSize = (try? FileManager.default.attributesOfItem(atPath: pickedURL.path)[.size] as? Int64) ?? 0
                let sha = await Self.computeShortSHA256(url: pickedURL)

                try await Task.detached(priority: .userInitiated) {
                    try ZIPArchive.extract(ipaURL: pickedURL, to: destRoot) { prog, fileName in
                        Task { @MainActor in
                            self.busyProgress = prog
                            self.busyDetail = fileName
                        }
                    }
                }.value

                busyTitle = "Đang phân tích IPA..."
                busyDetail = "Soi Info.plist, Mach-O & Entitlements"
                let analyzed = try await Task.detached(priority: .userInitiated) {
                    try Self.analyzeWorkspace(root: destRoot, sourceName: sourceName, originalSize: originalSize, shaShort: sha)
                }.value

                UserDefaults.standard.set(sourceName, forKey: lastSourceNameKey)
                UserDefaults.standard.set(Int(originalSize), forKey: lastSourceSizeKey)
                UserDefaults.standard.set(sha, forKey: lastSourceSHAKey)

                self.summary = analyzed
                self.pinnedFilesForAI = []
                self.scannedBinaryURLs = []
                self.includeBinaryURLsInAI = false
                self.includeEntitlementsInAI = false
                self.lastUndoEntries = []
                self.canUndo = false
                self.iconRefreshID = UUID()
                self.changeLog = ["Đã mở gói: \(sourceName)"]
                self.isBusy = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.showToast("Đã mở \(analyzed.displayName)")
            } catch {
                self.isBusy = false
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func refreshWorkspace() {
        guard let current = summary else { return }
        let root = current.workspaceRoot
        let srcName = current.sourceFileName
        let origSize = current.originalIPASize
        let sha = current.sha256Short
        Task {
            if let analyzed = try? await Task.detached(priority: .userInitiated, operation: {
                try Self.analyzeWorkspace(root: root, sourceName: srcName, originalSize: origSize, shaShort: sha)
            }).value {
                self.summary = analyzed
            }
        }
    }

    func scanBinaryStrings() {
        guard let execURL = summary?.machO?.executableURL, !isScanningBinary else { return }
        isScanningBinary = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                BinaryStringsScanner.scanURLs(binaryURL: execURL, maxResults: 150)
            }.value
            self.scannedBinaryURLs = urls
            self.isScanningBinary = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    nonisolated private static func computeShortSHA256(url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "N/A" }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    nonisolated private static func analyzeWorkspace(root: URL, sourceName: String, originalSize: Int64, shaShort: String) throws -> IPAWorkspaceSummary {
        let fm = FileManager.default
        let payloadDir = root.appendingPathComponent("Payload")
        guard let payloadItems = try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil),
              let appBundle = payloadItems.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw ZIPArchiveError.invalidArchive("Không tìm thấy thư mục Payload/*.app bên trong")
        }

        let infoURL = appBundle.appendingPathComponent("Info.plist")
        let plist = PlistHelper.readDict(url: infoURL) ?? [:]

        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appBundle.deletingPathExtension().lastPathComponent
        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? "unknown.bundle.id"
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
        let buildNumber = (plist["CFBundleVersion"] as? String) ?? "1"
        let minOS = (plist["MinimumOSVersion"] as? String) ?? "N/A"
        let execName = (plist["CFBundleExecutable"] as? String) ?? appBundle.deletingPathExtension().lastPathComponent
        let fileSharing = (plist["UIFileSharingEnabled"] as? Bool) ?? false
        let hasDeviceLimit = plist["UISupportedDevices"] != nil
        let urlTypes = (plist["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let schemeCount = urlTypes.reduce(0) { $0 + ((($1["CFBundleURLSchemes"] as? [String])?.count) ?? 0) }
        let removableLproj = LocalizationCleaner.removableURLs(in: appBundle).count

        let plugInsDir = appBundle.appendingPathComponent("PlugIns")
        let plugins = (try? fm.contentsOfDirectory(atPath: plugInsDir.path)) ?? []
        let fwDir = appBundle.appendingPathComponent("Frameworks")
        let frameworks = (try? fm.contentsOfDirectory(atPath: fwDir.path)) ?? []
        let hasWatch = fm.fileExists(atPath: appBundle.appendingPathComponent("Watch").path)
        let hasCodeSig = fm.fileExists(atPath: appBundle.appendingPathComponent("_CodeSignature").path)

        var fileCount = 0
        if let e = fm.enumerator(atPath: appBundle.path) {
            while e.nextObject() != nil { fileCount += 1 }
        }

        let execURL = appBundle.appendingPathComponent(execName)
        let machO = MachOInspector.inspect(binaryURL: execURL)
        let provSummary = PlistHelper.parseEmbeddedProvisionSummary(appBundleURL: appBundle)

        let appItems = (try? fm.contentsOfDirectory(at: appBundle, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let iconURL = appItems
            .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.lowercased().contains("icon") }
            .sorted {
                let s1 = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let s2 = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return s1 > s2
            }
            .first

        return IPAWorkspaceSummary(
            sourceFileName: sourceName,
            originalIPASize: originalSize,
            workspaceRoot: root,
            appBundleURL: appBundle,
            infoPlistURL: infoURL,
            displayName: displayName,
            bundleID: bundleID,
            version: version,
            buildNumber: buildNumber,
            minOS: minOS,
            executableName: execName,
            fileSharingEnabled: fileSharing,
            hasSupportedDevicesLimit: hasDeviceLimit,
            hasPlugIns: !plugins.isEmpty,
            hasWatchDir: hasWatch,
            hasCodeSignature: hasCodeSig,
            urlSchemeCount: schemeCount,
            removableLprojCount: removableLproj,
            pluginNames: plugins,
            frameworkNames: frameworks,
            totalFilesCount: fileCount,
            provisionSummary: provSummary,
            machO: machO,
            sha256Short: shaShort,
            iconPath: iconURL
        )
    }

    // MARK: - Mod Tools
    func injectDylibIntoBinary(dylibURL: URL, weakLoad: Bool) {
        guard let sum = summary else { return }
        let execURL = sum.appBundleURL.appendingPathComponent(sum.executableName)
        let sigURL = sum.appBundleURL.appendingPathComponent("_CodeSignature")
        recordUndoSnapshot(for: [execURL, sigURL])

        let appBundle = sum.appBundleURL
        let execName = sum.executableName
        isBusy = true
        busyTitle = "Đang inject \(dylibURL.lastPathComponent)"
        busyProgress = 0.5
        busyDetail = "Ghi lệnh LC_LOAD_DYLIB vào header Mach-O..."

        Task {
            do {
                let msg = try await Task.detached(priority: .userInitiated) {
                    try MachODylibInjector.inject(dylibSourceURL: dylibURL, into: appBundle, executableName: execName, weakLoad: weakLoad)
                }.value

                self.isBusy = false
                self.changeLog.insert("✓ \(msg)", at: 0)
                self.refreshWorkspace()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.showToast(msg)
            } catch {
                self.isBusy = false
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func stripUnusedLocalizations() {
        guard let sum = summary else { return }
        let targets = LocalizationCleaner.removableURLs(in: sum.appBundleURL)
        guard !targets.isEmpty else {
            showToast("Không có gói ngôn ngữ thừa (.lproj)")
            return
        }
        recordUndoSnapshot(for: targets)

        var totalFreed: Int64 = 0
        var removedCount = 0
        for url in targets {
            totalFreed += LocalizationCleaner.folderSize(url)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removedCount += 1
            }
        }
        let freedStr = ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)
        changeLog.insert("✓ Đã xóa \(removedCount) gói ngôn ngữ (giảm \(freedStr))", at: 0)
        refreshWorkspace()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("Đã dọn \(removedCount) .lproj (tiết kiệm \(freedStr))")
    }

    func applyManualEdits(name: String, bundleID: String, version: String, minOS: String, fileSharing: Bool, removeDeviceLimit: Bool) {
        guard let sum = summary, var dict = PlistHelper.readDict(url: sum.infoPlistURL) else { return }
        recordUndoSnapshot(for: [sum.infoPlistURL])

        dict["CFBundleDisplayName"] = name
        dict["CFBundleName"] = name
        dict["CFBundleIdentifier"] = bundleID
        dict["CFBundleShortVersionString"] = version
        if !minOS.isEmpty && minOS != "N/A" { dict["MinimumOSVersion"] = minOS }
        dict["UIFileSharingEnabled"] = fileSharing
        dict["LSSupportsOpeningDocumentsInPlace"] = fileSharing
        if removeDeviceLimit { dict.removeValue(forKey: "UISupportedDevices") }

        do {
            try PlistHelper.writeDict(dict, to: sum.infoPlistURL)
            changeLog.insert("✓ Đã lưu Info.plist (\(name) • \(bundleID))", at: 0)
            refreshWorkspace()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("Đã lưu Info.plist")
        } catch {
            alertMessage = "Lỗi lưu Info.plist: \(error.localizedDescription)"
        }
    }

    func removeFolderFromApp(_ folderName: String) {
        guard let sum = summary else { return }
        let target = sum.appBundleURL.appendingPathComponent(folderName)
        if FileManager.default.fileExists(atPath: target.path) {
            recordUndoSnapshot(for: [target])
            do {
                try FileManager.default.removeItem(at: target)
                changeLog.insert("✓ Đã xóa \(folderName)", at: 0)
                refreshWorkspace()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showToast("Đã xóa \(folderName)")
            } catch {
                alertMessage = "Không xóa được \(folderName): \(error.localizedDescription)"
            }
        }
    }

    func cleanAllForSideload() {
        guard let sum = summary else { return }
        let fm = FileManager.default
        let targets = ["PlugIns", "Watch", "_CodeSignature"].map { sum.appBundleURL.appendingPathComponent($0) } + [sum.infoPlistURL]
        recordUndoSnapshot(for: targets)

        var removed: [String] = []
        for dir in ["PlugIns", "Watch", "_CodeSignature"] {
            let target = sum.appBundleURL.appendingPathComponent(dir)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
                removed.append(dir)
            }
        }
        if var dict = PlistHelper.readDict(url: sum.infoPlistURL) {
            dict["UIFileSharingEnabled"] = true
            dict["LSSupportsOpeningDocumentsInPlace"] = true
            dict.removeValue(forKey: "UISupportedDevices")
            try? PlistHelper.writeDict(dict, to: sum.infoPlistURL)
        }
        let note = removed.isEmpty ? "Đã bật FileSharing & gỡ giới hạn thiết bị" : "Đã xóa \(removed.joined(separator: ", ")) & tối ưu Info.plist"
        changeLog.insert("✓ \(note)", at: 0)
        refreshWorkspace()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("Đã tối ưu Sideload xong")
    }

    func applyCloneSchemeFix() {
        guard let sum = summary, var dict = PlistHelper.readDict(url: sum.infoPlistURL) else { return }
        recordUndoSnapshot(for: [sum.infoPlistURL])

        let currentBID = (dict["CFBundleIdentifier"] as? String) ?? sum.bundleID
        if !currentBID.hasSuffix(".clone") {
            dict["CFBundleIdentifier"] = currentBID + ".clone"
        }
        let currentName = (dict["CFBundleDisplayName"] as? String) ?? sum.displayName
        if !currentName.contains("Clone") {
            dict["CFBundleDisplayName"] = currentName + " Clone"
            dict["CFBundleName"] = currentName + " Clone"
        }
        if var urlTypes = dict["CFBundleURLTypes"] as? [[String: Any]] {
            for i in urlTypes.indices {
                if let schemes = urlTypes[i]["CFBundleURLSchemes"] as? [String] {
                    urlTypes[i]["CFBundleURLSchemes"] = schemes.map { $0.hasSuffix("-clone") ? $0 : "\($0)-clone" }
                }
            }
            dict["CFBundleURLTypes"] = urlTypes
        }

        do {
            try PlistHelper.writeDict(dict, to: sum.infoPlistURL)
            changeLog.insert("✓ Đã nhân bản Bundle ID & URL Schemes", at: 0)
            refreshWorkspace()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("Đã nhân bản Bundle ID & URL Schemes")
        } catch {
            alertMessage = "Lỗi sửa Clone: \(error.localizedDescription)"
        }
    }

    func applyBypassForceUpdate() {
        guard let sum = summary, var dict = PlistHelper.readDict(url: sum.infoPlistURL) else { return }
        recordUndoSnapshot(for: [sum.infoPlistURL])
        dict["CFBundleShortVersionString"] = "99.9.9"
        dict["CFBundleVersion"] = "99999"
        do {
            try PlistHelper.writeDict(dict, to: sum.infoPlistURL)
            changeLog.insert("✓ Đã giả lập phiên bản 99.9.9 (99999)", at: 0)
            refreshWorkspace()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("Đã nâng phiên bản giả lập 99.9.9")
        } catch {
            alertMessage = "Lỗi sửa phiên bản: \(error.localizedDescription)"
        }
    }

    func replaceAppIconsBatch(with imageURL: URL) {
        guard let sum = summary else { return }
        do {
            let count = try AppIconBatchReplacer.replaceAllIcons(in: sum.appBundleURL, with: imageURL)
            iconRefreshID = UUID()
            if count > 0 {
                changeLog.insert("✓ Đã thay \(count) file AppIcon", at: 0)
                refreshWorkspace()
                showToast("Đã thay \(count) ảnh AppIcon")
            } else {
                alertMessage = "Không tìm thấy file AppIcon*.png trực tiếp trong .app (app có thể lưu icon trong Assets.car)."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func exportEditedIPA() {
        guard let sum = summary else { return }
        let safeBase = sum.displayName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let outURL = exportsDir.appendingPathComponent("\(safeBase)_Edited.ipa")
        let root = sum.workspaceRoot
        let compress = compressOnExport

        isBusy = true
        busyTitle = "Đang đóng gói \(safeBase)_Edited.ipa"
        busyProgress = 0.05
        busyDetail = "Chuẩn bị dữ liệu..."

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ZIPArchive.pack(sourceDir: root, to: outURL, compressFiles: compress) { prog, fileName in
                        Task { @MainActor in
                            self.busyProgress = prog
                            self.busyDetail = fileName
                        }
                    }
                }.value

                self.isBusy = false
                self.changeLog.insert("✓ Đã xuất: \(outURL.lastPathComponent)", at: 0)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                NativeShareHelper.share(url: outURL)
            } catch {
                self.isBusy = false
                self.alertMessage = "Lỗi đóng gói IPA: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - File Explorer & Deep Search Helpers
    func listDirectory(_ dirURL: URL) -> [IPAFileNode] {
        guard let sum = summary else { return [] }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        let appRootPath = sum.appBundleURL.standardizedFileURL.path

        return items.map { url in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = vals?.isDirectory ?? false
            let size = Int64(vals?.fileSize ?? 0)
            let stdPath = url.standardizedFileURL.path
            var rel = stdPath
            if stdPath.hasPrefix(appRootPath) {
                rel = String(stdPath.dropFirst(appRootPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
            }
            return IPAFileNode(url: url, name: url.lastPathComponent, relativePath: rel, isDirectory: isDir, sizeBytes: size)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func searchAllFiles(in appBundleURL: URL, query: String, limit: Int = 120) -> [IPAFileNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: appBundleURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return []
        }
        let rootPath = appBundleURL.standardizedFileURL.path
        var matches: [IPAFileNode] = []

        for case let url as URL in enumerator {
            if matches.count >= limit { break }
            let name = url.lastPathComponent
            if name.localizedCaseInsensitiveContains(q) {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = vals?.isDirectory ?? false
                let size = Int64(vals?.fileSize ?? 0)
                let stdPath = url.standardizedFileURL.path
                var rel = stdPath
                if stdPath.hasPrefix(rootPath) {
                    rel = String(stdPath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                }
                matches.append(IPAFileNode(url: url, name: name, relativePath: rel, isDirectory: isDir, sizeBytes: size))
            }
        }
        return matches
    }

    func injectFiles(_ urls: [URL], into targetDir: URL) {
        let fm = FileManager.default
        var added = 0
        for src in urls {
            let dest = targetDir.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                added += 1
            } catch {
                alertMessage = "Không chèn được \(src.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if added > 0 {
            changeLog.insert("✓ Đã chèn \(added) tệp vào \(targetDir.lastPathComponent)", at: 0)
            refreshWorkspace()
            showToast("Đã chèn \(added) tệp")
        }
    }

    func replaceFile(at targetURL: URL, with sourceURL: URL, relativePath: String) {
        recordUndoSnapshot(for: [targetURL])
        do {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: targetURL, options: .atomic)
            changeLog.insert("✓ Đã thay tệp: \(relativePath)", at: 0)
            iconRefreshID = UUID()
            refreshWorkspace()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("Đã thay tệp thành công")
        } catch {
            alertMessage = "Lỗi thay tệp: \(error.localizedDescription)"
        }
    }

    func togglePinForAI(_ relativePath: String) {
        if let idx = pinnedFilesForAI.firstIndex(of: relativePath) {
            pinnedFilesForAI.remove(at: idx)
            showToast("Đã bỏ ghim tệp khỏi AI")
        } else {
            pinnedFilesForAI.append(relativePath)
            showToast("Đã ghim tệp cho AI")
        }
    }

    // MARK: - AI Context Builder & Resilient Execution
    private func buildIPAContext() -> String {
        guard let sum = summary else {
            return "Hiện người dùng CHƯA nhập file IPA nào."
        }
        var lines: [String] = []
        lines.append("=== IPA ĐANG MỞ ===")
        lines.append("File: \(sum.sourceFileName) (\(ByteCountFormatter.string(fromByteCount: sum.originalIPASize, countStyle: .file)))")
        lines.append("Name: \(sum.displayName) | BundleID: \(sum.bundleID) | Ver: \(sum.version) (\(sum.buildNumber)) | MinOS: \(sum.minOS)")
        lines.append("Exec: \(sum.executableName) | Files: \(sum.totalFilesCount) | FileSharing: \(sum.fileSharingEnabled) | DeviceLimit: \(sum.hasSupportedDevicesLimit) | CodeSig: \(sum.hasCodeSignature) | URLSchemes: \(sum.urlSchemeCount)")
        if !sum.pluginNames.isEmpty { lines.append("PlugIns: \(sum.pluginNames.joined(separator: ", "))") }
        if !sum.frameworkNames.isEmpty { lines.append("Frameworks (\(sum.frameworkNames.count)): \(sum.frameworkNames.prefix(30).joined(separator: ", "))") }
        if let prov = sum.provisionSummary { lines.append("Provision: \(prov)") }

        if let m = sum.machO {
            let enc = m.isEncrypted == nil ? "None" : (m.isEncrypted == true ? "ENCRYPTED(cryptid=\(m.cryptID ?? 1))" : "Decrypted(0)")
            lines.append("Mach-O: arch=\(m.architectures.joined(separator: ",")) | FairPlay=\(enc) | SDK=\(m.sdkVersion ?? "N/A") | InjectedDylibs=\(m.injectedDylibs.joined(separator: ", "))")
            if (includeEntitlementsInAI || contextDepth == .deep), let ent = m.entitlementsXML {
                lines.append("\n=== ENTITLEMENTS ===\n\(String(ent.prefix(3500)))")
            }
        }

        if includeBinaryURLsInAI && !scannedBinaryURLs.isEmpty {
            lines.append("\n=== URL TRÍCH TỪ MACH-O BINARY (\(scannedBinaryURLs.count)) ===")
            lines.append(scannedBinaryURLs.prefix(60).joined(separator: "\n"))
        }

        if contextDepth == .deep {
            let topNodes = listDirectory(sum.appBundleURL).prefix(50)
            lines.append("\n=== TỆP GỐC .APP ===")
            for n in topNodes { lines.append("- \(n.name) (\(n.formattedSize))") }

            if let xml = PlistHelper.plistToXMLString(url: sum.infoPlistURL) {
                lines.append("\n=== INFO.PLIST (XML) ===")
                lines.append(String(xml.prefix(9000)))
            }
        }

        if !pinnedFilesForAI.isEmpty {
            lines.append("\n=== TỆP GHIM ===")
            for rel in pinnedFilesForAI.prefix(4) {
                let fileURL = sum.appBundleURL.appendingPathComponent(rel)
                let content: String
                if fileURL.pathExtension.lowercased() == "plist", let xml = PlistHelper.plistToXMLString(url: fileURL) {
                    content = xml
                } else {
                    content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(Binary)"
                }
                lines.append("--- \(rel) ---\n\(String(content.prefix(4500)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func buildSystemPrompt() -> String {
        """
        Bạn là chuyên gia iOS Reverse Engineering & IPA Modding trong TueeHub IPA Studio v5.5. Trả lời tiếng Việt ngắn gọn, kỹ thuật chuẩn xác.

        Dữ liệu IPA hiện tại:
        \(buildIPAContext())

        QUY TẮC SỬA TỰ ĐỘNG:
        Khi người dùng yêu cầu chỉnh sửa IPA, bên cạnh giải thích ngắn, xuất ĐÚNG MỘT khối ```ipa_patch chứa JSON hợp lệ:
        ```ipa_patch
        {
          "summary": "Mô tả ngắn",
          "actions": [
            {"type": "set_plist", "key": "CFBundleDisplayName", "value": "TenMoi", "valueType": "string"},
            {"type": "set_plist", "key": "UIFileSharingEnabled", "value": "true", "valueType": "bool"},
            {"type": "delete_plist", "key": "UISupportedDevices"},
            {"type": "delete_path", "path": "PlugIns"},
            {"type": "patch_plist_file", "path": "Sub/File.plist", "key": "Key", "value": "123", "valueType": "int"},
            {"type": "write_text_file", "path": "config.json", "content": "{...}"},
            {"type": "replace_in_file", "path": "file.txt", "find": "old", "replace": "new"}
          ]
        }
        ```
        `type`: set_plist | delete_plist | patch_plist_file | delete_path | write_text_file | replace_in_file.
        `valueType`: string | bool | int | array. `path` tính từ bên trong `.app`.
        Nếu người dùng chỉ hỏi/phân tích, KHÔNG xuất khối ipa_patch.
        """
    }

    func sendMessage(_ prompt: String, appendUserBubble: Bool = true) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIThinking else { return }

        if appendUserBubble {
            messages.append(AIMessage(isUser: true, text: trimmed, modelBadge: nil, patch: nil))
        }

        let provider = selectedProvider
        let activeModel = selectedModel
        let key = currentAPIKey
        let mode = geminiEndpointMode
        let endpoint = customEndpoint
        let streaming = useStreaming
        let sysPrompt = buildSystemPrompt()
        let history = messages.filter { $0.failedPrompt == nil }.suffix(8).map { AIChatTurn(isUser: $0.isUser, text: $0.text) }

        let placeholder = AIMessage(
            isUser: false,
            text: "",
            modelBadge: "\(provider.rawValue) • \(activeModel)",
            patch: nil,
            isStreaming: true
        )
        let replyID = placeholder.id
        messages.append(placeholder)
        isAIThinking = true
        waitingSeconds = 0

        waitTimerTask?.cancel()
        waitTimerTask = Task {
            while !Task.isCancelled && self.isAIThinking {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled && self.isAIThinking {
                    self.waitingSeconds += 1
                }
            }
        }

        aiStreamTask = Task {
            var attempt = 0
            while attempt < 2 {
                attempt += 1
                do {
                    let fullReply = try await AIClient.send(
                        provider: provider,
                        model: activeModel,
                        apiKey: key,
                        geminiMode: mode,
                        customEndpoint: endpoint,
                        useStreaming: streaming,
                        systemPrompt: sysPrompt,
                        history: history
                    ) { chunk in
                        await MainActor.run {
                            if let idx = self.messages.firstIndex(where: { $0.id == replyID }) {
                                self.messages[idx].text += chunk
                            }
                        }
                    }

                    await MainActor.run {
                        self.waitTimerTask?.cancel()
                        if let idx = self.messages.firstIndex(where: { $0.id == replyID }) {
                            self.messages[idx].isStreaming = false
                            let finalRaw = fullReply.isEmpty ? self.messages[idx].text : fullReply
                            let parsed = AIPatchEngine.extractPatch(from: finalRaw)
                            self.messages[idx].text = parsed.cleanText.isEmpty ? (parsed.patch?.summary ?? "Đã hoàn tất.") : parsed.cleanText
                            self.messages[idx].patch = parsed.patch
                        }
                        self.isAIThinking = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    return
                } catch {
                    let nsErr = error as NSError
                    let isTempBusy = (nsErr.code == 503 || nsErr.code == 429)
                    if isTempBusy && attempt == 1 && !Task.isCancelled {
                        await MainActor.run {
                            if let idx = self.messages.firstIndex(where: { $0.id == replyID }) {
                                self.messages[idx].text = ""
                                self.messages[idx].modelBadge = "Đang thử lại (503) • \(activeModel)"
                            }
                        }
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        continue
                    }

                    await MainActor.run {
                        self.waitTimerTask?.cancel()
                        if let idx = self.messages.firstIndex(where: { $0.id == replyID }) {
                            self.messages[idx].isStreaming = false
                            if !Task.isCancelled {
                                self.messages[idx].text = "❌ \(error.localizedDescription)"
                                self.messages[idx].failedPrompt = trimmed
                            } else if self.messages[idx].text.isEmpty {
                                self.messages[idx].text = "Đã dừng."
                            }
                        }
                        self.isAIThinking = false
                    }
                    return
                }
            }
        }
    }

    func retryFailedMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              let prompt = messages[idx].failedPrompt else { return }
        messages.remove(at: idx)
        sendMessage(prompt, appendUserBubble: false)
    }

    func stopAI() {
        aiStreamTask?.cancel()
        aiStreamTask = nil
        waitTimerTask?.cancel()
        waitTimerTask = nil
        isAIThinking = false
        for i in messages.indices where messages[i].isStreaming {
            messages[i].isStreaming = false
        }
    }

    func applyAIPatch(messageID: UUID) {
        guard let sum = summary,
              let idx = messages.firstIndex(where: { $0.id == messageID }),
              let patch = messages[idx].patch else { return }

        let targets = AIPatchEngine.targetURLs(for: patch.actions, appBundleURL: sum.appBundleURL, workspaceRoot: sum.workspaceRoot)
        recordUndoSnapshot(for: targets)

        let logs = AIPatchEngine.apply(actions: patch.actions, appBundleURL: sum.appBundleURL, workspaceRoot: sum.workspaceRoot)
        messages[idx].patchApplied = true
        for l in logs.reversed() { changeLog.insert(l, at: 0) }
        refreshWorkspace()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("Đã áp dụng \(patch.actions.count) thay đổi vào IPA")
    }

    func clearWorkspace() {
        try? FileManager.default.removeItem(at: workspaceDir)
        try? FileManager.default.removeItem(at: undoBackupDir)
        UserDefaults.standard.removeObject(forKey: lastSourceNameKey)
        summary = nil
        pinnedFilesForAI = []
        scannedBinaryURLs = []
        includeBinaryURLsInAI = false
        includeEntitlementsInAI = false
        lastUndoEntries = []
        canUndo = false
        changeLog = []
        showToast("Đã đóng workspace")
    }
}

// MARK: - Root ContentView (Pure iOS 26+ Liquid Glass TabView)
struct ContentView: View {
    @StateObject private var store = IPAStudioManager()

    var body: some View {
        ZStack {
            TabView {
                Tab("IPA", systemImage: "shippingbox.fill") {
                    IPAOverviewTab(store: store)
                }

                Tab("AI Studio", systemImage: "sparkles") {
                    AIStudioTab(store: store)
                }

                Tab("Tệp IPA", systemImage: "folder.fill") {
                    FileExplorerTab(store: store)
                }

                Tab("AI API", systemImage: "cpu") {
                    APISettingsTab(store: store)
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)

            if store.isBusy {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView(value: store.busyProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                        Text(store.busyTitle)
                            .font(.headline)
                        Text(store.busyDetail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 240)
                    }
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? .red : .green)
                    Text(toast.text)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint((toast.isError ? Color.red : Color.green).opacity(0.18)), in: .capsule)
                .padding(.top, 8)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.isBusy)
        .animation(.snappy, value: store.toast)
        .alert("TueeHub IPA Studio", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

// MARK: - Tab 1: IPA Overview, Mach-O Inspector & Mod Tools
struct IPAOverviewTab: View {
    @ObservedObject var store: IPAStudioManager

    @State private var editName = ""
    @State private var editBundleID = ""
    @State private var editVersion = ""
    @State private var editMinOS = ""
    @State private var editFileSharing = false
    @State private var removeDeviceLimit = false
    @State private var showDylibInjectDialog = false

    private let iconShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        NavigationStack {
            Group {
                if let sum = store.summary {
                    List {
                        // Hero Card với bo góc continuous chuẩn Apple
                        Section {
                            VStack(spacing: 16) {
                                HStack(spacing: 14) {
                                    if let iconURL = sum.iconPath, let img = UIImage(contentsOfFile: iconURL.path) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 66, height: 66)
                                            .clipShape(iconShape)
                                            .overlay(iconShape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.6))
                                            .id(store.iconRefreshID)
                                    } else {
                                        Image(systemName: "app.dashed")
                                            .font(.title)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 66, height: 66)
                                            .background(Color(uiColor: .tertiarySystemFill), in: iconShape)
                                    }

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(sum.displayName)
                                            .font(.title3.weight(.semibold))
                                            .lineLimit(1)
                                        Text(sum.bundleID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        HStack(spacing: 6) {
                                            Text("v\(sum.version)")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 3)
                                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                                .foregroundStyle(.tint)

                                            if let enc = sum.machO?.isEncrypted {
                                                Text(enc ? "FairPlay Mã hóa" : "Đã giải mã")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 9)
                                                    .padding(.vertical, 3)
                                                    .background((enc ? Color.red : Color.green).opacity(0.18), in: Capsule())
                                                    .foregroundStyle(enc ? .red : .green)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }

                                HStack(spacing: 10) {
                                    QuickStatTile(icon: "doc.on.doc", title: "Tệp", value: "\(sum.totalFilesCount)")
                                    QuickStatTile(icon: "cpu", title: "Kiến trúc", value: sum.machO?.architectures.first ?? "N/A")
                                    QuickStatTile(icon: "puzzlepiece.extension", title: "Dylib nhúng", value: "\(sum.machO?.injectedDylibs.count ?? 0)")
                                }

                                Button {
                                    store.exportEditedIPA()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.body.weight(.semibold))
                                        Text("Đóng gói & Xuất IPA")
                                            .font(.headline)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.glassProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                            }
                            .padding(.vertical, 6)
                        }

                        // Mach-O, Dylibs & Entitlements
                        if let m = sum.machO {
                            Section("Mach-O & Binary (\(m.executableName))") {
                                LabeledContent("Dung lượng Binary", value: ByteCountFormatter.string(fromByteCount: m.fileSizeBytes, countStyle: .file))
                                LabeledContent("SHA-256", value: sum.sha256Short)
                                if let sdk = m.sdkVersion {
                                    LabeledContent("SDK / MinOS", value: "iOS \(sdk) / \(m.minOSVersion ?? "N/A")")
                                }
                                NavigationLink {
                                    DylibListView(machO: m)
                                } label: {
                                    LabeledContent("Thư viện Dylib", value: "\(m.injectedDylibs.count) nhúng • \(m.linkedDylibs.count) tổng")
                                }
                                NavigationLink {
                                    EntitlementsViewer(store: store, xml: m.entitlementsXML)
                                } label: {
                                    LabeledContent("Entitlements", value: m.entitlementsXML == nil ? "Không có" : "Xem XML")
                                }
                                NavigationLink {
                                    BinaryURLScannerView(store: store)
                                } label: {
                                    LabeledContent("URL trong Binary", value: store.scannedBinaryURLs.isEmpty ? "Quét" : "\(store.scannedBinaryURLs.count) link")
                                }
                            }
                        }

                        // Chỉnh sửa nhanh Info.plist
                        Section("Info.plist") {
                            LabeledFieldRow(label: "Tên app", text: $editName, placeholder: "Tên hiển thị")
                            LabeledFieldRow(label: "Bundle ID", text: $editBundleID, placeholder: "com.example.app", isCode: true)
                            LabeledFieldRow(label: "Version", text: $editVersion, placeholder: "1.0", isCode: true)
                            LabeledFieldRow(label: "Min iOS", text: $editMinOS, placeholder: "15.0", isCode: true)
                            Toggle("Chia sẻ tệp (UIFileSharing)", isOn: $editFileSharing)
                            if sum.hasSupportedDevicesLimit {
                                Toggle("Gỡ giới hạn thiết bị", isOn: $removeDeviceLimit)
                            }
                            Button {
                                store.applyManualEdits(
                                    name: editName,
                                    bundleID: editBundleID,
                                    version: editVersion,
                                    minOS: editMinOS,
                                    fileSharing: editFileSharing,
                                    removeDeviceLimit: removeDeviceLimit
                                )
                            } label: {
                                Text("Lưu Info.plist")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                        }

                        // Công cụ Mod v5.5
                        Section("Công cụ Mod") {
                            Button {
                                showDylibInjectDialog = true
                            } label: {
                                Label("Inject .dylib vào Mach-O", systemImage: "syringe")
                            }

                            Button {
                                store.cleanAllForSideload()
                            } label: {
                                Label("Tối ưu Sideload 1 chạm", systemImage: "wand.and.stars")
                            }

                            if sum.removableLprojCount > 0 {
                                Button {
                                    store.stripUnusedLocalizations()
                                } label: {
                                    Label("Xóa \(sum.removableLprojCount) gói ngôn ngữ thừa (.lproj)", systemImage: "globe.badge.chevron.backward")
                                }
                            }

                            Button {
                                NativeFilePicker.shared.pick(types: [.image, .png, .jpeg]) { urls in
                                    if let first = urls.first { store.replaceAppIconsBatch(with: first) }
                                }
                            } label: {
                                Label("Thay toàn bộ App Icon bằng 1 ảnh", systemImage: "app.badge.checkmark")
                            }

                            Button {
                                store.applyCloneSchemeFix()
                            } label: {
                                Label("Nhân bản App + Fix URL Schemes (\(sum.urlSchemeCount))", systemImage: "doc.on.doc")
                            }

                            Button {
                                store.applyBypassForceUpdate()
                            } label: {
                                Label("Giả lập Version 99.9.9", systemImage: "arrow.up.forward.circle")
                            }

                            if sum.hasPlugIns {
                                Button("Xóa PlugIns (\(sum.pluginNames.count))", role: .destructive) {
                                    store.removeFolderFromApp("PlugIns")
                                }
                            }
                            if sum.hasWatchDir {
                                Button("Xóa thư mục Watch", role: .destructive) {
                                    store.removeFolderFromApp("Watch")
                                }
                            }
                            if sum.hasCodeSignature {
                                Button("Xóa _CodeSignature", role: .destructive) {
                                    store.removeFolderFromApp("_CodeSignature")
                                }
                            }
                        }

                        if let prov = sum.provisionSummary {
                            Section("Provisioning Profile") {
                                Text(prov).font(.caption.monospaced())
                            }
                        }

                        if !store.changeLog.isEmpty {
                            Section("Nhật ký") {
                                ForEach(store.changeLog.prefix(8), id: \.self) { log in
                                    Text(log).font(.caption.monospaced())
                                }
                            }
                        }
                    }
                    .onAppear { syncForm(sum) }
                    .onChange(of: sum.bundleID) { syncForm(sum) }
                    .onChange(of: sum.displayName) { syncForm(sum) }
                    .onChange(of: sum.version) { syncForm(sum) }
                    .confirmationDialog("Chọn kiểu Inject Dylib vào Mach-O", isPresented: $showDylibInjectDialog, titleVisibility: .visible) {
                        Button("LC_LOAD_DYLIB (Chuẩn)") {
                            NativeFilePicker.shared.pick { urls in
                                if let first = urls.first {
                                    store.injectDylibIntoBinary(dylibURL: first, weakLoad: false)
                                }
                            }
                        }
                        Button("LC_LOAD_WEAK_DYLIB (An toàn)") {
                            NativeFilePicker.shared.pick { urls in
                                if let first = urls.first {
                                    store.injectDylibIntoBinary(dylibURL: first, weakLoad: true)
                                }
                            }
                        }
                        Button("Hủy", role: .cancel) {}
                    } message: {
                        Text("Tệp .dylib sẽ được chép vào Frameworks/ và ghi thẳng lệnh tải vào header Mach-O.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("IPA Studio", systemImage: "shippingbox.and.arrow.backward")
                    } description: {
                        Text("Nhập file .ipa từ app Tệp để bắt đầu.")
                    } actions: {
                        Button {
                            NativeFilePicker.shared.pick { urls in
                                if let first = urls.first { store.importIPA(from: first) }
                            }
                        } label: {
                            Label("Nhập file .IPA", systemImage: "plus")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    }
                }
            }
            .navigationTitle("IPA Studio")
            .toolbar {
                if store.summary != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            store.clearWorkspace()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Đóng workspace")
                    }
                }

                if store.canUndo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.performUndo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .accessibilityLabel("Hoàn tác")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NativeFilePicker.shared.pick { urls in
                            if let first = urls.first { store.importIPA(from: first) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nhập file IPA")
                }
            }
        }
    }

    private func syncForm(_ sum: IPAWorkspaceSummary) {
        editName = sum.displayName
        editBundleID = sum.bundleID
        editVersion = sum.version
        editMinOS = sum.minOS
        editFileSharing = sum.fileSharingEnabled
        removeDeviceLimit = false
    }
}

struct QuickStatTile: View {
    let icon: String
    let title: String
    let value: String

    private let tileShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color(uiColor: .tertiarySystemFill), in: tileShape)
        .overlay(tileShape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

struct EntitlementsViewer: View {
    @ObservedObject var store: IPAStudioManager
    let xml: String?

    var body: some View {
        Group {
            if let xml = xml {
                List {
                    Section {
                        Toggle("Gửi Entitlements này cho AI", isOn: $store.includeEntitlementsInAI)
                        Button {
                            UIPasteboard.general.string = xml
                            store.showToast("Đã copy Entitlements XML")
                        } label: {
                            Label("Sao chép toàn bộ XML", systemImage: "doc.on.doc")
                        }
                    }

                    Section("Nội dung Entitlements") {
                        Text(xml)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Không có Entitlements",
                    systemImage: "lock.slash",
                    description: Text("Binary không có khối LC_CODE_SIGNATURE chứa Entitlements nhúng.")
                )
            }
        }
        .navigationTitle("Entitlements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BinaryURLScannerView: View {
    @ObservedObject var store: IPAStudioManager
    @State private var searchText = ""

    var filtered: [String] {
        guard !searchText.isEmpty else { return store.scannedBinaryURLs }
        return store.scannedBinaryURLs.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    store.scanBinaryStrings()
                } label: {
                    HStack {
                        Label(store.isScanningBinary ? "Đang quét file Binary..." : "Quét toàn bộ URL trong Mach-O", systemImage: "magnifyingglass.circle.fill")
                        Spacer()
                        if store.isScanningBinary { ProgressView() }
                    }
                }
                .disabled(store.isScanningBinary)

                if !store.scannedBinaryURLs.isEmpty {
                    Toggle("Gửi danh sách URL này cho AI", isOn: $store.includeBinaryURLsInAI)
                }
            }

            if !filtered.isEmpty {
                Section("Phát hiện \(filtered.count) đường dẫn") {
                    ForEach(filtered, id: \.self) { url in
                        Text(url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = url
                                    store.showToast("Đã copy URL")
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("URL trong Binary")
        .searchable(text: $searchText, prompt: "Lọc domain...")
        .onAppear {
            if store.scannedBinaryURLs.isEmpty {
                store.scanBinaryStrings()
            }
        }
    }
}

struct LabeledFieldRow: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var isCode: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .font(isCode ? .subheadline.monospaced() : .subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(isCode ? .never : .sentences)
        }
    }
}

struct DylibListView: View {
    let machO: MachOInfo

    var body: some View {
        List {
            Section("Dylib / Tweak nhúng trong gói (\(machO.injectedDylibs.count))") {
                if machO.injectedDylibs.isEmpty {
                    Text("Không phát hiện dylib tùy chỉnh / tweak nào.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(machO.injectedDylibs, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }

            if !machO.rpaths.isEmpty {
                Section("LC_RPATH") {
                    ForEach(machO.rpaths, id: \.self) { r in
                        Text(r).font(.caption.monospaced())
                    }
                }
            }

            Section("Toàn bộ thư viện liên kết (\(machO.linkedDylibs.count))") {
                ForEach(machO.linkedDylibs, id: \.self) { path in
                    Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Mach-O Dylibs")
    }
}

// MARK: - Tab 2: AI Studio (Minimalist Clean Liquid Glass + Live Timer & Retry)
struct AIStudioTab: View {
    @ObservedObject var store: IPAStudioManager
    @State private var inputText = ""
    @State private var showModelPicker = false
    @Namespace private var glassNamespace

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if store.messages.isEmpty {
                        ContentUnavailableView(
                            "AI Studio",
                            systemImage: "sparkles",
                            description: Text(store.summary == nil ? "Nhập một file .ipa hoặc đặt câu hỏi." : "Đang gắn với \(store.summary?.displayName ?? "IPA").")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(store.messages) { msg in
                                    AIMessageBubble(
                                        message: msg,
                                        waitingSeconds: store.waitingSeconds,
                                        canApplyPatch: store.summary != nil,
                                        onApply: { store.applyAIPatch(messageID: msg.id) },
                                        onRetry: { store.retryFailedMessage(id: msg.id) },
                                        onCopy: {
                                            UIPasteboard.general.string = msg.text
                                            store.showToast("Đã sao chép")
                                        }
                                    )
                                    .id(msg.id)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: store.messages.count) {
                            if let last = store.messages.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                showModelPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(store.currentAPIKey.isEmpty ? Color.orange : Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(store.selectedModel)
                                        .font(.caption.weight(.semibold).monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("modelPicker", in: glassNamespace)

                            Spacer(minLength: 4)

                            HStack(spacing: 2) {
                                ForEach(AIContextDepth.allCases) { depth in
                                    let isSelected = store.contextDepth == depth
                                    Button {
                                        withAnimation(.snappy) {
                                            store.contextDepth = depth
                                        }
                                    } label: {
                                        Text(depth.rawValue)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(isSelected ? .primary : .secondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background {
                                                if isSelected {
                                                    Capsule()
                                                        .fill(Color.accentColor.opacity(0.22))
                                                        .matchedGeometryEffect(id: "depthActivePill", in: glassNamespace)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(3)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("depthSwitcher", in: glassNamespace)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 10) {
                            TextField("Nhập yêu cầu...", text: $inputText, axis: .vertical)
                                .lineLimit(1...4)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                                .glassEffectID("composerField", in: glassNamespace)

                            if store.isAIThinking {
                                Button {
                                    withAnimation(.snappy) {
                                        store.stopAI()
                                    }
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.glassProminent)
                                .buttonBorderShape(.circle)
                                .tint(.red)
                                .glassEffectID("composerAction", in: glassNamespace)
                                .accessibilityLabel("Dừng phản hồi AI")
                            } else {
                                Button {
                                    let text = inputText
                                    inputText = ""
                                    withAnimation(.snappy) {
                                        store.sendMessage(text)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.glassProminent)
                                .buttonBorderShape(.circle)
                                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .glassEffectID("composerAction", in: glassNamespace)
                                .accessibilityLabel("Gửi yêu cầu")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.messages.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.stopAI()
                            store.messages.removeAll()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Xóa lịch sử trò chuyện")
                    }
                }

                if store.canUndo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.performUndo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .accessibilityLabel("Hoàn tác")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showModelPicker = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Chọn model AI")
                }
            }
            .sheet(isPresented: $showModelPicker) {
                AIModelSelectorSheet(store: store)
            }
        }
    }
}

struct AIMessageBubble: View {
    let message: AIMessage
    let waitingSeconds: Int
    let canApplyPatch: Bool
    let onApply: () -> Void
    let onRetry: () -> Void
    let onCopy: () -> Void

    private let bubbleShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private let patchShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
            if let badge = message.modelBadge {
                HStack(spacing: 6) {
                    Text(badge)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if message.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                }
            }

            Group {
                if message.text.isEmpty && message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(waitingSeconds > 0 ? "Đang kết nối... (\(waitingSeconds)s)" : "Đang kết nối...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                message.isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                in: bubbleShape
            )
            .foregroundStyle(message.isUser ? Color.white : Color.primary)
            .contextMenu {
                Button(action: onCopy) {
                    Label("Sao chép nội dung", systemImage: "doc.on.doc")
                }
            }

            if message.failedPrompt != nil {
                HStack(spacing: 8) {
                    Button(action: onRetry) {
                        Label("Thử lại", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button(action: onCopy) {
                        Label("Copy lỗi", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            if let patch = message.patch {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.green)
                        Text(patch.summary ?? "Gói chỉnh sửa AI (\(patch.actions.count) bước)")
                            .font(.subheadline.weight(.semibold))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(patch.actions) { act in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.tint)
                                Text(act.displayTitle)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(action: onApply) {
                        Label(
                            message.patchApplied ? "Đã áp dụng vào IPA" : "Áp dụng ngay vào IPA",
                            systemImage: message.patchApplied ? "checkmark.circle.fill" : "bolt.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(message.patchApplied ? .green : .accentColor)
                    .disabled(!canApplyPatch || message.patchApplied)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: patchShape)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

struct AIModelSelectorSheet: View {
    @ObservedObject var store: IPAStudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var customModelInput = ""
    @State private var fetchedModels: [String] = []
    @State private var isFetching = false
    @State private var fetchError: String?

    var displayedModels: [String] {
        fetchedModels.isEmpty ? store.selectedProvider.presetModels : fetchedModels
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Nhà cung cấp AI API") {
                    ForEach(AIProvider.allCases) { provider in
                        Button {
                            store.switchProvider(provider)
                            fetchedModels = []
                            fetchError = nil
                        } label: {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if !(store.apiKeys[provider.rawValue] ?? "").isEmpty {
                                    Text("Sẵn sàng")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                                if store.selectedProvider == provider {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("2. API Key cho \(store.selectedProvider.rawValue)") {
                    SecureField(
                        store.selectedProvider.keyPlaceholder,
                        text: Binding(
                            get: { store.apiKeys[store.selectedProvider.rawValue] ?? "" },
                            set: { store.setAPIKey($0, for: store.selectedProvider) }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if store.selectedProvider == .gemini {
                        Picker("Cổng kết nối", selection: $store.geminiEndpointMode) {
                            ForEach(GeminiEndpointMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                    }

                    if store.selectedProvider == .custom {
                        TextField("https://.../v1/chat/completions", text: $store.customEndpoint)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        loadLiveModels()
                    } label: {
                        HStack {
                            Label(isFetching ? "Đang quét model từ Key..." : "Quét danh sách Model thật từ Key", systemImage: "arrow.clockwise")
                            Spacer()
                            if isFetching { ProgressView() }
                        }
                    }
                    .disabled(isFetching || store.currentAPIKey.isEmpty)

                    if let err = fetchError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Section("3. Chọn Model (\(displayedModels.count))") {
                    ForEach(displayedModels, id: \.self) { m in
                        Button {
                            store.selectedModel = m
                        } label: {
                            HStack {
                                Text(m)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if store.selectedModel == m {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("Nhập tên model tùy chỉnh...", text: $customModelInput)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Dùng") {
                            let clean = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                store.selectedModel = clean
                                customModelInput = ""
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Chọn Model & API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }

    private func loadLiveModels() {
        isFetching = true
        fetchError = nil
        let provider = store.selectedProvider
        let key = store.currentAPIKey
        let mode = store.geminiEndpointMode
        let endpoint = store.customEndpoint

        Task {
            do {
                let list = try await AIClient.fetchModels(provider: provider, apiKey: key, geminiMode: mode, customEndpoint: endpoint)
                self.fetchedModels = list
                if !list.contains(store.selectedModel), let first = list.first {
                    store.selectedModel = first
                }
                self.isFetching = false
            } catch {
                self.fetchError = error.localizedDescription
                self.isFetching = false
            }
        }
    }
}

// MARK: - Tab 3: Deep IPA File Explorer & Global Search
struct FileExplorerTab: View {
    @ObservedObject var store: IPAStudioManager

    var body: some View {
        NavigationStack {
            if let sum = store.summary {
                FolderBrowserView(folderURL: sum.appBundleURL, title: sum.appBundleURL.lastPathComponent, isRoot: true, store: store)
            } else {
                ContentUnavailableView(
                    "Chưa có file IPA",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Vào tab IPA để nhập file .ipa trước.")
                )
                .navigationTitle("Tệp IPA")
            }
        }
    }
}

struct FolderBrowserView: View {
    let folderURL: URL
    let title: String
    var isRoot: Bool = false
    @ObservedObject var store: IPAStudioManager
    @State private var searchText = ""
    @State private var deepResults: [IPAFileNode] = []
    @State private var refreshTick = 0

    var displayedItems: [IPAFileNode] {
        _ = refreshTick
        if !searchText.isEmpty && isRoot {
            return deepResults
        }
        let list = store.listDirectory(folderURL)
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(displayedItems) { node in
                if node.isDirectory {
                    NavigationLink {
                        FolderBrowserView(folderURL: node.url, title: node.name, isRoot: false, store: store)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: node.iconName).foregroundStyle(node.iconColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).lineLimit(1)
                                if isRoot && !searchText.isEmpty {
                                    Text(node.relativePath)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } else {
                    NavigationLink {
                        FileDetailEditorView(node: node, store: store)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: node.iconName).foregroundStyle(node.iconColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).lineLimit(1)
                                Text(isRoot && !searchText.isEmpty ? "\(node.relativePath) • \(node.formattedSize)" : node.formattedSize)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if store.pinnedFilesForAI.contains(node.relativePath) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                }
            }
            .onDelete { offsets in
                let list = displayedItems
                for idx in offsets {
                    try? FileManager.default.removeItem(at: list[idx].url)
                }
                refreshTick += 1
                store.refreshWorkspace()
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: isRoot ? "Tìm toàn bộ tệp trong .app..." : "Lọc tệp trong thư mục...")
        .onChange(of: searchText) {
            guard isRoot else { return }
            let query = searchText
            let rootURL = folderURL
            Task {
                let hits = await Task.detached(priority: .userInitiated) {
                    IPAStudioManager.searchAllFiles(in: rootURL, query: query)
                }.value
                if self.searchText == query {
                    self.deepResults = hits
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NativeFilePicker.shared.pick(allowsMultiple: true) { urls in
                        store.injectFiles(urls, into: folderURL)
                        refreshTick += 1
                    }
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .accessibilityLabel("Chèn tệp vào thư mục")
            }
        }
    }
}

struct FileDetailEditorView: View {
    let node: IPAFileNode
    @ObservedObject var store: IPAStudioManager
    @State private var textContent = ""
    @State private var hexPreview = ""
    @State private var previewImage: UIImage?
    @State private var isPlist = false

    private let previewShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var isPinned: Bool {
        store.pinnedFilesForAI.contains(node.relativePath)
    }

    var body: some View {
        Group {
            if node.isTextEditable {
                TextEditor(text: $textContent)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else if node.isImageFile {
                ScrollView {
                    VStack(spacing: 16) {
                        if let img = previewImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 320)
                                .clipShape(previewShape)
                                .overlay(previewShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
                                .padding(.top, 20)
                            Text("\(Int(img.size.width * img.scale)) × \(Int(img.size.height * img.scale)) px • \(node.formattedSize)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            NativeFilePicker.shared.pick(types: [.image, .png, .jpeg]) { urls in
                                if let picked = urls.first {
                                    store.replaceFile(at: node.url, with: picked, relativePath: node.relativePath)
                                    previewImage = UIImage(contentsOfFile: node.url.path)
                                }
                            }
                        } label: {
                            Label("Thay ảnh này từ Tệp", systemImage: "photo.badge.arrow.down")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tệp nhị phân (\(node.formattedSize)) — 2KB Hex đầu tiên:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(hexPreview)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if node.isTextEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.togglePinForAI(node.relativePath)
                    } label: {
                        Image(systemName: isPinned ? "sparkles.rectangle.stack.fill" : "sparkles")
                            .foregroundStyle(isPinned ? .purple : .primary)
                    }
                    .accessibilityLabel("Ghim tệp cho AI")
                }

                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { saveFile() }
                }
            }
        }
        .onAppear { loadFile() }
    }

    private func loadFile() {
        isPlist = node.url.pathExtension.lowercased() == "plist"
        if node.isTextEditable {
            if isPlist, let xml = PlistHelper.plistToXMLString(url: node.url) {
                textContent = xml
            } else if let str = try? String(contentsOf: node.url, encoding: .utf8) {
                textContent = str
            } else {
                textContent = "// Không đọc được dưới dạng UTF-8"
            }
        } else if node.isImageFile {
            previewImage = UIImage(contentsOfFile: node.url.path)
        } else {
            if let handle = try? FileHandle(forReadingFrom: node.url),
               let sample = try? handle.read(upToCount: 2048) {
                try? handle.close()
                let bytes = [UInt8](sample)
                var lines: [String] = []
                for offset in stride(from: 0, to: bytes.count, by: 16) {
                    let end = min(offset + 16, bytes.count)
                    let slice = bytes[offset..<end]
                    let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
                    let ascii = slice.map { ($0 >= 32 && $0 <= 126) ? String(UnicodeScalar($0)) : "." }.joined()
                    lines.append("\(String(format: "%04X", offset)): \(paddedHex)  \(ascii)")
                }
                hexPreview = lines.joined(separator: "\n")
            }
        }
    }

    private func saveFile() {
        do {
            if isPlist {
                try PlistHelper.validateAndSaveXMLPlist(textContent, to: node.url)
            } else {
                try Data(textContent.utf8).write(to: node.url, options: .atomic)
            }
            store.changeLog.insert("✓ Đã sửa thủ công: \(node.relativePath)", at: 0)
            store.refreshWorkspace()
            store.showToast("Đã lưu \(node.name)")
        } catch {
            store.showToast("Lỗi lưu tệp: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Tab 4: AI API Settings
struct APISettingsTab: View {
    @ObservedObject var store: IPAStudioManager

    var body: some View {
        NavigationStack {
            Form {
                Section("AI đang hoạt động") {
                    LabeledContent("Nhà cung cấp", value: store.selectedProvider.rawValue)
                    LabeledContent("Model", value: store.selectedModel)
                    Picker("Độ sâu ngữ cảnh", selection: $store.contextDepth) {
                        ForEach(AIContextDepth.allCases) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }
                    Toggle("Streaming hiện chữ trực tiếp", isOn: $store.useStreaming)
                    if store.selectedProvider == .gemini {
                        Picker("Cổng Gemini", selection: $store.geminiEndpointMode) {
                            ForEach(GeminiEndpointMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                    }
                }

                Section("Kho API Key") {
                    ForEach(AIProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if store.selectedProvider == provider {
                                    Text("Đang chọn")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            SecureField(
                                provider.keyPlaceholder,
                                text: Binding(
                                    get: { store.apiKeys[provider.rawValue] ?? "" },
                                    set: { store.setAPIKey($0, for: provider) }
                                )
                            )
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Custom OpenAI-Compatible Endpoint") {
                    TextField("https://.../v1/chat/completions", text: $store.customEndpoint)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Đóng gói IPA") {
                    Toggle("Nén ZLIB khi xuất IPA", isOn: $store.compressOnExport)
                    Button("Xóa thư mục giải nén tạm", role: .destructive) {
                        store.clearWorkspace()
                    }
                }
            }
            .navigationTitle("AI API & Cài đặt")
        }
    }
}
