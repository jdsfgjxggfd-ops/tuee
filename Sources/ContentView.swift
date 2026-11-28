import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Compression
import CryptoKit

// MARK: - Native UIKit File Picker & Share Sheet (Fix hoàn toàn lỗi đơ chọn file)
@MainActor
final class NativeFilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeFilePicker()
    private var completion: (([URL]) -> Void)?

    static var supportedTypes: [UTType] {
        var list: [UTType] = [.item, .data, .content, .archive, .zip, .json, .propertyList, .plainText]
        for ext in ["ipa", "dylib", "deb", "plist", "mobileprovision", "strings", "xml", "cfg"] {
            if let t = UTType(filenameExtension: ext) { list.append(t) }
        }
        return list
    }

    func pick(allowsMultiple: Bool = false, completion: @escaping ([URL]) -> Void) {
        guard let presenter = Self.topViewController() else {
            completion([])
            return
        }
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.supportedTypes, asCopy: true)
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

// MARK: - Pure Swift ZIP Extractor & Repacker (Compression ZLIB + CRC32)
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
        let dstCapacity = max(expectedSize + 64, 1024)
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
        guard fileSize >= 22 else { throw ZIPArchiveError.invalidArchive("File quá nhỏ") }

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

        let cdSize = Int(readU32LE(tail, eocd + 12))
        let cdOffset = UInt64(readU32LE(tail, eocd + 16))
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
                if idx % 20 == 0 || idx == entries.count - 1 {
                    onProgress?(Double(idx + 1) / Double(total), entry.name)
                }
                guard !entry.name.isEmpty, !entry.name.contains("..") else { return }
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

                let rawData: Data
                if entry.compressedSize == 0 {
                    rawData = Data()
                } else {
                    rawData = (try handle.read(upToCount: Int(entry.compressedSize))) ?? Data()
                }

                let finalData: Data
                if entry.method == 0 {
                    finalData = rawData
                } else if entry.method == 8 {
                    guard let decoded = decompressDeflate(rawData, expectedSize: Int(entry.uncompressedSize)) else {
                        throw ZIPArchiveError.invalidArchive("Giải nén lỗi tại \(entry.name)")
                    }
                    finalData = decoded
                } else {
                    throw ZIPArchiveError.invalidArchive("Phương thức nén \(entry.method) chưa hỗ trợ")
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

        guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else {
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
                let fullPath = itemURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath) else { return }
                var relPath = String(fullPath.dropFirst(rootPath.count))
                if relPath.hasPrefix("/") { relPath.removeFirst() }
                guard !relPath.isEmpty else { return }

                if idx % 20 == 0 || idx == allURLs.count - 1 {
                    onProgress?(Double(idx + 1) / Double(total), relPath)
                }

                let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = values.isDirectory ?? false
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

                    // Giữ quyền thực thi cho file Mach-O & dylib
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
                appendU16LE(&lfh, 0x0800) // UTF-8
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
            appendU16LE(&cdh, 0x031E) // UNIX
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

// MARK: - Deep Mach-O Binary Inspector
struct MachOInfo: Sendable {
    let executableName: String
    let fileSizeBytes: Int64
    let architectures: [String]
    let isEncrypted: Bool?
    let cryptID: UInt32?
    let minOSVersion: String?
    let sdkVersion: String?
    let linkedDylibs: [String]
    let injectedDylibs: [String]
    let rpaths: [String]
}

enum MachOInspector {
    private static func readU32LE(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return UInt32(d[b]) | (UInt32(d[b+1]) << 8) | (UInt32(d[b+2]) << 16) | (UInt32(d[b+3]) << 24)
    }

    private static func readU32BE(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return (UInt32(d[b]) << 24) | (UInt32(d[b+1]) << 16) | (UInt32(d[b+2]) << 8) | UInt32(d[b+3])
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
        var pos = 0

        for _ in 0..<ncmds {
            guard pos + 8 <= cmdData.count else { break }
            let cmd = readU32LE(cmdData, pos)
            let cmdsize = Int(readU32LE(cmdData, pos + 4))
            guard cmdsize >= 8, pos + cmdsize <= cmdData.count else { break }

            if cmd == 0x2C || cmd == 0x21 { // LC_ENCRYPTION_INFO_64 / LC_ENCRYPTION_INFO
                if pos + 20 <= cmdData.count {
                    cryptID = readU32LE(cmdData, pos + 16)
                }
            } else if cmd == 0x32 { // LC_BUILD_VERSION
                if pos + 20 <= cmdData.count {
                    minOS = decodeVersion(readU32LE(cmdData, pos + 12))
                    sdk = decodeVersion(readU32LE(cmdData, pos + 16))
                }
            } else if cmd == 0x0C || cmd == 0x80000018 || cmd == 0x8000001F || cmd == 0x20 { // Dylibs
                if pos + 12 <= cmdData.count {
                    let strOff = Int(readU32LE(cmdData, pos + 8))
                    if strOff < cmdsize {
                        let start = cmdData.startIndex + pos + strOff
                        let end = cmdData.startIndex + pos + cmdsize
                        let slice = cmdData[start..<end]
                        if let nullIdx = slice.firstIndex(of: 0) {
                            if let s = String(data: slice[start..<nullIdx], encoding: .utf8), !s.isEmpty {
                                dylibs.append(s)
                            }
                        } else if let s = String(data: slice, encoding: .utf8), !s.isEmpty {
                            dylibs.append(s.trimmingCharacters(in: .controlCharacters))
                        }
                    }
                }
            } else if cmd == 0x8000001C { // LC_RPATH
                if pos + 12 <= cmdData.count {
                    let strOff = Int(readU32LE(cmdData, pos + 8))
                    if strOff < cmdsize {
                        let start = cmdData.startIndex + pos + strOff
                        let end = cmdData.startIndex + pos + cmdsize
                        let slice = cmdData[start..<end]
                        let endPos = slice.firstIndex(of: 0) ?? end
                        if let s = String(data: slice[start..<endPos], encoding: .utf8), !s.isEmpty {
                            rpaths.append(s)
                        }
                    }
                }
            }

            pos += cmdsize
        }

        let injected = dylibs.filter {
            $0.hasPrefix("@executable_path") || $0.hasPrefix("@rpath") || $0.hasPrefix("@loader_path") || $0.contains("Substrate") || $0.contains("ElleKit") || $0.contains("Cydia")
        }

        return MachOInfo(
            executableName: binaryURL.lastPathComponent,
            fileSizeBytes: fileSize,
            architectures: archs,
            isEncrypted: cryptID.map { $0 != 0 },
            cryptID: cryptID,
            minOSVersion: minOS,
            sdkVersion: sdk,
            linkedDylibs: dylibs,
            injectedDylibs: injected,
            rpaths: rpaths
        )
    }
}

// MARK: - Plist & Provision Helpers
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

// MARK: - IPA Workspace Models
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
    let pluginNames: [String]
    let frameworkNames: [String]
    let totalFilesCount: Int
    let provisionSummary: String?
    let machO: MachOInfo?
    let sha256Short: String
    let iconPath: URL?
}

// MARK: - AI Providers & Multi-API Engine
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini = "Google Gemini"
    case openai = "OpenAI (ChatGPT)"
    case claude = "Anthropic Claude"
    case deepseek = "DeepSeek"
    case groq = "Groq"
    case grok = "xAI Grok"
    case openrouter = "OpenRouter (All-in-One)"
    case custom = "Custom OpenAI API"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gemini: return "sparkles"
        case .openai: return "brain.head.profile"
        case .claude: return "cpu"
        case .deepseek: return "magnifyingglass.circle"
        case .groq: return "bolt.fill"
        case .grok: return "flame.fill"
        case .openrouter: return "network"
        case .custom: return "server.rack"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .grok: return "https://api.x.ai/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        }
    }

    var presetModels: [String] {
        switch self {
        case .gemini:
            return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.0-flash-thinking-exp"]
        case .openai:
            return ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "o4-mini", "o3-mini"]
        case .claude:
            return ["claude-sonnet-4-20250514", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .deepseek:
            return ["deepseek-reasoner", "deepseek-chat"]
        case .groq:
            return ["llama-3.3-70b-versatile", "qwen-qwq-32b", "deepseek-r1-distill-llama-70b"]
        case .grok:
            return ["grok-3", "grok-3-mini", "grok-2-latest"]
        case .openrouter:
            return ["google/gemini-2.5-pro", "anthropic/claude-sonnet-4", "openai/gpt-4.1", "deepseek/deepseek-r1"]
        case .custom:
            return ["gpt-4o", "gemini-2.5-pro", "claude-sonnet-4"]
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: return "AIzaSy..."
        case .openai: return "sk-proj-..."
        case .claude: return "sk-ant-..."
        case .deepseek: return "sk-..."
        case .groq: return "gsk_..."
        case .grok: return "xai-..."
        case .openrouter: return "sk-or-v1-..."
        case .custom: return "Bearer API Key..."
        }
    }
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
        case "set_plist":
            return "Sửa Info.plist: \(key ?? "?") = \(value ?? "")"
        case "delete_plist":
            return "Xóa key Info.plist: \(key ?? "?")"
        case "patch_plist_file":
            return "Sửa Plist \(path ?? ""): \(key ?? "?") = \(value ?? "")"
        case "delete_path":
            return "Xóa tệp/thư mục: \(path ?? "?")"
        case "write_text_file":
            return "Ghi tệp: \(path ?? "?")"
        case "replace_in_file":
            return "Thay chuỗi trong \(path ?? "?")"
        default:
            return note ?? type
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
    let text: String
    let modelBadge: String?
    let patch: AIPatchEnvelope?
    var patchApplied: Bool = false
    let timestamp = Date()
}

struct AIChatTurn: Sendable {
    let isUser: Bool
    let text: String
}

enum AIClient {
    static func send(
        provider: AIProvider,
        model: String,
        apiKey: String,
        customEndpoint: String,
        systemPrompt: String,
        history: [AIChatTurn]
    ) async throws -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "AIClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Bạn chưa nhập API Key cho \(provider.rawValue). Bấm nút chọn Model ở góc trên để thêm key."])
        }

        switch provider {
        case .gemini:
            return try await callGemini(model: model, apiKey: cleanKey, systemPrompt: systemPrompt, history: history)
        case .claude:
            return try await callClaude(model: model, apiKey: cleanKey, systemPrompt: systemPrompt, history: history)
        case .openai, .deepseek, .groq, .grok, .openrouter, .custom:
            let endpoint = (provider == .custom && !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                : provider.defaultEndpoint
            return try await callOpenAICompatible(endpoint: endpoint, model: model, apiKey: cleanKey, systemPrompt: systemPrompt, history: history)
        }
    }

    private static func callGemini(model: String, apiKey: String, systemPrompt: String, history: [AIChatTurn]) async throws -> String {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent?key=\(apiKey)") else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Tên model Gemini không hợp lệ."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents: [[String: Any]] = history.map { turn in
            [
                "role": turn.isUser ? "user" : "model",
                "parts": [["text": turn.text]]
            ]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.25]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response: response, data: data)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Gemini không trả về nội dung."])
    }

    private static func callClaude(model: String, apiKey: String, systemPrompt: String, history: [AIChatTurn]) async throws -> String {
        guard let url = URL(string: AIProvider.claude.defaultEndpoint) else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "URL Claude lỗi."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let messages: [[String: Any]] = history.map { turn in
            ["role": turn.isUser ? "user" : "assistant", "content": turn.text]
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response: response, data: data)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Claude không trả về nội dung."])
    }

    private static func callOpenAICompatible(endpoint: String, model: String, apiKey: String, systemPrompt: String, history: [AIChatTurn]) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Endpoint API không hợp lệ."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": turn.isUser ? "user" : "assistant", "content": turn.text])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.25
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response: response, data: data)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let text = msg["content"] as? String {
            return text
        }
        throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "API không trả về nội dung."])
    }

    private static func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let preview = String(bodyText.prefix(260))
            throw NSError(domain: "AIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi API (\(http.statusCode)): \(preview)"])
        }
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

    static func apply(actions: [AIPatchAction], appBundleURL: URL, workspaceRoot: URL) -> [String] {
        var logs: [String] = []
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        let fm = FileManager.default

        func resolveSafeURL(_ relPath: String) -> URL? {
            let clean = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !clean.isEmpty, !clean.contains("..") else { return nil }
            let candidate = clean.hasPrefix("Payload/")
                ? workspaceRoot.appendingPathComponent(clean)
                : appBundleURL.appendingPathComponent(clean)
            guard candidate.standardizedFileURL.path.hasPrefix(workspaceRoot.standardizedFileURL.path) else { return nil }
            return candidate
        }

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
                guard let rel = action.path, let target = resolveSafeURL(rel), let key = action.key,
                      var dict = PlistHelper.readDict(url: target) else {
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
                guard let rel = action.path, let target = resolveSafeURL(rel) else {
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
                guard let rel = action.path, let target = resolveSafeURL(rel), let content = action.content else {
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
                guard let rel = action.path, let target = resolveSafeURL(rel),
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

// MARK: - Main Studio Store Manager
@MainActor
final class IPAStudioManager: ObservableObject {
    @Published var summary: IPAWorkspaceSummary?
    @Published var isBusy = false
    @Published var busyTitle = ""
    @Published var busyProgress: Double = 0
    @Published var busyDetail = ""
    @Published var alertMessage: String?
    @Published var changeLog: [String] = []
    @Published var pinnedFilesForAI: [String] = []

    // AI State
    @Published var selectedProvider: AIProvider = .gemini {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: providerKey) }
    }
    @Published var selectedModel: String = "gemini-2.5-pro" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: modelKey) }
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

    private let providerKey = "IPAStudio_Provider"
    private let modelKey = "IPAStudio_Model"
    private let keysStorageKey = "IPAStudio_APIKeys"
    private let customEndpointKey = "IPAStudio_CustomEndpoint"
    private let compressKey = "IPAStudio_Compress"

    var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var workspaceDir: URL {
        documentsDir.appendingPathComponent("ActiveIPAWorkspace", isDirectory: true)
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
        if let savedKeys = UserDefaults.standard.dictionary(forKey: keysStorageKey) as? [String: String] {
            apiKeys = savedKeys
        }
        customEndpoint = UserDefaults.standard.string(forKey: customEndpointKey) ?? ""
        if UserDefaults.standard.object(forKey: compressKey) != nil {
            compressOnExport = UserDefaults.standard.bool(forKey: compressKey)
        }
        messages = [
            AIMessage(
                isUser: false,
                text: "Nhập một file `.ipa` ở tab **IPA**, rồi quay lại đây ra lệnh cho tôi soi sâu `Info.plist`, kiểm tra mã hóa FairPlay, soi Dylib/Tweak hoặc tự động chỉnh sửa mọi thứ bên trong gói IPA.",
                modelBadge: nil,
                patch: nil
            )
        ]
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

    // MARK: - Import & Extract IPA
    func importIPA(from pickedURL: URL) {
        let ext = pickedURL.pathExtension.lowercased()
        guard ext == "ipa" || ext == "zip" else {
            alertMessage = "Vui lòng chọn đúng file đuôi .ipa"
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

                busyTitle = "Đang phân tích sâu IPA..."
                busyDetail = "Soi Info.plist & Mach-O Binary"
                let analyzed = try await Task.detached(priority: .userInitiated) {
                    try Self.analyzeWorkspace(root: destRoot, sourceName: sourceName, originalSize: originalSize, shaShort: sha)
                }.value

                self.summary = analyzed
                self.pinnedFilesForAI = []
                self.changeLog = ["Đã nhập & giải nén: \(sourceName)"]
                self.isBusy = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

        // Tìm ảnh icon (ưu tiên png lớn nhất có chữ AppIcon)
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
            pluginNames: plugins,
            frameworkNames: frameworks,
            totalFilesCount: fileCount,
            provisionSummary: provSummary,
            machO: machO,
            sha256Short: shaShort,
            iconPath: iconURL
        )
    }

    // MARK: - Quick Native Edits
    func applyManualEdits(name: String, bundleID: String, version: String, minOS: String, fileSharing: Bool, removeDeviceLimit: Bool) {
        guard let sum = summary, var dict = PlistHelper.readDict(url: sum.infoPlistURL) else { return }
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
        } catch {
            alertMessage = "Lỗi lưu Info.plist: \(error.localizedDescription)"
        }
    }

    func removeFolderFromApp(_ folderName: String) {
        guard let sum = summary else { return }
        let target = sum.appBundleURL.appendingPathComponent(folderName)
        if FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
                changeLog.insert("✓ Đã xóa thư mục \(folderName)", at: 0)
                refreshWorkspace()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                alertMessage = "Không xóa được \(folderName): \(error.localizedDescription)"
            }
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
                self.changeLog.insert("✓ Đã xuất IPA: \(outURL.lastPathComponent)", at: 0)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                NativeShareHelper.share(url: outURL)
            } catch {
                self.isBusy = false
                self.alertMessage = "Lỗi đóng gói IPA: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - File Explorer Helpers
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
        }
    }

    func togglePinForAI(_ relativePath: String) {
        if let idx = pinnedFilesForAI.firstIndex(of: relativePath) {
            pinnedFilesForAI.remove(at: idx)
        } else {
            pinnedFilesForAI.append(relativePath)
        }
    }

    // MARK: - AI Context Builder & Chat
    private func buildDeepIPAContext() -> String {
        guard let sum = summary else {
            return "Hiện người dùng CHƯA nhập file IPA nào."
        }
        var lines: [String] = []
        lines.append("=== THÔNG TIN IPA ĐANG MỞ ===")
        lines.append("File: \(sum.sourceFileName) (\(ByteCountFormatter.string(fromByteCount: sum.originalIPASize, countStyle: .file)))")
        lines.append("Tên app: \(sum.displayName) | Bundle ID: \(sum.bundleID) | Version: \(sum.version) (\(sum.buildNumber)) | MinOS: \(sum.minOS)")
        lines.append("Executable: \(sum.executableName) | Tổng số tệp trong .app: \(sum.totalFilesCount)")
        lines.append("FileSharing: \(sum.fileSharingEnabled) | UISupportedDevices: \(sum.hasSupportedDevicesLimit) | _CodeSignature: \(sum.hasCodeSignature)")
        lines.append("PlugIns (\(sum.pluginNames.count)): \(sum.pluginNames.joined(separator: ", "))")
        lines.append("Frameworks (\(sum.frameworkNames.count)): \(sum.frameworkNames.prefix(40).joined(separator: ", "))")
        if let prov = sum.provisionSummary {
            lines.append("embedded.mobileprovision: \(prov)")
        }

        if let m = sum.machO {
            let enc = m.isEncrypted == nil ? "Không có LC_ENCRYPTION_INFO" : (m.isEncrypted == true ? "ĐANG MÃ HÓA FAIRPLAY (cryptid=\(m.cryptID ?? 1))" : "ĐÃ GIẢI MÃ (cryptid=0)")
            lines.append("\n=== PHÂN TÍCH MACH-O BINARY ===")
            lines.append("Kiến trúc: \(m.architectures.joined(separator: ", ")) | Trạng thái mã hóa: \(enc)")
            lines.append("MinOS (LC_BUILD_VERSION): \(m.minOSVersion ?? "N/A") | SDK: \(m.sdkVersion ?? "N/A")")
            lines.append("Dylib/Tweak tùy chỉnh/nhúng (\(m.injectedDylibs.count)): \(m.injectedDylibs.joined(separator: ", "))")
            lines.append("Tổng số Dylib hệ thống liên kết: \(m.linkedDylibs.count)")
        }

        // Top-level files trong .app
        let topNodes = listDirectory(sum.appBundleURL).prefix(60)
        lines.append("\n=== CÂY THƯ MỤC GỐC .APP ===")
        for n in topNodes {
            lines.append("- \(n.name) (\(n.formattedSize))")
        }

        // Info.plist XML (giới hạn 12KB để tiết kiệm token)
        if let xml = PlistHelper.plistToXMLString(url: sum.infoPlistURL) {
            lines.append("\n=== NỘI DUNG INFO.PLIST (XML) ===")
            lines.append(String(xml.prefix(12000)))
        }

        // Các file người dùng ghim thêm để AI soi kỹ
        if !pinnedFilesForAI.isEmpty {
            lines.append("\n=== CÁC TỆP NGƯỜI DÙNG GHIM ĐỂ SOI SÂU ===")
            for rel in pinnedFilesForAI.prefix(5) {
                let fileURL = sum.appBundleURL.appendingPathComponent(rel)
                let content: String
                if fileURL.pathExtension.lowercased() == "plist", let xml = PlistHelper.plistToXMLString(url: fileURL) {
                    content = xml
                } else {
                    content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(Tệp nhị phân)"
                }
                lines.append("--- FILE: \(rel) ---\n\(String(content.prefix(6000)))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func buildSystemPrompt() -> String {
        """
        Bạn là chuyên gia kỹ thuật đảo ngược iOS (Reverse Engineering, Sideloading, Mach-O, Info.plist, IPA modding) được tích hợp trực tiếp trong ứng dụng TueeHub IPA Studio.
        Trả lời bằng tiếng Việt ngắn gọn, kỹ thuật chuẩn xác, đi thẳng vào vấn đề.

        Dưới đây là toàn bộ dữ liệu thực tế trích xuất từ file IPA người dùng đang mở:
        \(buildDeepIPAContext())

        QUY TẮC CHỈNH SỬA TỰ ĐỘNG (QUAN TRỌNG):
        - Khi người dùng yêu cầu chỉnh sửa bất kỳ gì trong file IPA (đổi tên, đổi Bundle ID, bật File Sharing, xóa PlugIns/Watch/_CodeSignature, xóa giới hạn thiết bị, sửa key Info.plist, sửa file json/plist/strings...), bên cạnh lời giải thích ngắn gọn, BẮT BUỘC xuất thêm ĐÚNG MỘT khối code ```ipa_patch chứa JSON hợp lệ theo định dạng sau để ứng dụng thực thi thật lên tệp:

        ```ipa_patch
        {
          "summary": "Mô tả ngắn gói chỉnh sửa",
          "actions": [
            {"type": "set_plist", "key": "CFBundleDisplayName", "value": "TenMoi", "valueType": "string"},
            {"type": "set_plist", "key": "UIFileSharingEnabled", "value": "true", "valueType": "bool"},
            {"type": "delete_plist", "key": "UISupportedDevices"},
            {"type": "delete_path", "path": "PlugIns"},
            {"type": "patch_plist_file", "path": "Sub/File.plist", "key": "SomeKey", "value": "123", "valueType": "int"},
            {"type": "write_text_file", "path": "config.json", "content": "{...}"},
            {"type": "replace_in_file", "path": "file.txt", "find": "old", "replace": "new"}
          ]
        }
        ```

        - Các `type` hợp lệ: `set_plist`, `delete_plist`, `patch_plist_file`, `delete_path`, `write_text_file`, `replace_in_file`.
        - Các `valueType` hợp lệ: `string`, `bool`, `int`, `array`.
        - `path` tính tương đối từ bên trong thư mục `.app` (ví dụ `PlugIns`, `Watch`, `_CodeSignature`, `Frameworks/AdSDK.framework`, `config.json`).
        - Nếu người dùng chỉ hỏi/phân tích mà không kêu sửa, KHÔNG cần xuất khối `ipa_patch`.
        """
    }

    func sendMessage(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIThinking else { return }

        messages.append(AIMessage(isUser: true, text: trimmed, modelBadge: nil, patch: nil))
        isAIThinking = true

        let provider = selectedProvider
        let model = selectedModel
        let key = currentAPIKey
        let endpoint = customEndpoint
        let sysPrompt = buildSystemPrompt()
        let history = messages.suffix(10).map { AIChatTurn(isUser: $0.isUser, text: $0.text) }

        Task {
            do {
                let reply = try await AIClient.send(
                    provider: provider,
                    model: model,
                    apiKey: key,
                    customEndpoint: endpoint,
                    systemPrompt: sysPrompt,
                    history: history
                )
                let parsed = AIPatchEngine.extractPatch(from: reply)
                self.messages.append(
                    AIMessage(
                        isUser: false,
                        text: parsed.cleanText.isEmpty ? (parsed.patch?.summary ?? "Đã tạo gói chỉnh sửa.") : parsed.cleanText,
                        modelBadge: "\(provider.rawValue) • \(model)",
                        patch: parsed.patch
                    )
                )
                self.isAIThinking = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                self.isAIThinking = false
                self.messages.append(
                    AIMessage(
                        isUser: false,
                        text: "❌ \(error.localizedDescription)",
                        modelBadge: provider.rawValue,
                        patch: nil
                    )
                )
            }
        }
    }

    func applyAIPatch(messageID: UUID) {
        guard let sum = summary,
              let idx = messages.firstIndex(where: { $0.id == messageID }),
              let patch = messages[idx].patch else { return }

        let logs = AIPatchEngine.apply(actions: patch.actions, appBundleURL: sum.appBundleURL, workspaceRoot: sum.workspaceRoot)
        messages[idx].patchApplied = true
        for l in logs.reversed() { changeLog.insert(l, at: 0) }
        refreshWorkspace()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        alertMessage = logs.joined(separator: "\n")
    }

    func clearWorkspace() {
        try? FileManager.default.removeItem(at: workspaceDir)
        summary = nil
        pinnedFilesForAI = []
        changeLog = []
    }
}

// MARK: - Root ContentView (100% Native iOS TabView)
struct ContentView: View {
    @StateObject private var store = IPAStudioManager()

    var body: some View {
        ZStack {
            TabView {
                IPAOverviewTab(store: store)
                    .tabItem {
                        Label("IPA", systemImage: "shippingbox.fill")
                    }

                AIStudioTab(store: store)
                    .tabItem {
                        Label("AI Studio", systemImage: "sparkles")
                    }

                FileExplorerTab(store: store)
                    .tabItem {
                        Label("Tệp IPA", systemImage: "folder.fill")
                    }

                APISettingsTab(store: store)
                    .tabItem {
                        Label("AI API", systemImage: "cpu")
                    }
            }

            if store.isBusy {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
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
                    .padding(22)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("IPA Studio", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

// MARK: - Tab 1: IPA Overview, Mach-O Deep Inspector & Quick Editor
struct IPAOverviewTab: View {
    @ObservedObject var store: IPAStudioManager

    @State private var editName = ""
    @State private var editBundleID = ""
    @State private var editVersion = ""
    @State private var editMinOS = ""
    @State private var editFileSharing = false
    @State private var removeDeviceLimit = false

    var body: some View {
        NavigationStack {
            Group {
                if let sum = store.summary {
                    Form {
                        // Header thông tin IPA
                        Section {
                            HStack(spacing: 14) {
                                if let iconURL = sum.iconPath, let img = UIImage(contentsOfFile: iconURL.path) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 62, height: 62)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                } else {
                                    Image(systemName: "app.dashed")
                                        .font(.system(size: 32))
                                        .frame(width: 62, height: 62)
                                        .background(Color.secondary.opacity(0.2))
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sum.displayName).font(.headline)
                                    Text(sum.bundleID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("v\(sum.version) (\(sum.buildNumber)) • \(sum.totalFilesCount) tệp • SHA \(sum.sha256Short)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 4)

                            Button {
                                store.exportEditedIPA()
                            } label: {
                                Label("Đóng gói & Xuất file IPA đã sửa", systemImage: "square.and.arrow.up.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }

                        // Mach-O Deep Inspection
                        if let m = sum.machO {
                            Section("Soi Mach-O Binary (\(m.executableName))") {
                                LabeledContent("Kiến trúc", value: m.architectures.joined(separator: ", "))
                                HStack {
                                    Text("Mã hóa FairPlay")
                                    Spacer()
                                    if let enc = m.isEncrypted {
                                        Text(enc ? "Còn mã hóa (cryptid=\(m.cryptID ?? 1))" : "Đã giải mã (Decrypted)")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(enc ? .red : .green)
                                    } else {
                                        Text("Không mã hóa").foregroundStyle(.secondary)
                                    }
                                }
                                LabeledContent("Dung lượng Binary", value: ByteCountFormatter.string(fromByteCount: m.fileSizeBytes, countStyle: .file))
                                if let sdk = m.sdkVersion {
                                    LabeledContent("Build SDK / MinOS", value: "iOS \(sdk) / \(m.minOSVersion ?? "N/A")")
                                }
                                NavigationLink {
                                    DylibListView(machO: m)
                                } label: {
                                    LabeledContent("Dylib / Tweak nhúng", value: "\(m.injectedDylibs.count) nhúng / \(m.linkedDylibs.count) tổng")
                                }
                            }
                        }

                        // Chỉnh sửa nhanh Info.plist
                        Section("Chỉnh sửa nhanh Info.plist") {
                            TextField("Tên hiển thị", text: $editName)
                            TextField("Bundle ID", text: $editBundleID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            HStack {
                                Text("Version")
                                Spacer()
                                TextField("1.0", text: $editVersion)
                                    .multilineTextAlignment(.trailing)
                            }
                            HStack {
                                Text("MinimumOSVersion")
                                Spacer()
                                TextField("15.0", text: $editMinOS)
                                    .multilineTextAlignment(.trailing)
                            }
                            Toggle("Bật Chia sẻ tệp (UIFileSharing)", isOn: $editFileSharing)
                            if sum.hasSupportedDevicesLimit {
                                Toggle("Gỡ giới hạn thiết bị (UISupportedDevices)", isOn: $removeDeviceLimit)
                            }
                            Button("Lưu thay đổi Info.plist") {
                                store.applyManualEdits(
                                    name: editName,
                                    bundleID: editBundleID,
                                    version: editVersion,
                                    minOS: editMinOS,
                                    fileSharing: editFileSharing,
                                    removeDeviceLimit: removeDeviceLimit
                                )
                            }
                            .fontWeight(.semibold)
                        }

                        // Dọn dẹp nhanh trước khi ký
                        Section("Dọn gói trước khi ký") {
                            if sum.hasPlugIns {
                                Button("Xóa thư mục PlugIns (\(sum.pluginNames.count) extension)", role: .destructive) {
                                    store.removeFolderFromApp("PlugIns")
                                }
                            }
                            if sum.hasWatchDir {
                                Button("Xóa thư mục Watch", role: .destructive) {
                                    store.removeFolderFromApp("Watch")
                                }
                            }
                            if sum.hasCodeSignature {
                                Button("Xóa chữ ký cũ (_CodeSignature)", role: .destructive) {
                                    store.removeFolderFromApp("_CodeSignature")
                                }
                            }
                            if !sum.hasPlugIns && !sum.hasWatchDir && !sum.hasCodeSignature {
                                Text("Gói IPA đã sạch (không có PlugIns, Watch, _CodeSignature).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let prov = sum.provisionSummary {
                            Section("Chứng chỉ đính kèm sẵn") {
                                Text(prov).font(.caption.monospaced())
                            }
                        }

                        if !store.changeLog.isEmpty {
                            Section("Nhật ký chỉnh sửa") {
                                ForEach(store.changeLog.prefix(8), id: \.self) { log in
                                    Text(log).font(.caption.monospaced())
                                }
                            }
                        }
                    }
                    .onAppear { syncForm(sum) }
                    .onChange(of: sum.bundleID) { _ in syncForm(sum) }
                    .onChange(of: sum.displayName) { _ in syncForm(sum) }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "shippingbox.and.arrow.backward")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue)
                        Text("Chưa mở file IPA nào")
                            .font(.title2.bold())
                        Text("Nhập file .ipa từ app Tệp để giải nén, soi Mach-O/Info.plist và để AI chỉnh sửa chuyên sâu.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            NativeFilePicker.shared.pick { urls in
                                if let first = urls.first { store.importIPA(from: first) }
                            }
                        } label: {
                            Label("Nhập file .IPA", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("IPA Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NativeFilePicker.shared.pick { urls in
                            if let first = urls.first { store.importIPA(from: first) }
                        }
                    } label: {
                        Label("Nhập IPA", systemImage: "plus")
                    }
                }
                if store.summary != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            store.clearWorkspace()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
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
                        Text(path).font(.caption.monospaced())
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

// MARK: - Tab 2: AI Studio (Multi-API Picker + Auto-Patch Engine)
struct AIStudioTab: View {
    @ObservedObject var store: IPAStudioManager
    @State private var inputText = ""
    @State private var showModelPicker = false

    private let quickPrompts: [(title: String, prompt: String)] = [
        ("Soi toàn diện IPA", "Hãy soi kỹ toàn bộ file IPA này: kiểm tra mã hóa FairPlay, các quyền nhạy cảm trong Info.plist, dylib/tweak đã nhúng, PlugIns thừa và chỉ ra điểm cần tối ưu."),
        ("Tối ưu để Sideload", "Hãy chỉnh gói IPA này tối ưu nhất để cài sideload: bật UIFileSharingEnabled, gỡ UISupportedDevices, xóa PlugIns, Watch và _CodeSignature."),
        ("Bật chia sẻ tệp", "Bật chia sẻ tệp UIFileSharingEnabled và LSSupportsOpeningDocumentsInPlace trong Info.plist giúp tôi."),
        ("Tìm quảng cáo / SDK", "Kiểm tra Info.plist, Frameworks và cây thư mục xem có SDK quảng cáo hoặc tracking nào không và hướng dẫn xử lý.")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Thanh trạng thái Model AI + Tệp ghim
                HStack(spacing: 10) {
                    Button {
                        showModelPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.selectedProvider.icon)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.selectedProvider.rawValue)
                                    .font(.caption.bold())
                                    .foregroundStyle(.primary)
                                Text(store.selectedModel)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(Capsule())
                    }

                    Spacer()

                    if !store.pinnedFilesForAI.isEmpty {
                        Text("Ghim \(store.pinnedFilesForAI.count) tệp")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }

                    Circle()
                        .fill(store.currentAPIKey.isEmpty ? Color.orange : Color.green)
                        .frame(width: 9, height: 9)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                // Nút lệnh nhanh 1 chạm
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.title) { item in
                            Button {
                                store.sendMessage(item.prompt)
                            } label: {
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .foregroundStyle(.primary)
                                    .clipShape(Capsule())
                            }
                            .disabled(store.isAIThinking)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                Divider()

                // Khung hội thoại AI
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(store.messages) { msg in
                                AIMessageBubble(
                                    message: msg,
                                    canApplyPatch: store.summary != nil,
                                    onApply: { store.applyAIPatch(messageID: msg.id) }
                                )
                                .id(msg.id)
                            }
                            if store.isAIThinking {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("AI đang soi sâu file IPA...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: store.messages.count) { _ in
                        if let last = store.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Ô nhập lệnh
                HStack(spacing: 10) {
                    TextField("Yêu cầu AI soi hoặc sửa IPA...", text: $inputText, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        let text = inputText
                        inputText = ""
                        store.sendMessage(text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAIThinking ? .gray : .blue)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAIThinking)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle("AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Model AI", systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.messages.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }
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
    let canApplyPatch: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
            if let badge = message.modelBadge {
                Text(badge)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(message.text)
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(12)
                .background(message.isUser ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground))
                .foregroundStyle(message.isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let patch = message.patch {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.green)
                        Text(patch.summary ?? "Gói chỉnh sửa AI đề xuất (\(patch.actions.count) bước)")
                            .font(.subheadline.bold())
                    }

                    ForEach(patch.actions) { act in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.blue)
                            Text(act.displayTitle)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        onApply()
                    } label: {
                        Label(
                            message.patchApplied ? "Đã áp dụng vào IPA" : "Áp dụng ngay vào IPA",
                            systemImage: message.patchApplied ? "checkmark.circle.fill" : "bolt.fill"
                        )
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(message.patchApplied ? .green : .blue)
                    .disabled(!canApplyPatch || message.patchApplied)
                }
                .padding(12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

struct AIModelSelectorSheet: View {
    @ObservedObject var store: IPAStudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var customModelInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Chọn nhà cung cấp AI API") {
                    ForEach(AIProvider.allCases) { provider in
                        Button {
                            store.switchProvider(provider)
                        } label: {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if !(store.apiKeys[provider.rawValue] ?? "").isEmpty {
                                    Text("Có Key")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }
                                if store.selectedProvider == provider {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("2. Chọn Model (\(store.selectedProvider.rawValue))") {
                    ForEach(store.selectedProvider.presetModels, id: \.self) { m in
                        Button {
                            store.selectedModel = m
                        } label: {
                            HStack {
                                Text(m)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if store.selectedModel == m {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("Hoặc tự gõ tên model bất kỳ...", text: $customModelInput)
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
                        .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("3. API Key cho \(store.selectedProvider.rawValue)") {
                    SecureField(
                        store.selectedProvider.keyPlaceholder,
                        text: Binding(
                            get: { store.apiKeys[store.selectedProvider.rawValue] ?? "" },
                            set: { store.setAPIKey($0, for: store.selectedProvider) }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if store.selectedProvider == .custom {
                        TextField("https://.../v1/chat/completions", text: $store.customEndpoint)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Chọn Model & API AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tab 3: Deep IPA File Explorer & Editor
struct FileExplorerTab: View {
    @ObservedObject var store: IPAStudioManager

    var body: some View {
        NavigationStack {
            if let sum = store.summary {
                FolderBrowserView(folderURL: sum.appBundleURL, title: sum.appBundleURL.lastPathComponent, store: store)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Chưa có file IPA để duyệt")
                        .font(.headline)
                    Text("Vào tab IPA để nhập và giải nén file .ipa trước.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Tệp IPA")
            }
        }
    }
}

struct FolderBrowserView: View {
    let folderURL: URL
    let title: String
    @ObservedObject var store: IPAStudioManager
    @State private var searchText = ""
    @State private var refreshTick = 0

    var items: [IPAFileNode] {
        _ = refreshTick
        let list = store.listDirectory(folderURL)
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(items) { node in
                if node.isDirectory {
                    NavigationLink {
                        FolderBrowserView(folderURL: node.url, title: node.name, store: store)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(node.name).lineLimit(1)
                        }
                    }
                } else {
                    NavigationLink {
                        FileDetailEditorView(node: node, store: store)
                    } label: {
                        HStack {
                            Image(systemName: node.isTextEditable ? "doc.text.fill" : "doc.fill")
                                .foregroundStyle(node.isTextEditable ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name).lineLimit(1)
                                Text(node.formattedSize)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
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
                let list = items
                for idx in offsets {
                    try? FileManager.default.removeItem(at: list[idx].url)
                }
                refreshTick += 1
                store.refreshWorkspace()
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Lọc tên tệp...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NativeFilePicker.shared.pick(allowsMultiple: true) { urls in
                        store.injectFiles(urls, into: folderURL)
                        refreshTick += 1
                    }
                } label: {
                    Label("Chèn tệp", systemImage: "doc.badge.plus")
                }
            }
        }
    }
}

struct FileDetailEditorView: View {
    let node: IPAFileNode
    @ObservedObject var store: IPAStudioManager
    @State private var textContent = ""
    @State private var hexPreview = ""
    @State private var isPlist = false
    @State private var saveNotice: String?

    var isPinned: Bool {
        store.pinnedFilesForAI.contains(node.relativePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = saveNotice {
                Text(notice)
                    .font(.caption.bold())
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(notice.contains("Lỗi") ? Color.red.opacity(0.25) : Color.green.opacity(0.25))
            }

            if node.isTextEditable {
                TextEditor(text: $textContent)
                    .font(.system(size: 12.5, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tệp nhị phân (\(node.formattedSize)) — Xem trước 2KB Hex:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(hexPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.togglePinForAI(node.relativePath)
                } label: {
                    Image(systemName: isPinned ? "sparkles.rectangle.stack.fill" : "sparkles")
                        .foregroundStyle(isPinned ? .purple : .primary)
                }

                if node.isTextEditable {
                    Button("Lưu") { saveFile() }
                        .fontWeight(.semibold)
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
        } else {
            if let handle = try? FileHandle(forReadingFrom: node.url),
               let sample = try? handle.read(upToCount: 2048) {
                try? handle.close()
                var lines: [String] = []
                for offset in stride(from: 0, to: sample.count, by: 16) {
                    let slice = sample[offset..<min(offset + 16, sample.count)]
                    let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let ascii = slice.map { ($0 >= 32 && $0 <= 126) ? String(UnicodeScalar($0)) : "." }.joined()
                    lines.append(String(format: "%04X: %-47s  %@", offset, (hex as NSString).utf8String!, ascii))
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
            saveNotice = "✓ Đã lưu tệp thành công"
        } catch {
            saveNotice = "Lỗi cú pháp/lưu tệp: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tab 4: All AI APIs & Settings
struct APISettingsTab: View {
    @ObservedObject var store: IPAStudioManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Model AI đang hoạt động") {
                    LabeledContent("Nhà cung cấp", value: store.selectedProvider.rawValue)
                    LabeledContent("Model", value: store.selectedModel)
                }

                Section("Kho API Key (Hỗ trợ tất cả nền tảng AI)") {
                    ForEach(AIProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .font(.subheadline.bold())
                                Spacer()
                                if store.selectedProvider == provider {
                                    Text("Đang dùng")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.blue)
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
                    Toggle("Nén ZLIB khi xuất IPA (nhẹ file hơn)", isOn: $store.compressOnExport)
                    Button("Xóa thư mục giải nén tạm", role: .destructive) {
                        store.clearWorkspace()
                    }
                }
            }
            .navigationTitle("AI API & Cài đặt")
        }
    }
}
