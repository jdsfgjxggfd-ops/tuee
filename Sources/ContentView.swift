import Foundation
import SwiftUI
import UIKit
import Security
import UniformTypeIdentifiers
import PDFKit
import QuickLook
import Compression
import CryptoKit
import Observation
import CoreTransferable

// MARK: - Keychain Secure Storage (No Plain-Text Persistence, Never Logs Keys)
enum KeychainStore: Sendable {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.tueehub.ipastudio.keychain"
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account: account)
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Tự động di trú key cũ từ UserDefaults sang Keychain rồi xóa bản plain text
    static func migrateLegacyUserDefaultsIfNeeded(providerRawValues: [String]) {
        let legacyKeys = [
            "IPAStudio_v55_APIKeys",
            "IPAStudio_v5_APIKeys",
            "IPAStudio_v45_APIKeys"
        ]
        let defaults = UserDefaults.standard
        for storageKey in legacyKeys {
            guard let dict = defaults.dictionary(forKey: storageKey) as? [String: String] else { continue }
            for (rawProvider, secret) in dict {
                let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanSecret.isEmpty else { continue }

                let targetAccount: String
                if providerRawValues.contains(rawProvider) {
                    targetAccount = rawProvider
                } else if rawProvider.localizedCaseInsensitiveContains("Gemini") {
                    targetAccount = "Google Gemini"
                } else if rawProvider.localizedCaseInsensitiveContains("OpenRouter") {
                    targetAccount = "OpenRouter (Free / All)"
                } else if rawProvider.localizedCaseInsensitiveContains("Groq") {
                    targetAccount = "Groq (Siêu nhanh)"
                } else {
                    targetAccount = rawProvider
                }

                if read(account: targetAccount) == nil {
                    _ = save(cleanSecret, account: targetAccount)
                }
            }
            defaults.removeObject(forKey: storageKey)
        }
    }
}

// MARK: - Lightweight Haptics Helper
@MainActor
enum Haptics {
    static func light() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }

    static func medium() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    static func selection() {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }

    static func success() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
    }

    static func error() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
    }
}

// MARK: - Attachment Models
enum AttachmentKind: String, Sendable {
    case image
    case pdf
    case text
    case office
    case archive
    case unsupported
}

struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let fileExtension: String
    let localURL: URL
    let fileSizeBytes: Int64
    let kind: AttachmentKind
    let extractedText: String?
    let imageJPEGData: Data?
    let imageThumbnailData: Data?
    let summaryNote: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var systemImage: String {
        switch kind {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.text.fill"
        case .office: return "doc.badge.gearshape.fill"
        case .archive: return "doc.zipper"
        case .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    var tintColor: Color {
        switch kind {
        case .image: return .orange
        case .pdf: return .red
        case .text: return .blue
        case .office: return .green
        case .archive: return .purple
        case .unsupported: return .secondary
        }
    }

    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AttachmentError: LocalizedError, Sendable {
    case fileTooLarge(name: String, limitMB: Int)
    case unreadable(name: String, reason: String)
    case unsupportedFormat(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let name, let limitMB):
            return "Tệp \"\(name)\" vượt quá giới hạn \(limitMB) MB."
        case .unreadable(let name, let reason):
            return "Không đọc được \"\(name)\": \(reason)"
        case .unsupportedFormat(let name, let detail):
            return "Chưa hỗ trợ trích xuất \"\(name)\": \(detail)"
        }
    }
}

// MARK: - Async Multi-Format File Processor
enum AttachmentProcessor {
    static let maxFileSizeBytes: Int64 = 25 * 1024 * 1024 // 25 MB
    static let maxExtractedChars: Int = 45_000
    static let maxZIPUnpackedBytes: Int = 12 * 1024 * 1024 // Chống zip-bomb

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "bmp", "tiff"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "xml", "plist", "strings",
        "entitlements", "yaml", "yml", "toml", "ini", "cfg", "conf", "log",
        "swift", "m", "mm", "h", "hpp", "c", "cpp", "cs", "java", "kt", "kts",
        "py", "js", "jsx", "ts", "tsx", "html", "htm", "css", "scss", "sql",
        "sh", "zsh", "bash", "lua", "luau", "rb", "go", "rs", "php", "dart", "gradle"
    ]

    private static let officeZipExtensions: Set<String> = ["docx", "xlsx", "pptx"]
    private static let legacyOfficeExtensions: Set<String> = ["doc", "xls", "ppt"]

    static var cacheDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TueeHubChatAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func process(
        sourceURL: URL,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ChatAttachment {
        try await Task.detached(priority: .userInitiated) {
            let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fileName = sourceURL.lastPathComponent
            let ext = sourceURL.pathExtension.lowercased()
            onProgress?(0.08, "Đang kiểm tra \(fileName)...")

            let fm = FileManager.default
            let resourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                throw AttachmentError.unsupportedFormat(
                    name: fileName,
                    detail: "Không hỗ trợ đính kèm trực tiếp thư mục. Hãy nén thành .zip trước."
                )
            }

            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            if fileSize > maxFileSizeBytes {
                throw AttachmentError.fileTooLarge(name: fileName, limitMB: Int(maxFileSizeBytes / (1024 * 1024)))
            }

            // Copy vào vùng nhớ tạm để QuickLook và đọc bất đồng bộ luôn an toàn
            let id = UUID()
            let safeDest = cacheDirectory.appendingPathComponent("\(id.uuidString)_\(fileName)")
            if fm.fileExists(atPath: safeDest.path) {
                try? fm.removeItem(at: safeDest)
            }
            try fm.copyItem(at: sourceURL, to: safeDest)

            let verifiedSize = Int64((try? fm.attributesOfItem(atPath: safeDest.path)[.size] as? Int64) ?? fileSize)
            if verifiedSize > maxFileSizeBytes {
                try? fm.removeItem(at: safeDest)
                throw AttachmentError.fileTooLarge(name: fileName, limitMB: Int(maxFileSizeBytes / (1024 * 1024)))
            }

            try Task.checkCancellation()
            onProgress?(0.25, "Đang xử lý \(fileName)...")

            // 1. Ảnh
            if imageExtensions.contains(ext) {
                let rawData = try Data(contentsOf: safeDest)
                guard let image = UIImage(data: rawData) else {
                    throw AttachmentError.unreadable(name: fileName, reason: "Dữ liệu ảnh bị hỏng.")
                }
                onProgress?(0.65, "Đang tối ưu kích thước ảnh...")
                let resizedJPEG = downscaleToJPEG(image: image, maxSide: 1600, quality: 0.78)
                let thumbJPEG = downscaleToJPEG(image: image, maxSide: 160, quality: 0.72)
                onProgress?(1.0, "Hoàn tất ảnh")
                let pxW = Int(image.size.width * image.scale)
                let pxH = Int(image.size.height * image.scale)
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .image,
                    extractedText: nil,
                    imageJPEGData: resizedJPEG,
                    imageThumbnailData: thumbJPEG,
                    summaryNote: "Ảnh \(pxW)×\(pxH) px (gửi trực tiếp cho AI)"
                )
            }

            // 2. PDF (PDFKit)
            if ext == "pdf" {
                guard let doc = PDFDocument(url: safeDest) else {
                    throw AttachmentError.unreadable(name: fileName, reason: "Không mở được tài liệu PDF (có thể bị khóa mật khẩu hoặc hỏng).")
                }
                if doc.isLocked {
                    throw AttachmentError.unsupportedFormat(name: fileName, detail: "PDF có mật khẩu bảo vệ.")
                }
                let pageCount = doc.pageCount
                var pagesText: [String] = []
                var currentChars = 0
                var truncated = false

                for idx in 0..<pageCount {
                    try Task.checkCancellation()
                    if idx % 3 == 0 || idx == pageCount - 1 {
                        let p = 0.25 + 0.7 * (Double(idx + 1) / Double(max(pageCount, 1)))
                        onProgress?(p, "Đang trích PDF trang \(idx + 1)/\(pageCount)...")
                    }
                    if let pageStr = doc.page(at: idx)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pageStr.isEmpty {
                        let block = "[Trang \(idx + 1)]\n\(pageStr)"
                        if currentChars + block.count > maxExtractedChars {
                            let remain = max(0, maxExtractedChars - currentChars)
                            if remain > 120 {
                                pagesText.append(String(block.prefix(remain)))
                            }
                            truncated = true
                            break
                        }
                        pagesText.append(block)
                        currentChars += block.count
                    }
                }

                let combined = pagesText.joined(separator: "\n\n")
                let note: String
                if combined.isEmpty {
                    note = "PDF \(pageCount) trang (dạng ảnh scan, không có văn bản chọn được)"
                } else if truncated {
                    note = "PDF \(pageCount) trang (đã trích \(maxExtractedChars) ký tự đầu)"
                } else {
                    note = "PDF \(pageCount) trang"
                }

                onProgress?(1.0, "Hoàn tất PDF")
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .pdf,
                    extractedText: combined.isEmpty ? nil : combined,
                    imageJPEGData: nil,
                    imageThumbnailData: nil,
                    summaryNote: note
                )
            }

            // 3. Văn bản / Code / JSON / CSV / Markdown / Plist
            if textExtensions.contains(ext) {
                onProgress?(0.6, "Đang đọc nội dung văn bản...")
                let text: String
                if ext == "plist", let xml = PlistHelper.plistToXMLString(url: safeDest) {
                    text = xml
                } else if let utf8 = try? String(contentsOf: safeDest, encoding: .utf8) {
                    text = utf8
                } else if let latin = try? String(contentsOf: safeDest, encoding: .isoLatin1) {
                    text = latin
                } else {
                    throw AttachmentError.unreadable(name: fileName, reason: "Không giải mã được bảng mã văn bản.")
                }

                let (clipped, wasClipped) = clipText(text, limit: maxExtractedChars)
                onProgress?(1.0, "Hoàn tất")
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .text,
                    extractedText: clipped,
                    imageJPEGData: nil,
                    imageThumbnailData: nil,
                    summaryNote: wasClipped ? "Văn bản (đã cắt còn \(maxExtractedChars) ký tự)" : "Văn bản (\(text.count) ký tự)"
                )
            }

            // 4. Office OpenXML (DOCX, XLSX, PPTX)
            if officeZipExtensions.contains(ext) {
                onProgress?(0.45, "Đang giải nén cấu trúc \(ext.uppercased())...")
                let extracted: String
                switch ext {
                case "docx":
                    extracted = try extractDOCX(from: safeDest)
                case "xlsx":
                    extracted = try extractXLSX(from: safeDest)
                case "pptx":
                    extracted = try extractPPTX(from: safeDest)
                default:
                    extracted = ""
                }
                let (clipped, wasClipped) = clipText(extracted, limit: maxExtractedChars)
                onProgress?(1.0, "Hoàn tất \(ext.uppercased())")
                let note: String
                if clipped.isEmpty {
                    note = "\(ext.uppercased()) không có văn bản trích xuất được"
                } else if wasClipped {
                    note = "\(ext.uppercased()) (đã trích \(maxExtractedChars) ký tự đầu)"
                } else {
                    note = "\(ext.uppercased()) (\(clipped.count) ký tự)"
                }
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .office,
                    extractedText: clipped.isEmpty ? nil : clipped,
                    imageJPEGData: nil,
                    imageThumbnailData: nil,
                    summaryNote: note
                )
            }

            // 5. Legacy Office (.doc, .xls, .ppt) — báo rõ chưa hỗ trợ
            if legacyOfficeExtensions.contains(ext) {
                throw AttachmentError.unsupportedFormat(
                    name: fileName,
                    detail: "Định dạng Office cũ (.\(ext)) dùng chuẩn nhị phân OLE, chưa hỗ trợ trích text. Hãy lưu sang .\(ext)x hoặc .pdf."
                )
            }

            // 6. ZIP / IPA archive
            if ext == "zip" || ext == "ipa" {
                onProgress?(0.5, "Đang liệt kê cấu trúc gói nén...")
                let summary = try extractZIPSummary(from: safeDest)
                let (clipped, _) = clipText(summary, limit: maxExtractedChars)
                onProgress?(1.0, "Hoàn tất gói nén")
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .archive,
                    extractedText: clipped,
                    imageJPEGData: nil,
                    imageThumbnailData: nil,
                    summaryNote: "Gói nén .\(ext) (đã đọc danh sách tệp & text nhỏ)"
                )
            }

            // 7. Thử đọc heuristic nếu là file text không có đuôi chuẩn
            let sampleHandle = try FileHandle(forReadingFrom: safeDest)
            defer { try? sampleHandle.close() }
            let probe = (try? sampleHandle.read(upToCount: 4096)) ?? Data()
            if !probe.isEmpty, isLikelyUTF8Text(probe),
               let fullText = try? String(contentsOf: safeDest, encoding: .utf8) {
                let (clipped, wasClipped) = clipText(fullText, limit: maxExtractedChars)
                onProgress?(1.0, "Hoàn tất")
                return ChatAttachment(
                    id: id,
                    fileName: fileName,
                    fileExtension: ext,
                    localURL: safeDest,
                    fileSizeBytes: verifiedSize,
                    kind: .text,
                    extractedText: clipped,
                    imageJPEGData: nil,
                    imageThumbnailData: nil,
                    summaryNote: wasClipped ? "Tệp văn bản (đã cắt \(maxExtractedChars) ký tự)" : "Tệp văn bản"
                )
            }

            throw AttachmentError.unsupportedFormat(
                name: fileName,
                detail: "Định dạng nhị phân (.\(ext.isEmpty ? "không rõ" : ext)) chưa hỗ trợ trích xuất văn bản cho AI."
            )
        }.value
    }

    static func processImage(_ image: UIImage, suggestedName: String = "Image.jpg") async throws -> ChatAttachment {
        try await Task.detached(priority: .userInitiated) {
            let id = UUID()
            let jpeg = downscaleToJPEG(image: image, maxSide: 1600, quality: 0.78)
            let thumb = downscaleToJPEG(image: image, maxSide: 160, quality: 0.72)
            let safeDest = cacheDirectory.appendingPathComponent("\(id.uuidString)_\(suggestedName)")
            try jpeg.write(to: safeDest, options: .atomic)
            let pxW = Int(image.size.width * image.scale)
            let pxH = Int(image.size.height * image.scale)
            return ChatAttachment(
                id: id,
                fileName: suggestedName,
                fileExtension: "jpg",
                localURL: safeDest,
                fileSizeBytes: Int64(jpeg.count),
                kind: .image,
                extractedText: nil,
                imageJPEGData: jpeg,
                imageThumbnailData: thumb,
                summaryNote: "Ảnh \(pxW)×\(pxH) px"
            )
        }.value
    }

    // MARK: - Helpers
    private static func clipText(_ text: String, limit: Int) -> (String, Bool) {
        if text.count <= limit { return (text, false) }
        return (String(text.prefix(limit)) + "\n\n[...Đã cắt bớt do vượt giới hạn ngữ cảnh...]", true)
    }

    private static func isLikelyUTF8Text(_ data: Data) -> Bool {
        if data.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    private static func downscaleToJPEG(image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        let scaleFactor = longest > maxSide ? (maxSide / longest) : 1.0
        let targetSize = CGSize(
            width: max(1, floor(pixelW * scaleFactor)),
            height: max(1, floor(pixelH * scaleFactor))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: quality) ?? Data()
    }

    // MARK: - Office XML Extractors (DOCX / XLSX / PPTX)
    private static func extractDOCX(from url: URL) throws -> String {
        let entries = try ZIPArchive.readEntriesData(
            zipURL: url,
            matching: { path in
                path == "word/document.xml"
                || (path.hasPrefix("word/header") && path.hasSuffix(".xml"))
                || (path.hasPrefix("word/footer") && path.hasSuffix(".xml"))
            },
            maxTotalBytes: maxZIPUnpackedBytes
        )
        guard let docData = entries["word/document.xml"] else {
            throw AttachmentError.unreadable(name: url.lastPathComponent, reason: "Không tìm thấy word/document.xml bên trong DOCX.")
        }
        let parser = DOCXTextParser()
        return parser.parse(data: docData)
    }

    private static func extractXLSX(from url: URL) throws -> String {
        let entries = try ZIPArchive.readEntriesData(
            zipURL: url,
            matching: { path in
                path == "xl/sharedStrings.xml"
                || (path.hasPrefix("xl/worksheets/sheet") && path.hasSuffix(".xml"))
            },
            maxTotalBytes: maxZIPUnpackedBytes
        )

        let sharedStrings: [String]
        if let ssData = entries["xl/sharedStrings.xml"] {
            sharedStrings = XLSXSharedStringsParser().parse(data: ssData)
        } else {
            sharedStrings = []
        }

        let sheetKeys = entries.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !sheetKeys.isEmpty else {
            throw AttachmentError.unreadable(name: url.lastPathComponent, reason: "Không tìm thấy worksheet nào trong XLSX.")
        }

        var output: [String] = []
        for key in sheetKeys {
            guard let data = entries[key] else { continue }
            let sheetName = (key as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: "")
            let tableText = XLSXSheetParser(sharedStrings: sharedStrings).parse(data: data)
            if !tableText.isEmpty {
                output.append("=== \(sheetName.uppercased()) ===\n\(tableText)")
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func extractPPTX(from url: URL) throws -> String {
        let entries = try ZIPArchive.readEntriesData(
            zipURL: url,
            matching: { path in
                path.hasPrefix("ppt/slides/slide") && path.hasSuffix(".xml")
            },
            maxTotalBytes: maxZIPUnpackedBytes
        )

        let slideKeys = entries.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !slideKeys.isEmpty else {
            throw AttachmentError.unreadable(name: url.lastPathComponent, reason: "Không tìm thấy slide nào trong PPTX.")
        }

        var output: [String] = []
        for (idx, key) in slideKeys.enumerated() {
            guard let data = entries[key] else { continue }
            let text = PPTXSlideParser().parse(data: data)
            if !text.isEmpty {
                output.append("[Slide \(idx + 1)]\n\(text)")
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func extractZIPSummary(from url: URL) throws -> String {
        let list = try ZIPArchive.listEntries(zipURL: url, maxEntries: 300)
        var lines: [String] = ["Danh sách tệp trong gói (\(list.count) mục hiển thị):"]
        for item in list.prefix(180) {
            let sizeStr = item.isDirectory
                ? "dir"
                : ByteCountFormatter.string(fromByteCount: Int64(item.uncompressedSize), countStyle: .file)
            lines.append("- \(item.path) (\(sizeStr))")
        }

        // Trích thêm tối đa 5 file text nhỏ (< 120KB mỗi file) để AI hiểu nội dung chính
        let readableExts = textExtensions
        var pickedCount = 0
        let smallTexts = try ZIPArchive.readEntriesData(
            zipURL: url,
            matching: { path in
                guard pickedCount < 5 else { return false }
                let ext = (path as NSString).pathExtension.lowercased()
                guard readableExts.contains(ext) else { return false }
                if let meta = list.first(where: { $0.path == path }), meta.uncompressedSize <= 120_000 {
                    pickedCount += 1
                    return true
                }
                return false
            },
            maxTotalBytes: 600_000
        )

        if !smallTexts.isEmpty {
            lines.append("\n=== NỘI DUNG TỆP VĂN BẢN BÊN TRONG ===")
            for (path, data) in smallTexts.sorted(by: { $0.key < $1.key }) {
                if let str = String(data: data, encoding: .utf8) {
                    lines.append("--- \(path) ---\n\(String(str.prefix(6000)))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Local XML Parsers (Thread-Safe Per-Invocation)
private final class DOCXTextParser: NSObject, XMLParserDelegate {
    private var result = ""
    private var insideText = false

    func parse(data: Data) -> String {
        result = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "t" {
            insideText = true
        } else if local == "tab" {
            result += "\t"
        } else if local == "br" {
            result += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText {
            result += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "t" {
            insideText = false
        } else if local == "p" {
            if !result.hasSuffix("\n") {
                result += "\n"
            }
        }
    }
}

private final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentItem = ""
    private var insideT = false

    func parse(data: Data) -> [String] {
        strings = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "si" {
            currentItem = ""
        } else if local == "t" {
            insideT = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT {
            currentItem += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "t" {
            insideT = false
        } else if local == "si" {
            strings.append(currentItem)
        }
    }
}

private final class XLSXSheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [String] = []
    private var currentRowCells: [String] = []
    private var currentCellType: String = ""
    private var currentValue: String = ""
    private var captureValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(data: Data) -> String {
        rows = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rows.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "row" {
            currentRowCells = []
        } else if local == "c" {
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
        } else if local == "v" || local == "t" {
            captureValue = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "v" || local == "t" {
            captureValue = false
        } else if local == "c" {
            let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentCellType == "s", let idx = Int(trimmed), idx >= 0, idx < sharedStrings.count {
                currentRowCells.append(sharedStrings[idx])
            } else if !trimmed.isEmpty {
                currentRowCells.append(trimmed)
            }
        } else if local == "row" {
            if !currentRowCells.isEmpty {
                rows.append(currentRowCells.joined(separator: " | "))
            }
        }
    }
}

private final class PPTXSlideParser: NSObject, XMLParserDelegate {
    private var result = ""
    private var insideText = false

    func parse(data: Data) -> String {
        result = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "t" {
            insideText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText {
            result += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "t" {
            insideText = false
        } else if local == "p" {
            if !result.hasSuffix("\n") {
                result += "\n"
            }
        }
    }
}

// MARK: - QuickLook Native Preview Sheet
struct QuickLookItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

struct QuickLookPreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let itemURL: URL

        init(url: URL) {
            self.itemURL = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            itemURL as NSURL
        }
    }
}

// MARK: - AI Provider & Config Models
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
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .openrouter:
            return [
                "google/gemma-3-27b-it:free",
                "deepseek/deepseek-r1-0528:free",
                "meta-llama/llama-3.3-70b-instruct:free",
                "google/gemini-2.5-flash"
            ]
        case .groq:
            return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b"]
        case .openai:
            return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o", "o4-mini"]
        case .claude:
            return ["claude-sonnet-4-20250514", "claude-3-5-haiku-latest"]
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .grok:
            return ["grok-3-mini", "grok-3"]
        case .custom:
            return ["gpt-4o", "claude-sonnet-4", "gemini-2.5-flash"]
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: return "AIza... hoặc AQ.Ab8RN..."
        case .openrouter: return "sk-or-v1-..."
        case .groq: return "gsk_..."
        case .openai: return "sk-proj-..."
        case .claude: return "sk-ant-..."
        case .deepseek: return "sk-..."
        case .grok: return "xai-..."
        case .custom: return "Bearer API Key..."
        }
    }

    /// Gợi ý nhận diện nhà cung cấp từ prefix khi dán key
    static func detectProvider(fromKey key: String) -> AIProvider? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sk-or-v1-") { return .openrouter }
        if k.hasPrefix("sk-ant-") { return .claude }
        if k.hasPrefix("gsk_") { return .groq }
        if k.hasPrefix("xai-") { return .grok }
        if k.hasPrefix("AIza") || k.hasPrefix("AQ.") { return .gemini }
        if k.hasPrefix("sk-proj-") { return .openai }
        return nil
    }
}

enum AIContextDepth: String, CaseIterable, Identifiable, Sendable {
    case fast = "Nhanh"
    case deep = "Sâu"

    var id: String { rawValue }
}

struct AIImagePayload: Sendable {
    let mimeType: String
    let base64: String
}

struct AIChatTurn: Sendable {
    let isUser: Bool
    let text: String
    let images: [AIImagePayload]

    init(isUser: Bool, text: String, images: [AIImagePayload] = []) {
        self.isUser = isUser
        self.text = text
        self.images = images
    }
}

struct ModelScanResult: Sendable {
    let models: [String]
    let recommendedFast: String
    let recommendedDeep: String
    let endpointNote: String?
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

// MARK: - Stream Chunk Coalescer (~60ms UI Batching)
actor StreamChunkCoalescer {
    private(set) var hasReceivedAnyChunk = false
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let onBatch: @Sendable (String) async -> Void

    init(intervalMilliseconds: UInt64 = 60, onBatch: @escaping @Sendable (String) async -> Void) {
        self.intervalNanoseconds = intervalMilliseconds * 1_000_000
        self.onBatch = onBatch
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        hasReceivedAnyChunk = true
        buffer += chunk
        if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                await self.flushNow()
            }
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let out = buffer
        buffer = ""
        await onBatch(out)
    }

    func clear() {
        flushTask?.cancel()
        flushTask = nil
        buffer = ""
    }
}

// MARK: - High-Speed Resilient AI Networking Client (v6)
enum AIClient {
    private static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    private static let scanSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let retryDelaysSeconds: [Double] = [1.0, 2.5]

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let retryableURLCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet
            ]
            return retryableURLCodes.contains(ns.code)
        }
        return ns.code == 429 || (500...599).contains(ns.code)
    }

    private static func sanitizeAlternatingTurns(_ history: [AIChatTurn]) -> [AIChatTurn] {
        var cleaned: [AIChatTurn] = []
        for turn in history {
            let t = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty || !turn.images.isEmpty else { continue }
            if cleaned.isEmpty && !turn.isUser { continue }
            if let last = cleaned.last, last.isUser == turn.isUser {
                let mergedText = [last.text, t].filter { !$0.isEmpty }.joined(separator: "\n\n")
                cleaned[cleaned.count - 1] = AIChatTurn(
                    isUser: last.isUser,
                    text: mergedText,
                    images: last.images + turn.images
                )
            } else {
                cleaned.append(AIChatTurn(isUser: turn.isUser, text: t, images: turn.images))
            }
        }
        return cleaned
    }

    /// Gửi yêu cầu AI kèm streaming gom nhịp và retry backoff tối đa 2 lần
    static func send(
        provider: AIProvider,
        model: String,
        apiKey: String,
        geminiMode: GeminiEndpointMode,
        customEndpoint: String,
        depth: AIContextDepth,
        useStreaming: Bool,
        systemPrompt: String,
        history: [AIChatTurn],
        onRetryStatus: (@Sendable (Int, Int) async -> Void)? = nil,
        onBatchChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(
                domain: "AIClient",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Chưa gắn API Key cho \(provider.rawValue). Bấm vào nút Model phía trên để dán key."]
            )
        }

        let maxRetries = retryDelaysSeconds.count // tối đa 2 lần thử lại (tổng 3 lần)
        var lastError: Error?

        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            let coalescer = StreamChunkCoalescer(intervalMilliseconds: 60, onBatch: onBatchChunk)

            do {
                let rawSend: () async throws -> String = {
                    switch provider {
                    case .gemini:
                        return try await callGemini(
                            model: model,
                            apiKey: cleanKey,
                            mode: geminiMode,
                            depth: depth,
                            useStreaming: useStreaming,
                            systemPrompt: systemPrompt,
                            history: history
                        ) { piece in
                            await coalescer.append(piece)
                        }
                    case .claude:
                        return try await callClaude(
                            model: model,
                            apiKey: cleanKey,
                            depth: depth,
                            useStreaming: useStreaming,
                            systemPrompt: systemPrompt,
                            history: history
                        ) { piece in
                            await coalescer.append(piece)
                        }
                    case .openrouter, .groq, .openai, .deepseek, .grok, .custom:
                        let customClean = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        let endpoint = (provider == .custom && !customClean.isEmpty) ? customClean : provider.defaultEndpoint
                        return try await callOpenAI(
                            endpoint: endpoint,
                            model: model,
                            apiKey: cleanKey,
                            depth: depth,
                            useStreaming: useStreaming,
                            systemPrompt: systemPrompt,
                            history: history
                        ) { piece in
                            await coalescer.append(piece)
                        }
                    }
                }

                let fullText = try await rawSend()
                await coalescer.flushNow()
                return fullText
            } catch {
                await coalescer.clear()
                lastError = error
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                let emitted = await coalescer.hasReceivedAnyChunk
                let canRetry = attempt < maxRetries && !emitted && isRetryable(error)
                if canRetry {
                    await onRetryStatus?(attempt + 1, maxRetries)
                    let delay = retryDelaysSeconds[attempt]
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw enrichError(error)
            }
        }

        throw enrichError(lastError ?? NSError(
            domain: "AIClient",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Không nhận được phản hồi từ máy chủ AI."]
        ))
    }

    // MARK: - Gemini
    private static func callGemini(
        model: String,
        apiKey: String,
        mode: GeminiEndpointMode,
        depth: AIContextDepth,
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
            var parts: [[String: Any]] = []
            if !turn.text.isEmpty {
                parts.append(["text": turn.text])
            }
            for img in turn.images {
                parts.append([
                    "inlineData": [
                        "mimeType": img.mimeType,
                        "data": img.base64
                    ]
                ])
            }
            return ["role": turn.isUser ? "user" : "model", "parts": parts]
        }

        let maxTokens = depth == .deep ? 4096 : 2048
        let plainBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "temperature": depth == .deep ? 0.25 : 0.2,
                "maxOutputTokens": maxTokens
            ]
        ] as [String: Any])

        let bodies: [Data]
        if depth == .fast {
            let fastBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": contents,
                "generationConfig": [
                    "temperature": 0.2,
                    "maxOutputTokens": maxTokens,
                    "thinkingConfig": ["thinkingBudget": 0]
                ]
            ] as [String: Any])
            bodies = [fastBody, plainBody]
        } else {
            bodies = [plainBody]
        }

        var lastError: Error?
        for (baseIdx, baseStr) in candidateBases.enumerated() {
            guard var comps = URLComponents(string: baseStr) else { continue }
            var qItems = [URLQueryItem(name: "key", value: apiKey)]
            if useStreaming { qItems.insert(URLQueryItem(name: "alt", value: "sse"), at: 0) }
            comps.queryItems = qItems
            guard let url = comps.url else { continue }

            for (bodyIdx, payload) in bodies.enumerated() {
                try Task.checkCancellation()
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload

                do {
                    if useStreaming {
                        let (bytes, response) = try await streamSession.bytes(for: req)
                        try await validateStreamHTTP(response: response, bytes: bytes)
                        var accumulated = ""
                        for try await line in bytes.lines {
                            if Task.isCancelled { throw CancellationError() }
                            guard line.hasPrefix("data:") else { continue }
                            let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            guard !jsonStr.isEmpty, jsonStr != "[DONE]",
                                  let data = jsonStr.data(using: .utf8),
                                  let text = extractGeminiText(from: data), !text.isEmpty else { continue }
                            accumulated += text
                            await onChunk(text)
                        }
                        if accumulated.isEmpty && !Task.isCancelled {
                            throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Máy chủ Gemini không trả về nội dung."])
                        }
                        return accumulated
                    } else {
                        let (data, response) = try await streamSession.data(for: req)
                        try validateDataHTTP(response: response, data: data)
                        let text = extractGeminiText(from: data) ?? ""
                        if !text.isEmpty { await onChunk(text) }
                        return text
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    lastError = error
                    let code = (error as NSError).code
                    if code == 400 && bodyIdx + 1 < bodies.count {
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

        throw lastError ?? NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Không kết nối được Google Gemini API."])
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

    // MARK: - Anthropic Claude
    private static func callClaude(
        model: String,
        apiKey: String,
        depth: AIContextDepth,
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
        let messages: [[String: Any]] = safeHistory.map { turn in
            if turn.images.isEmpty {
                return ["role": turn.isUser ? "user" : "assistant", "content": turn.text]
            }
            var blocks: [[String: Any]] = turn.images.map { img in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": img.mimeType,
                        "data": img.base64
                    ]
                ]
            }
            if !turn.text.isEmpty {
                blocks.append(["type": "text", "text": turn.text])
            }
            return ["role": turn.isUser ? "user" : "assistant", "content": blocks]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": depth == .deep ? 4096 : 2048,
            "stream": useStreaming,
            "system": systemPrompt,
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        if useStreaming {
            let (bytes, response) = try await streamSession.bytes(for: req)
            try await validateStreamHTTP(response: response, bytes: bytes)
            var accumulated = ""
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
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
            let (data, response) = try await streamSession.data(for: req)
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

    // MARK: - OpenAI-Compatible (OpenAI, OpenRouter, Groq, DeepSeek, Grok, Custom)
    private static func callOpenAI(
        endpoint: String,
        model: String,
        apiKey: String,
        depth: AIContextDepth,
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
            if turn.images.isEmpty {
                messages.append(["role": turn.isUser ? "user" : "assistant", "content": turn.text])
            } else {
                var parts: [[String: Any]] = []
                if !turn.text.isEmpty {
                    parts.append(["type": "text", "text": turn.text])
                }
                for img in turn.images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64)"]
                    ])
                }
                messages.append(["role": turn.isUser ? "user" : "assistant", "content": parts])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "stream": useStreaming,
            "messages": messages,
            "temperature": depth == .deep ? 0.25 : 0.2
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        if useStreaming {
            let (bytes, response) = try await streamSession.bytes(for: req)
            try await validateStreamHTTP(response: response, bytes: bytes)
            var accumulated = ""
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
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
            let (data, response) = try await streamSession.data(for: req)
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

    // MARK: - Live Key Verification, Model Scanning & Smart Fast/Deep Picker
    static func scanModels(
        provider: AIProvider,
        apiKey: String,
        geminiMode: GeminiEndpointMode,
        customEndpoint: String
    ) async throws -> ModelScanResult {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "AIClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Hãy dán API Key trước khi quét."])
        }

        if provider == .gemini {
            let vertexBase = "https://aiplatform.googleapis.com/v1/publishers/google/models"
            let aiStudioBase = "https://generativelanguage.googleapis.com/v1beta/models"
            let candidates: [(base: String, label: String)]
            switch geminiMode {
            case .vertex: candidates = [(vertexBase, "Vertex AI")]
            case .aiStudio: candidates = [(aiStudioBase, "AI Studio")]
            case .auto:
                candidates = cleanKey.hasPrefix("AQ.")
                    ? [(vertexBase, "Vertex AI"), (aiStudioBase, "AI Studio")]
                    : [(aiStudioBase, "AI Studio"), (vertexBase, "Vertex AI")]
            }

            var lastErr: Error?
            for candidate in candidates {
                try Task.checkCancellation()
                guard var comps = URLComponents(string: candidate.base) else { continue }
                comps.queryItems = [URLQueryItem(name: "key", value: cleanKey)]
                guard let url = comps.url else { continue }

                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    let (data, response) = try await scanSession.data(for: req)
                    try validateDataHTTP(response: response, data: data)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["models"] as? [[String: Any]] {
                        let rawNames = models.compactMap { item -> String? in
                            guard let raw = item["name"] as? String else { return nil }
                            if let methods = item["supportedGenerationMethods"] as? [String],
                               !methods.contains("generateContent") {
                                return nil
                            }
                            return raw.components(separatedBy: "/").last
                        }
                        let filtered = filterChatModels(rawNames, provider: .gemini)
                        if !filtered.isEmpty {
                            let picked = pickFastAndDeep(from: filtered, provider: .gemini)
                            return ModelScanResult(
                                models: filtered,
                                recommendedFast: picked.fast,
                                recommendedDeep: picked.deep,
                                endpointNote: candidate.label
                            )
                        }
                    }
                } catch {
                    if error is CancellationError { throw error }
                    lastErr = error
                }
            }
            throw enrichError(lastErr ?? NSError(domain: "AIClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Key không hợp lệ hoặc không có model Gemini khả dụng."]))
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
            let cleanBase = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = cleanBase.replacingOccurrences(of: "/chat/completions", with: "")
            modelsEndpoint = stripped.hasSuffix("/") ? "\(stripped)models" : "\(stripped)/models"
        case .gemini:
            modelsEndpoint = ""
        }

        guard let url = URL(string: modelsEndpoint) else {
            throw NSError(domain: "AIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Endpoint quét model không hợp lệ."])
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if provider == .claude {
            req.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await scanSession.data(for: req)
        try validateDataHTTP(response: response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw NSError(domain: "AIClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Dữ liệu danh sách model trả về không đúng định dạng."])
        }

        let rawIDs = list.compactMap { $0["id"] as? String }
        let filtered = filterChatModels(rawIDs, provider: provider)
        guard !filtered.isEmpty else {
            throw NSError(domain: "AIClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "API Key hợp lệ nhưng không có model chat nào khả dụng."])
        }

        let picked = pickFastAndDeep(from: filtered, provider: provider)
        return ModelScanResult(
            models: filtered,
            recommendedFast: picked.fast,
            recommendedDeep: picked.deep,
            endpointNote: nil
        )
    }

    private static func filterChatModels(_ raw: [String], provider: AIProvider) -> [String] {
        let excludedKeywords = [
            "embedding", "embed", "whisper", "tts", "dall-e", "imagen", "veo",
            "moderation", "audio", "realtime", "transcribe", "sora", "babbage",
            "davinci", "aqa", "lyria", "playai", "guard", "vision-preview-only",
            "speech", "image-gen", "video"
        ]

        var seen: Set<String> = []
        let filtered = raw.filter { id in
            let lower = id.lowercased()
            guard !seen.contains(id) else { return false }
            if excludedKeywords.contains(where: { lower.contains($0) }) {
                return false
            }
            switch provider {
            case .openai:
                let allowedPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
                guard allowedPrefixes.contains(where: { lower.hasPrefix($0) }) else { return false }
            case .gemini:
                guard lower.contains("gemini") || lower.contains("gemma") else { return false }
            case .claude:
                guard lower.contains("claude") else { return false }
            case .grok:
                guard lower.contains("grok") else { return false }
            case .deepseek:
                guard lower.contains("deepseek") else { return false }
            case .groq, .openrouter, .custom:
                break
            }
            seen.insert(id)
            return true
        }

        // Sắp xếp đưa model mới/nổi bật lên trước
        return filtered.sorted { a, b in
            let sa = modelRecencyScore(a)
            let sb = modelRecencyScore(b)
            if sa != sb { return sa > sb }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private static func pickFastAndDeep(from models: [String], provider: AIProvider) -> (fast: String, deep: String) {
        let fastScore: (String) -> Int = { name in
            let l = name.lowercased()
            var score = modelRecencyScore(name)
            if l.contains("flash-lite") || l.contains("nano") { score += 55 }
            if l.contains("flash") || l.contains("mini") || l.contains("haiku") || l.contains("instant") { score += 80 }
            if l.contains("8b") || l.contains("chat") { score += 35 }
            if provider == .openrouter && l.contains(":free") { score += 90 }
            if l.contains("pro") || l.contains("opus") || l.contains("reasoner") || l.contains("r1") { score -= 25 }
            return score
        }

        let deepScore: (String) -> Int = { name in
            let l = name.lowercased()
            var score = modelRecencyScore(name)
            if l.contains("opus") || l.contains("reasoner") || l.contains("r1") || l.contains("o3") || l.contains("o4") { score += 85 }
            if l.contains("pro") || l.contains("sonnet") || l.contains("gpt-5") || l.contains("gpt-4.1") || l.contains("120b") || l.contains("70b") { score += 75 }
            if l.contains("grok-4") || l.contains("grok-3") { score += 65 }
            if provider == .openrouter && l.contains(":free") { score += 60 }
            if l.contains("mini") || l.contains("nano") || l.contains("lite") || l.contains("haiku") || l.contains("8b") { score -= 30 }
            return score
        }

        let bestFast = models.max(by: { fastScore($0) < fastScore($1) }) ?? models[0]
        let bestDeep = models.max(by: { deepScore($0) < deepScore($1) }) ?? bestFast
        return (bestFast, bestDeep)
    }

    private static func modelRecencyScore(_ id: String) -> Int {
        let lower = id.lowercased()
        var score = 0
        if lower.contains("preview") || lower.contains("exp") { score -= 5 }
        if lower.contains("latest") { score += 12 }

        // Trích số phiên bản lớn nhất trong tên model (vd 2.5 -> 25, 4.1 -> 41, 3.8 -> 38)
        let tokens = lower.components(separatedBy: CharacterSet(charactersIn: "-_/ :"))
        for token in tokens {
            if let num = Double(token), num > 0 && num < 100 {
                score += Int(num * 10)
            } else if token.hasPrefix("v"), let num = Double(token.dropFirst()), num > 0 && num < 100 {
                score += Int(num * 10)
            }
        }
        return score
    }

    // MARK: - HTTP Validation & Friendly Error Messages
    private static func validateStreamHTTP(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        var errText = ""
        for try await line in bytes.lines {
            errText += line
            if errText.count > 460 { break }
        }
        throw NSError(
            domain: "AIClient",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: formatHTTPError(code: http.statusCode, rawBody: errText)]
        )
    }

    private static func validateDataHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        let errText = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
            domain: "AIClient",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: formatHTTPError(code: http.statusCode, rawBody: String(errText.prefix(460)))]
        )
    }

    private static func formatHTTPError(code: Int, rawBody: String) -> String {
        switch code {
        case 401: return "API Key không hợp lệ hoặc đã bị thu hồi (401)."
        case 403: return "API Key không có quyền truy cập model/endpoint này (403). \(rawBody)"
        case 404: return "Model không tồn tại hoặc key không hỗ trợ model này (404). Hãy bấm Quét lại model."
        case 429: return "Vượt giới hạn tốc độ / hết hạn mức (429). Đã tự thử lại nhưng máy chủ vẫn bận."
        case 500...599: return "Máy chủ AI đang quá tải (\(code)). Đã tự thử lại không thành công, hãy bấm Thử lại sau vài giây."
        default: return "Lỗi API (\(code)): \(rawBody)"
        }
    }

    private static func enrichError(_ error: Error) -> Error {
        let ns = error as NSError
        let msg = ns.localizedDescription
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return NSError(domain: "AIClient", code: ns.code, userInfo: [NSLocalizedDescriptionKey: "Quá thời gian phản hồi sau khi đã thử lại. Hãy kiểm tra mạng hoặc bấm Thử lại."])
            case NSURLErrorNotConnectedToInternet:
                return NSError(domain: "AIClient", code: ns.code, userInfo: [NSLocalizedDescriptionKey: "Thiết bị đang ngoại tuyến. Hãy kiểm tra Wi-Fi hoặc 5G rồi bấm Thử lại."])
            case NSURLErrorNetworkConnectionLost:
                return NSError(domain: "AIClient", code: ns.code, userInfo: [NSLocalizedDescriptionKey: "Kết nối mạng bị ngắt giữa chừng. Hãy bấm Thử lại."])
            default:
                break
            }
        }
        if ns.code == 403 && (msg.contains("aiplatform.googleapis.com") || msg.contains("PERMISSION_DENIED")) {
            return NSError(domain: "AIClient", code: 403, userInfo: [NSLocalizedDescriptionKey: "Dự án Google Cloud chưa bật Vertex AI API (aiplatform.googleapis.com). Hãy đổi Cổng Gemini sang AI Studio hoặc bật Vertex AI trong Google Cloud Console."])
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
                if let p = action.path,
                   let u = resolveSafeURL(p, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                   !urls.contains(u) {
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
                guard let rel = action.path,
                      let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                      let key = action.key,
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
                guard let rel = action.path,
                      let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot) else {
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
                guard let rel = action.path,
                      let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
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
                guard let rel = action.path,
                      let target = resolveSafeURL(rel, appBundleURL: appBundleURL, workspaceRoot: workspaceRoot),
                      let find = action.find,
                      let replace = action.replace,
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

// MARK: - Pure Swift ZIP Extractor, Selective Reader & Repacker
enum ZIPArchiveError: LocalizedError, Sendable {
    case invalidArchive(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let msg): return "File nén/IPA không hợp lệ: \(msg)"
        case .ioFailed(let msg): return "Lỗi đọc/ghi tệp: \(msg)"
        }
    }
}

struct ZIPListEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let compressedSize: UInt32
    let uncompressedSize: UInt32
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

    private static func readCentralDirectory(handle: FileHandle) throws -> [CentralEntry] {
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
        return entries
    }

    private static func readEntryPayload(handle: FileHandle, entry: CentralEntry) throws -> Data {
        try handle.seek(toOffset: UInt64(entry.localOffset))
        guard let localHeader = try handle.read(upToCount: 30), localHeader.count == 30 else {
            throw ZIPArchiveError.invalidArchive("Local header lỗi tại \(entry.name)")
        }
        let localNameLen = Int(readU16LE(localHeader, 26))
        let localExtraLen = Int(readU16LE(localHeader, 28))
        try handle.seek(toOffset: UInt64(entry.localOffset) + 30 + UInt64(localNameLen + localExtraLen))

        let rawData: Data = entry.compressedSize == 0
            ? Data()
            : ((try handle.read(upToCount: Int(entry.compressedSize))) ?? Data())

        if entry.method == 0 {
            return rawData
        } else if entry.method == 8 {
            guard let decoded = decompressDeflate(rawData, expectedSize: Int(entry.uncompressedSize)) else {
                throw ZIPArchiveError.invalidArchive("Giải nén lỗi tại \(entry.name)")
            }
            return decoded
        } else {
            throw ZIPArchiveError.invalidArchive("Phương thức nén \(entry.method) không hỗ trợ")
        }
    }

    /// Liệt kê nhanh cấu trúc gói ZIP/DOCX/XLSX/PPTX không cần giải nén ra đĩa
    static func listEntries(zipURL: URL, maxEntries: Int = 500) throws -> [ZIPListEntry] {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        let entries = try readCentralDirectory(handle: handle)
        return entries.prefix(maxEntries).compactMap { e in
            guard !e.name.isEmpty, !e.name.contains(".."), !e.name.hasPrefix("__MACOSX/") else { return nil }
            return ZIPListEntry(
                path: e.name,
                isDirectory: e.name.hasSuffix("/"),
                compressedSize: e.compressedSize,
                uncompressedSize: e.uncompressedSize
            )
        }
    }

    /// Giải nén chọn lọc vào RAM (dùng cho DOCX, XLSX, PPTX, ZIP preview) kèm giới hạn dung lượng
    static func readEntriesData(
        zipURL: URL,
        matching predicate: (String) -> Bool,
        maxTotalBytes: Int
    ) throws -> [String: Data] {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        let entries = try readCentralDirectory(handle: handle)
        var result: [String: Data] = [:]
        var accumulated = 0

        for entry in entries {
            guard !entry.name.isEmpty,
                  !entry.name.hasSuffix("/"),
                  !entry.name.contains(".."),
                  !entry.name.hasPrefix("__MACOSX/"),
                  predicate(entry.name) else { continue }

            let expected = Int(entry.uncompressedSize)
            if accumulated + expected > maxTotalBytes {
                continue
            }
            let data = try readEntryPayload(handle: handle, entry: entry)
            if accumulated + data.count > maxTotalBytes {
                continue
            }
            accumulated += data.count
            result[entry.name] = data
        }
        return result
    }

    static func extract(ipaURL: URL, to destinationDir: URL, onProgress: (@Sendable (Double, String) -> Void)? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDir.path) {
            try fm.removeItem(at: destinationDir)
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: ipaURL)
        defer { try? handle.close() }

        let entries = try readCentralDirectory(handle: handle)
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
                let finalData = try readEntryPayload(handle: handle, entry: entry)
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
    static let keepSet: Set<String> = [
        "base.lproj", "en.lproj", "en-us.lproj", "en_us.lproj",
        "vi.lproj", "vi-vn.lproj", "vi_vn.lproj"
    ]

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

// MARK: - Workspace Value Models
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
    let iconPNGData: Data?
}

struct UndoSnapshotEntry: Sendable {
    let targetURL: URL
    let backupURL: URL?
    let existedBefore: Bool
}

struct ToastBannerData: Equatable, Sendable {
    let id = UUID()
    let text: String
    let isError: Bool
}

// MARK: - Observable Message Model (Chống render lại cả danh sách khi streaming)
@Observable
@MainActor
final class AIMessage: Identifiable {
    let id: UUID
    let isUser: Bool
    var text: String
    var modelBadge: String?
    var statusNote: String?
    var patch: AIPatchEnvelope?
    var patchApplied: Bool
    var isStreaming: Bool
    var waitingSeconds: Int
    var failedPrompt: String?
    var failedAttachments: [ChatAttachment]
    let attachments: [ChatAttachment]

    init(
        id: UUID = UUID(),
        isUser: Bool,
        text: String,
        modelBadge: String? = nil,
        statusNote: String? = nil,
        patch: AIPatchEnvelope? = nil,
        patchApplied: Bool = false,
        isStreaming: Bool = false,
        waitingSeconds: Int = 0,
        failedPrompt: String? = nil,
        failedAttachments: [ChatAttachment] = [],
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.modelBadge = modelBadge
        self.statusNote = statusNote
        self.patch = patch
        self.patchApplied = patchApplied
        self.isStreaming = isStreaming
        self.waitingSeconds = waitingSeconds
        self.failedPrompt = failedPrompt
        self.failedAttachments = failedAttachments
        self.attachments = attachments
    }
}

// MARK: - Key Scan Validation State
enum KeyValidationState: Equatable, Sendable {
    case empty
    case scanning
    case valid(count: Int, note: String?)
    case invalid(String)
}

// MARK: - Store 1: API Configuration, Keychain & Auto Model Scanner
@Observable
@MainActor
final class APIConfigStore {
    var selectedProvider: AIProvider = .gemini
    var contextDepth: AIContextDepth = .fast
    var geminiEndpointMode: GeminiEndpointMode = .auto
    var customEndpoint: String = ""
    var useStreaming: Bool = true

    // Cache Keychain trên RAM (không ghi vào UserDefaults)
    private(set) var keyCache: [AIProvider: String] = [:]
    var scannedModelsByProvider: [AIProvider: [String]] = [:]
    var fastModelByProvider: [AIProvider: String] = [:]
    var deepModelByProvider: [AIProvider: String] = [:]
    var validationByProvider: [AIProvider: KeyValidationState] = [:]

    @ObservationIgnored var onCancelActiveChatRequest: (() -> Void)?
    @ObservationIgnored var onNotifyToast: ((String, Bool) -> Void)?
    @ObservationIgnored private var scanTasks: [AIProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounceTasks: [AIProvider: Task<Void, Never>] = [:]

    private let providerKey = "IPAStudio_v6_Provider"
    private let geminiModeKey = "IPAStudio_v6_GeminiMode"
    private let depthKey = "IPAStudio_v6_Depth"
    private let streamingKey = "IPAStudio_v6_Streaming"
    private let customEndpointKey = "IPAStudio_CustomEndpoint"
    private let scannedModelsKey = "IPAStudio_v6_ScannedModels"
    private let fastModelsKey = "IPAStudio_v6_FastModels"
    private let deepModelsKey = "IPAStudio_v6_DeepModels"

    init() {
        KeychainStore.migrateLegacyUserDefaultsIfNeeded(providerRawValues: AIProvider.allCases.map(\.rawValue))

        let defaults = UserDefaults.standard
        if let rawP = defaults.string(forKey: providerKey), let parsed = AIProvider(rawValue: rawP) {
            selectedProvider = parsed
        }
        if let rawMode = defaults.string(forKey: geminiModeKey), let parsedMode = GeminiEndpointMode(rawValue: rawMode) {
            geminiEndpointMode = parsedMode
        }
        if let rawD = defaults.string(forKey: depthKey), let parsedD = AIContextDepth(rawValue: rawD) {
            contextDepth = parsedD
        }
        if defaults.object(forKey: streamingKey) != nil {
            useStreaming = defaults.bool(forKey: streamingKey)
        }
        customEndpoint = defaults.string(forKey: customEndpointKey) ?? ""

        if let data = defaults.data(forKey: scannedModelsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (k, v) in decoded {
                if let p = AIProvider(rawValue: k) { scannedModelsByProvider[p] = v }
            }
        }
        if let dict = defaults.dictionary(forKey: fastModelsKey) as? [String: String] {
            for (k, v) in dict {
                if let p = AIProvider(rawValue: k) { fastModelByProvider[p] = v }
            }
        }
        if let dict = defaults.dictionary(forKey: deepModelsKey) as? [String: String] {
            for (k, v) in dict {
                if let p = AIProvider(rawValue: k) { deepModelByProvider[p] = v }
            }
        }

        // Nạp toàn bộ key từ Keychain
        for provider in AIProvider.allCases {
            if let secret = KeychainStore.read(account: provider.rawValue), !secret.isEmpty {
                keyCache[provider] = secret
                if let cachedModels = scannedModelsByProvider[provider], !cachedModels.isEmpty {
                    validationByProvider[provider] = .valid(count: cachedModels.count, note: nil)
                }
            } else {
                validationByProvider[provider] = .empty
            }
        }
    }

    // MARK: - Computed Properties
    var currentAPIKey: String {
        keyCache[selectedProvider] ?? ""
    }

    var activeModel: String {
        model(for: selectedProvider, depth: contextDepth)
    }

    func apiKey(for provider: AIProvider) -> String {
        keyCache[provider] ?? ""
    }

    func hasKey(for provider: AIProvider) -> Bool {
        !(keyCache[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func availableModels(for provider: AIProvider) -> [String] {
        if let scanned = scannedModelsByProvider[provider], !scanned.isEmpty {
            return scanned
        }
        return provider.presetModels
    }

    func model(for provider: AIProvider, depth: AIContextDepth) -> String {
        switch depth {
        case .fast:
            if let saved = fastModelByProvider[provider], !saved.isEmpty { return saved }
            return availableModels(for: provider).first ?? provider.presetModels.first ?? ""
        case .deep:
            if let saved = deepModelByProvider[provider], !saved.isEmpty { return saved }
            let list = availableModels(for: provider)
            return list.count > 1 ? list[1] : (list.first ?? provider.presetModels.first ?? "")
        }
    }

    func validationState(for provider: AIProvider) -> KeyValidationState {
        validationByProvider[provider] ?? (hasKey(for: provider) ? .valid(count: availableModels(for: provider).count, note: nil) : .empty)
    }

    // MARK: - Instant Switching (Always Cancels Running Chat Request)
    func switchProvider(_ provider: AIProvider) {
        guard selectedProvider != provider else { return }
        onCancelActiveChatRequest?()
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
        Haptics.selection()
    }

    func switchDepth(_ depth: AIContextDepth) {
        guard contextDepth != depth else { return }
        onCancelActiveChatRequest?()
        contextDepth = depth
        UserDefaults.standard.set(depth.rawValue, forKey: depthKey)
        Haptics.selection()
    }

    func setModel(_ modelName: String, for provider: AIProvider, depth: AIContextDepth) {
        let clean = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onCancelActiveChatRequest?()
        switch depth {
        case .fast:
            fastModelByProvider[provider] = clean
            persistModelDict(fastModelByProvider, key: fastModelsKey)
        case .deep:
            deepModelByProvider[provider] = clean
            persistModelDict(deepModelByProvider, key: deepModelsKey)
        }
        Haptics.selection()
    }

    func setGeminiEndpointMode(_ mode: GeminiEndpointMode) {
        guard geminiEndpointMode != mode else { return }
        onCancelActiveChatRequest?()
        geminiEndpointMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: geminiModeKey)
        if hasKey(for: .gemini) {
            scanModels(for: .gemini, userInitiated: false)
        }
    }

    func setCustomEndpoint(_ value: String) {
        customEndpoint = value
        UserDefaults.standard.set(value, forKey: customEndpointKey)
    }

    func setUseStreaming(_ value: Bool) {
        useStreaming = value
        UserDefaults.standard.set(value, forKey: streamingKey)
    }

    // MARK: - Keychain Save + Auto-Scan on Paste
    func updateAPIKey(_ newValue: String, for provider: AIProvider) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = keyCache[provider] ?? ""
        if trimmed == previous { return }

        if trimmed.isEmpty {
            keyCache.removeValue(forKey: provider)
            KeychainStore.delete(account: provider.rawValue)
            debounceTasks[provider]?.cancel()
            scanTasks[provider]?.cancel()
            scannedModelsByProvider.removeValue(forKey: provider)
            validationByProvider[provider] = .empty
            persistScannedModels()
            return
        }

        keyCache[provider] = trimmed
        KeychainStore.save(trimmed, account: provider.rawValue)

        // Tự động debounce rồi quét model ngay khi người dùng dán hoặc nhập xong key
        debounceTasks[provider]?.cancel()
        let looksLikePaste = abs(trimmed.count - previous.count) >= 10
        let delayMs: UInt64 = looksLikePaste ? 350 : 900

        debounceTasks[provider] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            self?.scanModels(for: provider, userInitiated: false)
        }
    }

    func scanModels(for provider: AIProvider, userInitiated: Bool) {
        let key = apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationByProvider[provider] = .empty
            if userInitiated {
                onNotifyToast?("Hãy dán API Key trước khi quét.", true)
            }
            return
        }

        scanTasks[provider]?.cancel()
        validationByProvider[provider] = .scanning
        let mode = geminiEndpointMode
        let customEP = customEndpoint

        scanTasks[provider] = Task { [weak self] in
            do {
                let result = try await AIClient.scanModels(
                    provider: provider,
                    apiKey: key,
                    geminiMode: mode,
                    customEndpoint: customEP
                )
                guard !Task.isCancelled, let self else { return }

                self.scannedModelsByProvider[provider] = result.models
                self.persistScannedModels()

                // Nếu model hiện tại không còn trong danh sách hợp lệ thì tự gán cặp Nhanh / Sâu tối ưu
                if let currentFast = self.fastModelByProvider[provider], result.models.contains(currentFast) {
                    // Giữ lựa chọn tay nếu còn hợp lệ
                } else {
                    self.fastModelByProvider[provider] = result.recommendedFast
                    self.persistModelDict(self.fastModelByProvider, key: self.fastModelsKey)
                }

                if let currentDeep = self.deepModelByProvider[provider], result.models.contains(currentDeep) {
                    // Giữ lựa chọn tay nếu còn hợp lệ
                } else {
                    self.deepModelByProvider[provider] = result.recommendedDeep
                    self.persistModelDict(self.deepModelByProvider, key: self.deepModelsKey)
                }

                self.validationByProvider[provider] = .valid(count: result.models.count, note: result.endpointNote)
                if userInitiated {
                    Haptics.success()
                    self.onNotifyToast?("Đã quét \(result.models.count) model khả dụng cho \(provider.rawValue)", false)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.validationByProvider[provider] = .invalid(error.localizedDescription)
                if userInitiated {
                    Haptics.error()
                }
            }
        }
    }

    private func persistScannedModels() {
        var raw: [String: [String]] = [:]
        for (p, list) in scannedModelsByProvider {
            raw[p.rawValue] = list
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: scannedModelsKey)
        }
    }

    private func persistModelDict(_ dict: [AIProvider: String], key: String) {
        var raw: [String: String] = [:]
        for (p, m) in dict {
            raw[p.rawValue] = m
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

// MARK: - Store 2: IPA Workspace & Off-Main-Thread File Operations
@Observable
@MainActor
final class IPAWorkspaceStore {
    var summary: IPAWorkspaceSummary?
    var appIconImage: UIImage?
    var isBusy = false
    var busyTitle = ""
    var busyProgress: Double = 0
    var busyDetail = ""
    var alertMessage: String?
    var toast: ToastBannerData?
    var changeLog: [String] = []
    var pinnedFilesForAI: [String] = []
    var scannedBinaryURLs: [String] = []
    var includeBinaryURLsInAI = false
    var includeEntitlementsInAI = false
    var isScanningBinary = false
    var canUndo = false
    var iconRefreshID = UUID()
    var compressOnExport: Bool = true

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastUndoEntries: [UndoSnapshotEntry] = []

    private let compressKey = "IPAStudio_Compress"
    private let lastSourceNameKey = "IPAStudio_v55_LastSource"
    private let lastSourceSizeKey = "IPAStudio_v55_LastSize"
    private let lastSourceSHAKey = "IPAStudio_v55_LastSHA"

    nonisolated var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated var workspaceDir: URL {
        documentsDir.appendingPathComponent("ActiveIPAWorkspace", isDirectory: true)
    }

    nonisolated var undoBackupDir: URL {
        documentsDir.appendingPathComponent("UndoBackup", isDirectory: true)
    }

    nonisolated var exportsDir: URL {
        let dir = documentsDir.appendingPathComponent("ExportedIPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if UserDefaults.standard.object(forKey: compressKey) != nil {
            compressOnExport = UserDefaults.standard.bool(forKey: compressKey)
        }
        Task { await restoreExistingWorkspaceIfNeeded() }
    }

    func setCompressOnExport(_ value: Bool) {
        compressOnExport = value
        UserDefaults.standard.set(value, forKey: compressKey)
    }

    func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.snappy) {
            toast = ToastBannerData(text: text, isError: isError)
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }

    private func applySummary(_ analyzed: IPAWorkspaceSummary) {
        summary = analyzed
        if let data = analyzed.iconPNGData {
            appIconImage = UIImage(data: data)
        } else {
            appIconImage = nil
        }
    }

    private func restoreExistingWorkspaceIfNeeded() async {
        let root = workspaceDir
        let srcName = UserDefaults.standard.string(forKey: lastSourceNameKey) ?? "Restored.ipa"
        let origSize = Int64(UserDefaults.standard.integer(forKey: lastSourceSizeKey))
        let sha = UserDefaults.standard.string(forKey: lastSourceSHAKey) ?? "N/A"

        let analyzed: IPAWorkspaceSummary? = await Task.detached(priority: .utility) {
            let payloadDir = root.appendingPathComponent("Payload")
            guard FileManager.default.fileExists(atPath: payloadDir.path) else { return nil }
            return try? Self.analyzeWorkspace(root: root, sourceName: srcName, originalSize: origSize, shaShort: sha)
        }.value

        if let analyzed {
            applySummary(analyzed)
        }
    }

    // MARK: - Async Undo Snapshot
    nonisolated static func createUndoSnapshot(for targets: [URL], backupDir: URL) -> [UndoSnapshotEntry] {
        let fm = FileManager.default
        try? fm.removeItem(at: backupDir)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var entries: [UndoSnapshotEntry] = []
        for (i, target) in targets.enumerated() {
            if fm.fileExists(atPath: target.path) {
                let backup = backupDir.appendingPathComponent("bak_\(i)_\(target.lastPathComponent)")
                if (try? fm.copyItem(at: target, to: backup)) != nil {
                    entries.append(UndoSnapshotEntry(targetURL: target, backupURL: backup, existedBefore: true))
                }
            } else {
                entries.append(UndoSnapshotEntry(targetURL: target, backupURL: nil, existedBefore: false))
            }
        }
        return entries
    }

    func setUndoEntries(_ entries: [UndoSnapshotEntry]) {
        lastUndoEntries = entries
        canUndo = !entries.isEmpty
    }

    func performUndo() {
        let entries = lastUndoEntries
        guard !entries.isEmpty else { return }
        lastUndoEntries = []
        canUndo = false

        Task {
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for entry in entries.reversed() {
                    if fm.fileExists(atPath: entry.targetURL.path) {
                        try? fm.removeItem(at: entry.targetURL)
                    }
                    if entry.existedBefore, let backup = entry.backupURL, fm.fileExists(atPath: backup.path) {
                        try? fm.createDirectory(at: entry.targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.copyItem(at: backup, to: entry.targetURL)
                    }
                }
            }.value

            changeLog.insert("↩️ Đã hoàn tác thay đổi gần nhất", at: 0)
            iconRefreshID = UUID()
            refreshWorkspace()
            Haptics.medium()
            showToast("Đã hoàn tác thay đổi gần nhất")
        }
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
                let (originalSize, sha) = await Task.detached(priority: .userInitiated) {
                    let needsScope = pickedURL.startAccessingSecurityScopedResource()
                    defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
                    let size = (try? FileManager.default.attributesOfItem(atPath: pickedURL.path)[.size] as? Int64) ?? 0
                    let hash = Self.computeShortSHA256Sync(url: pickedURL)
                    return (size, hash)
                }.value

                try await Task.detached(priority: .userInitiated) {
                    let needsScope = pickedURL.startAccessingSecurityScopedResource()
                    defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
                    try ZIPArchive.extract(ipaURL: pickedURL, to: destRoot) { prog, fileName in
                        Task { @MainActor [weak self] in
                            self?.busyProgress = prog
                            self?.busyDetail = fileName
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

                applySummary(analyzed)
                pinnedFilesForAI = []
                scannedBinaryURLs = []
                includeBinaryURLsInAI = false
                includeEntitlementsInAI = false
                lastUndoEntries = []
                canUndo = false
                iconRefreshID = UUID()
                changeLog = ["Đã mở gói: \(sourceName)"]
                isBusy = false
                Haptics.success()
                showToast("Đã mở \(analyzed.displayName)")
            } catch {
                isBusy = false
                Haptics.error()
                alertMessage = error.localizedDescription
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
                applySummary(analyzed)
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
            scannedBinaryURLs = urls
            isScanningBinary = false
            Haptics.light()
        }
    }

    nonisolated private static func computeShortSHA256Sync(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "N/A" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func analyzeWorkspace(root: URL, sourceName: String, originalSize: Int64, shaShort: String) throws -> IPAWorkspaceSummary {
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
        let iconData = iconURL.flatMap { try? Data(contentsOf: $0) }

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
            iconPath: iconURL,
            iconPNGData: iconData
        )
    }

    // MARK: - Mod Tools (All Disk I/O Off Main Thread)
    func injectDylibIntoBinary(dylibURL: URL, weakLoad: Bool) {
        guard let sum = summary else { return }
        let execURL = sum.appBundleURL.appendingPathComponent(sum.executableName)
        let sigURL = sum.appBundleURL.appendingPathComponent("_CodeSignature")
        let backupDir = undoBackupDir
        let appBundle = sum.appBundleURL
        let execName = sum.executableName

        isBusy = true
        busyTitle = "Đang inject \(dylibURL.lastPathComponent)"
        busyProgress = 0.5
        busyDetail = "Ghi lệnh LC_LOAD_DYLIB vào header Mach-O..."

        Task {
            do {
                let (entries, msg) = try await Task.detached(priority: .userInitiated) {
                    let snaps = Self.createUndoSnapshot(for: [execURL, sigURL], backupDir: backupDir)
                    let message = try MachODylibInjector.inject(dylibSourceURL: dylibURL, into: appBundle, executableName: execName, weakLoad: weakLoad)
                    return (snaps, message)
                }.value

                setUndoEntries(entries)
                isBusy = false
                changeLog.insert("✓ \(msg)", at: 0)
                refreshWorkspace()
                Haptics.medium()
                showToast(msg)
            } catch {
                isBusy = false
                Haptics.error()
                alertMessage = error.localizedDescription
            }
        }
    }

    func stripUnusedLocalizations() {
        guard let sum = summary else { return }
        let appBundle = sum.appBundleURL
        let backupDir = undoBackupDir

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (entries: [UndoSnapshotEntry], count: Int, freed: Int64) in
                let targets = LocalizationCleaner.removableURLs(in: appBundle)
                guard !targets.isEmpty else { return ([], 0, 0) }
                let snaps = Self.createUndoSnapshot(for: targets, backupDir: backupDir)
                var totalFreed: Int64 = 0
                var removedCount = 0
                for url in targets {
                    totalFreed += LocalizationCleaner.folderSize(url)
                    if (try? FileManager.default.removeItem(at: url)) != nil {
                        removedCount += 1
                    }
                }
                return (snaps, removedCount, totalFreed)
            }.value

            guard result.count > 0 else {
                showToast("Không có gói ngôn ngữ thừa (.lproj)")
                return
            }
            setUndoEntries(result.entries)
            let freedStr = ByteCountFormatter.string(fromByteCount: result.freed, countStyle: .file)
            changeLog.insert("✓ Đã xóa \(result.count) gói ngôn ngữ (giảm \(freedStr))", at: 0)
            refreshWorkspace()
            Haptics.medium()
            showToast("Đã dọn \(result.count) .lproj (tiết kiệm \(freedStr))")
        }
    }

    func applyManualEdits(name: String, bundleID: String, version: String, minOS: String, fileSharing: Bool, removeDeviceLimit: Bool) {
        guard let sum = summary else { return }
        let infoURL = sum.infoPlistURL
        let backupDir = undoBackupDir

        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    guard var dict = PlistHelper.readDict(url: infoURL) else {
                        throw ZIPArchiveError.ioFailed("Không đọc được Info.plist")
                    }
                    let snaps = Self.createUndoSnapshot(for: [infoURL], backupDir: backupDir)
                    dict["CFBundleDisplayName"] = name
                    dict["CFBundleName"] = name
                    dict["CFBundleIdentifier"] = bundleID
                    dict["CFBundleShortVersionString"] = version
                    if !minOS.isEmpty && minOS != "N/A" { dict["MinimumOSVersion"] = minOS }
                    dict["UIFileSharingEnabled"] = fileSharing
                    dict["LSSupportsOpeningDocumentsInPlace"] = fileSharing
                    if removeDeviceLimit { dict.removeValue(forKey: "UISupportedDevices") }
                    try PlistHelper.writeDict(dict, to: infoURL)
                    return snaps
                }.value

                setUndoEntries(entries)
                changeLog.insert("✓ Đã lưu Info.plist (\(name) • \(bundleID))", at: 0)
                refreshWorkspace()
                Haptics.medium()
                showToast("Đã lưu Info.plist")
            } catch {
                Haptics.error()
                alertMessage = "Lỗi lưu Info.plist: \(error.localizedDescription)"
            }
        }
    }

    func removeFolderFromApp(_ folderName: String) {
        guard let sum = summary else { return }
        let target = sum.appBundleURL.appendingPathComponent(folderName)
        let backupDir = undoBackupDir

        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) { () -> [UndoSnapshotEntry]? in
                    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
                    let snaps = Self.createUndoSnapshot(for: [target], backupDir: backupDir)
                    try FileManager.default.removeItem(at: target)
                    return snaps
                }.value

                if let entries {
                    setUndoEntries(entries)
                    changeLog.insert("✓ Đã xóa \(folderName)", at: 0)
                    refreshWorkspace()
                    Haptics.light()
                    showToast("Đã xóa \(folderName)")
                }
            } catch {
                alertMessage = "Không xóa được \(folderName): \(error.localizedDescription)"
            }
        }
    }

    func cleanAllForSideload() {
        guard let sum = summary else { return }
        let appBundle = sum.appBundleURL
        let infoURL = sum.infoPlistURL
        let backupDir = undoBackupDir

        Task {
            let (entries, note) = await Task.detached(priority: .userInitiated) { () -> ([UndoSnapshotEntry], String) in
                let fm = FileManager.default
                let targets = ["PlugIns", "Watch", "_CodeSignature"].map { appBundle.appendingPathComponent($0) } + [infoURL]
                let snaps = Self.createUndoSnapshot(for: targets, backupDir: backupDir)

                var removed: [String] = []
                for dir in ["PlugIns", "Watch", "_CodeSignature"] {
                    let target = appBundle.appendingPathComponent(dir)
                    if fm.fileExists(atPath: target.path) {
                        try? fm.removeItem(at: target)
                        removed.append(dir)
                    }
                }
                if var dict = PlistHelper.readDict(url: infoURL) {
                    dict["UIFileSharingEnabled"] = true
                    dict["LSSupportsOpeningDocumentsInPlace"] = true
                    dict.removeValue(forKey: "UISupportedDevices")
                    try? PlistHelper.writeDict(dict, to: infoURL)
                }
                let text = removed.isEmpty
                    ? "Đã bật FileSharing & gỡ giới hạn thiết bị"
                    : "Đã xóa \(removed.joined(separator: ", ")) & tối ưu Info.plist"
                return (snaps, text)
            }.value

            setUndoEntries(entries)
            changeLog.insert("✓ \(note)", at: 0)
            refreshWorkspace()
            Haptics.medium()
            showToast("Đã tối ưu Sideload xong")
        }
    }

    func applyCloneSchemeFix() {
        guard let sum = summary else { return }
        let infoURL = sum.infoPlistURL
        let fallbackBID = sum.bundleID
        let fallbackName = sum.displayName
        let backupDir = undoBackupDir

        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    guard var dict = PlistHelper.readDict(url: infoURL) else {
                        throw ZIPArchiveError.ioFailed("Không đọc được Info.plist")
                    }
                    let snaps = Self.createUndoSnapshot(for: [infoURL], backupDir: backupDir)
                    let currentBID = (dict["CFBundleIdentifier"] as? String) ?? fallbackBID
                    if !currentBID.hasSuffix(".clone") {
                        dict["CFBundleIdentifier"] = currentBID + ".clone"
                    }
                    let currentName = (dict["CFBundleDisplayName"] as? String) ?? fallbackName
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
                    try PlistHelper.writeDict(dict, to: infoURL)
                    return snaps
                }.value

                setUndoEntries(entries)
                changeLog.insert("✓ Đã nhân bản Bundle ID & URL Schemes", at: 0)
                refreshWorkspace()
                Haptics.medium()
                showToast("Đã nhân bản Bundle ID & URL Schemes")
            } catch {
                alertMessage = "Lỗi sửa Clone: \(error.localizedDescription)"
            }
        }
    }

    func applyBypassForceUpdate() {
        guard let sum = summary else { return }
        let infoURL = sum.infoPlistURL
        let backupDir = undoBackupDir

        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    guard var dict = PlistHelper.readDict(url: infoURL) else {
                        throw ZIPArchiveError.ioFailed("Không đọc được Info.plist")
                    }
                    let snaps = Self.createUndoSnapshot(for: [infoURL], backupDir: backupDir)
                    dict["CFBundleShortVersionString"] = "99.9.9"
                    dict["CFBundleVersion"] = "99999"
                    try PlistHelper.writeDict(dict, to: infoURL)
                    return snaps
                }.value

                setUndoEntries(entries)
                changeLog.insert("✓ Đã giả lập phiên bản 99.9.9 (99999)", at: 0)
                refreshWorkspace()
                Haptics.medium()
                showToast("Đã nâng phiên bản giả lập 99.9.9")
            } catch {
                alertMessage = "Lỗi sửa phiên bản: \(error.localizedDescription)"
            }
        }
    }

    func replaceAppIconsBatch(with imageURL: URL) {
        guard let sum = summary else { return }
        let appBundle = sum.appBundleURL

        Task {
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    try AppIconBatchReplacer.replaceAllIcons(in: appBundle, with: imageURL)
                }.value

                iconRefreshID = UUID()
                if count > 0 {
                    changeLog.insert("✓ Đã thay \(count) file AppIcon", at: 0)
                    refreshWorkspace()
                    Haptics.medium()
                    showToast("Đã thay \(count) ảnh AppIcon")
                } else {
                    alertMessage = "Không tìm thấy file AppIcon*.png trực tiếp trong .app (app có thể lưu icon trong Assets.car)."
                }
            } catch {
                alertMessage = error.localizedDescription
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
                        Task { @MainActor [weak self] in
                            self?.busyProgress = prog
                            self?.busyDetail = fileName
                        }
                    }
                }.value

                isBusy = false
                changeLog.insert("✓ Đã xuất: \(outURL.lastPathComponent)", at: 0)
                Haptics.success()
                NativeShareHelper.share(url: outURL)
            } catch {
                isBusy = false
                Haptics.error()
                alertMessage = "Lỗi đóng gói IPA: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Off-Main-Thread File Explorer Helpers
    nonisolated static func listDirectory(_ dirURL: URL, appBundleURL: URL) -> [IPAFileNode] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        let appRootPath = appBundleURL.standardizedFileURL.path

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

    func injectFiles(_ urls: [URL], into targetDir: URL, onComplete: (@MainActor () -> Void)? = nil) {
        Task {
            let (added, firstErr) = await Task.detached(priority: .userInitiated) { () -> (Int, String?) in
                let fm = FileManager.default
                var count = 0
                var errMsg: String?
                for src in urls {
                    let dest = targetDir.appendingPathComponent(src.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: src, to: dest)
                        count += 1
                    } catch {
                        errMsg = "Không chèn được \(src.lastPathComponent): \(error.localizedDescription)"
                    }
                }
                return (count, errMsg)
            }.value

            if let firstErr { alertMessage = firstErr }
            if added > 0 {
                changeLog.insert("✓ Đã chèn \(added) tệp vào \(targetDir.lastPathComponent)", at: 0)
                refreshWorkspace()
                Haptics.light()
                showToast("Đã chèn \(added) tệp")
            }
            onComplete?()
        }
    }

    func replaceFile(at targetURL: URL, with sourceURL: URL, relativePath: String, onComplete: (@MainActor () -> Void)? = nil) {
        let backupDir = undoBackupDir
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    let snaps = Self.createUndoSnapshot(for: [targetURL], backupDir: backupDir)
                    let data = try Data(contentsOf: sourceURL)
                    try data.write(to: targetURL, options: .atomic)
                    return snaps
                }.value

                setUndoEntries(entries)
                changeLog.insert("✓ Đã thay tệp: \(relativePath)", at: 0)
                iconRefreshID = UUID()
                refreshWorkspace()
                Haptics.medium()
                showToast("Đã thay tệp thành công")
                onComplete?()
            } catch {
                alertMessage = "Lỗi thay tệp: \(error.localizedDescription)"
            }
        }
    }

    func togglePinForAI(_ relativePath: String) {
        if let idx = pinnedFilesForAI.firstIndex(of: relativePath) {
            pinnedFilesForAI.remove(at: idx)
            Haptics.light()
            showToast("Đã bỏ ghim tệp khỏi AI")
        } else {
            pinnedFilesForAI.append(relativePath)
            Haptics.light()
            showToast("Đã ghim tệp cho AI")
        }
    }

    func clearWorkspace() {
        let ws = workspaceDir
        let ub = undoBackupDir
        UserDefaults.standard.removeObject(forKey: lastSourceNameKey)
        summary = nil
        appIconImage = nil
        pinnedFilesForAI = []
        scannedBinaryURLs = []
        includeBinaryURLsInAI = false
        includeEntitlementsInAI = false
        lastUndoEntries = []
        canUndo = false
        changeLog = []
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: ub)
        }
        Haptics.light()
        showToast("Đã đóng workspace")
    }

    // MARK: - Off-Main-Thread System Context Builder
    nonisolated static func buildSystemPrompt(
        summary: IPAWorkspaceSummary?,
        depth: AIContextDepth,
        pinnedFiles: [String],
        scannedBinaryURLs: [String],
        includeBinaryURLs: Bool,
        includeEntitlements: Bool
    ) -> String {
        let ipaContext = buildIPAContext(
            summary: summary,
            depth: depth,
            pinnedFiles: pinnedFiles,
            scannedBinaryURLs: scannedBinaryURLs,
            includeBinaryURLs: includeBinaryURLs,
            includeEntitlements: includeEntitlements
        )
        return """
        Bạn là chuyên gia iOS Reverse Engineering, IPA Modding và trợ lý phân tích tài liệu trong TueeHub IPA Studio v6. Trả lời tiếng Việt ngắn gọn, rõ ràng, kỹ thuật chuẩn xác.

        Dữ liệu IPA hiện tại:
        \(ipaContext)

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
        Nếu người dùng chỉ hỏi, phân tích tệp đính kèm hoặc chat bình thường, KHÔNG xuất khối ipa_patch.
        """
    }

    nonisolated private static func buildIPAContext(
        summary: IPAWorkspaceSummary?,
        depth: AIContextDepth,
        pinnedFiles: [String],
        scannedBinaryURLs: [String],
        includeBinaryURLs: Bool,
        includeEntitlements: Bool
    ) -> String {
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
            if (includeEntitlements || depth == .deep), let ent = m.entitlementsXML {
                lines.append("\n=== ENTITLEMENTS ===\n\(String(ent.prefix(3500)))")
            }
        }

        if includeBinaryURLs && !scannedBinaryURLs.isEmpty {
            lines.append("\n=== URL TRÍCH TỪ MACH-O BINARY (\(scannedBinaryURLs.count)) ===")
            lines.append(scannedBinaryURLs.prefix(60).joined(separator: "\n"))
        }

        if depth == .deep {
            let topNodes = listDirectory(sum.appBundleURL, appBundleURL: sum.appBundleURL).prefix(50)
            lines.append("\n=== TỆP GỐC .APP ===")
            for n in topNodes { lines.append("- \(n.name) (\(n.formattedSize))") }

            if let xml = PlistHelper.plistToXMLString(url: sum.infoPlistURL) {
                lines.append("\n=== INFO.PLIST (XML) ===")
                lines.append(String(xml.prefix(9000)))
            }
        }

        if !pinnedFiles.isEmpty {
            lines.append("\n=== TỆP GHIM ===")
            for rel in pinnedFiles.prefix(4) {
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
}

// MARK: - Store 3: AI Chat & Multi-Format Attachments
@Observable
@MainActor
final class AIChatStore {
    var messages: [AIMessage] = []
    var pendingAttachments: [ChatAttachment] = []
    var isAIThinking = false
    var isProcessingAttachments = false
    var attachmentProgress: Double = 0
    var attachmentStatus = ""
    var previewQuickLookItem: QuickLookItem?

    @ObservationIgnored private let workspace: IPAWorkspaceStore
    @ObservationIgnored private let config: APIConfigStore
    @ObservationIgnored private var aiStreamTask: Task<Void, Never>?
    @ObservationIgnored private var waitTimerTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentTask: Task<Void, Never>?

    init(workspace: IPAWorkspaceStore, config: APIConfigStore) {
        self.workspace = workspace
        self.config = config
        self.config.onCancelActiveChatRequest = { [weak self] in
            self?.stopAI(silent: true)
        }
        self.config.onNotifyToast = { [weak workspace] text, isError in
            workspace?.showToast(text, isError: isError)
        }
    }

    // MARK: - Attachments Import (FileImporter / Drag-Drop / OpenURL)
    func importAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        attachmentTask?.cancel()
        isProcessingAttachments = true
        attachmentProgress = 0.05
        attachmentStatus = "Đang đọc \(urls.count) tệp..."

        attachmentTask = Task { [weak self] in
            guard let self else { return }
            var addedCount = 0
            var lastError: String?

            for (idx, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let baseStep = Double(idx) / Double(urls.count)
                let stepSpan = 1.0 / Double(urls.count)

                do {
                    let attachment = try await AttachmentProcessor.process(sourceURL: url) { p, note in
                        Task { @MainActor [weak self] in
                            self?.attachmentProgress = baseStep + p * stepSpan
                            self?.attachmentStatus = note
                        }
                    }
                    self.pendingAttachments.append(attachment)
                    addedCount += 1
                } catch {
                    if !(error is CancellationError) {
                        lastError = error.localizedDescription
                    }
                }
            }

            self.isProcessingAttachments = false
            self.attachmentProgress = 0
            self.attachmentStatus = ""

            if let err = lastError {
                Haptics.error()
                self.workspace.alertMessage = err
            } else if addedCount > 0 {
                Haptics.light()
                self.workspace.showToast("Đã đính kèm \(addedCount) tệp")
            }
        }
    }

    func importDroppedImage(_ image: UIImage, suggestedName: String = "DroppedImage.jpg") {
        isProcessingAttachments = true
        attachmentProgress = 0.4
        attachmentStatus = "Đang xử lý ảnh..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let att = try await AttachmentProcessor.processImage(image, suggestedName: suggestedName)
                self.pendingAttachments.append(att)
                Haptics.light()
                self.workspace.showToast("Đã đính kèm ảnh")
            } catch {
                Haptics.error()
                self.workspace.alertMessage = error.localizedDescription
            }
            self.isProcessingAttachments = false
            self.attachmentProgress = 0
            self.attachmentStatus = ""
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        Haptics.light()
    }

    func openQuickLook(url: URL) {
        previewQuickLookItem = QuickLookItem(url: url)
    }

    // MARK: - Chat Sending with Task.cancel, Off-Main Context Build & Coalesced Streaming
    func sendMessage(_ prompt: String, overrideAttachments: [ChatAttachment]? = nil, appendUserBubble: Bool = true) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAttachments = overrideAttachments ?? pendingAttachments
        guard !trimmed.isEmpty || !activeAttachments.isEmpty else { return }

        // Luôn hủy request đang chạy trước khi bắt đầu request mới
        stopAI(silent: true)

        if overrideAttachments == nil {
            pendingAttachments = []
        }

        if appendUserBubble {
            messages.append(AIMessage(
                isUser: true,
                text: trimmed.isEmpty ? "Hãy phân tích các tệp đính kèm này." : trimmed,
                attachments: activeAttachments
            ))
        }

        let effectivePrompt = trimmed.isEmpty ? "Hãy phân tích các tệp đính kèm này." : trimmed

        // Chụp snapshot bất biến trước khi đẩy xuống nền
        let provider = config.selectedProvider
        let activeModel = config.activeModel
        let key = config.currentAPIKey
        let mode = config.geminiEndpointMode
        let endpoint = config.customEndpoint
        let depth = config.contextDepth
        let streaming = config.useStreaming

        let summarySnapshot = workspace.summary
        let pinnedSnapshot = workspace.pinnedFilesForAI
        let urlsSnapshot = workspace.scannedBinaryURLs
        let includeURLs = workspace.includeBinaryURLsInAI
        let includeEnt = workspace.includeEntitlementsInAI

        let historySnapshots: [(isUser: Bool, text: String, attachments: [ChatAttachment])] = messages
            .filter { $0.failedPrompt == nil }
            .suffix(8)
            .map { ($0.isUser, $0.text, $0.attachments) }

        let replyMsg = AIMessage(
            isUser: false,
            text: "",
            modelBadge: "\(provider.rawValue) • \(activeModel) • \(depth.rawValue)",
            statusNote: nil,
            isStreaming: true,
            waitingSeconds: 0
        )
        messages.append(replyMsg)
        isAIThinking = true
        Haptics.light()

        // Timer chỉ cập nhật trên đúng 1 bubble đang chờ phản hồi đầu tiên
        waitTimerTask?.cancel()
        waitTimerTask = Task { [weak replyMsg] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let msg = replyMsg, msg.isStreaming, msg.text.isEmpty else { break }
                msg.waitingSeconds += 1
            }
        }

        aiStreamTask = Task { [weak self, weak replyMsg] in
            guard let self, let replyMsg else { return }
            do {
                // Dựng system prompt + mã hóa ảnh base64 hoàn toàn ngoài Main Thread
                let (sysPrompt, turns) = await Task.detached(priority: .userInitiated) {
                    let promptStr = IPAWorkspaceStore.buildSystemPrompt(
                        summary: summarySnapshot,
                        depth: depth,
                        pinnedFiles: pinnedSnapshot,
                        scannedBinaryURLs: urlsSnapshot,
                        includeBinaryURLs: includeURLs,
                        includeEntitlements: includeEnt
                    )
                    let builtTurns: [AIChatTurn] = historySnapshots.map { item in
                        var fullText = item.text
                        var imagePayloads: [AIImagePayload] = []

                        for att in item.attachments {
                            if let imgData = att.imageJPEGData {
                                imagePayloads.append(AIImagePayload(
                                    mimeType: "image/jpeg",
                                    base64: imgData.base64EncodedString()
                                ))
                            }
                            if let extracted = att.extractedText, !extracted.isEmpty {
                                fullText += "\n\n[Tệp đính kèm: \(att.fileName) — \(att.summaryNote)]\n\(extracted)"
                            } else if att.kind != .image {
                                fullText += "\n\n[Tệp đính kèm: \(att.fileName) — \(att.summaryNote)]"
                            }
                        }
                        return AIChatTurn(isUser: item.isUser, text: fullText, images: imagePayloads)
                    }
                    return (promptStr, builtTurns)
                }.value

                try Task.checkCancellation()

                let fullReply = try await AIClient.send(
                    provider: provider,
                    model: activeModel,
                    apiKey: key,
                    geminiMode: mode,
                    customEndpoint: endpoint,
                    depth: depth,
                    useStreaming: streaming,
                    systemPrompt: sysPrompt,
                    history: turns,
                    onRetryStatus: { attempt, maxRetries in
                        await MainActor.run {
                            replyMsg.statusNote = "Mạng/máy chủ bận — đang thử lại (\(attempt)/\(maxRetries))..."
                        }
                    },
                    onBatchChunk: { batch in
                        await MainActor.run {
                            replyMsg.statusNote = nil
                            replyMsg.text += batch
                        }
                    }
                )

                self.waitTimerTask?.cancel()
                replyMsg.isStreaming = false
                replyMsg.statusNote = nil
                let finalRaw = fullReply.isEmpty ? replyMsg.text : fullReply
                let parsed = await Task.detached(priority: .userInitiated) {
                    AIPatchEngine.extractPatch(from: finalRaw)
                }.value

                replyMsg.text = parsed.cleanText.isEmpty ? (parsed.patch?.summary ?? "Đã hoàn tất.") : parsed.cleanText
                replyMsg.patch = parsed.patch
                self.isAIThinking = false
                Haptics.light()
            } catch {
                self.waitTimerTask?.cancel()
                replyMsg.isStreaming = false
                replyMsg.statusNote = nil
                if Task.isCancelled || error is CancellationError {
                    if replyMsg.text.isEmpty {
                        replyMsg.text = "Đã dừng."
                    }
                } else {
                    replyMsg.text = "❌ \(error.localizedDescription)"
                    replyMsg.failedPrompt = effectivePrompt
                    replyMsg.failedAttachments = activeAttachments
                    Haptics.error()
                }
                self.isAIThinking = false
            }
        }
    }

    func retryFailedMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              let prompt = messages[idx].failedPrompt else { return }
        let atts = messages[idx].failedAttachments
        messages.remove(at: idx)
        Haptics.light()
        sendMessage(prompt, overrideAttachments: atts, appendUserBubble: false)
    }

    func stopAI(silent: Bool = false) {
        aiStreamTask?.cancel()
        aiStreamTask = nil
        waitTimerTask?.cancel()
        waitTimerTask = nil
        if isAIThinking {
            isAIThinking = false
            if !silent { Haptics.medium() }
        }
        for msg in messages where msg.isStreaming {
            msg.isStreaming = false
            msg.statusNote = nil
            if msg.text.isEmpty {
                msg.text = "Đã dừng."
            }
        }
    }

    func clearChat() {
        stopAI(silent: true)
        messages.removeAll()
        pendingAttachments.removeAll()
        Haptics.light()
    }

    func applyAIPatch(messageID: UUID) {
        guard let sum = workspace.summary,
              let msg = messages.first(where: { $0.id == messageID }),
              let patch = msg.patch else { return }

        let actions = patch.actions
        let appBundle = sum.appBundleURL
        let wsRoot = sum.workspaceRoot
        let backupDir = workspace.undoBackupDir

        Task {
            let (entries, logs) = await Task.detached(priority: .userInitiated) {
                let targets = AIPatchEngine.targetURLs(for: actions, appBundleURL: appBundle, workspaceRoot: wsRoot)
                let snaps = IPAWorkspaceStore.createUndoSnapshot(for: targets, backupDir: backupDir)
                let outputLogs = AIPatchEngine.apply(actions: actions, appBundleURL: appBundle, workspaceRoot: wsRoot)
                return (snaps, outputLogs)
            }.value

            workspace.setUndoEntries(entries)
            msg.patchApplied = true
            for l in logs.reversed() { workspace.changeLog.insert(l, at: 0) }
            workspace.refreshWorkspace()
            Haptics.success()
            workspace.showToast("Đã áp dụng \(actions.count) thay đổi vào IPA")
        }
    }
}

// MARK: - Universal Drag & Drop Transferable (Hỗ trợ kéo thả mọi loại file từ app Tệp/Ảnh)
struct DroppedFileTransfer: Transferable, Sendable {
    let copiedURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let safeName = received.file.lastPathComponent
            let dest = AttachmentProcessor.cacheDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(safeName)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return DroppedFileTransfer(copiedURL: dest)
        }
    }
}

// MARK: - Tab 2: AI Studio (v6 Liquid Glass, Streaming mượt, Đa định dạng file & QuickLook)
struct AIStudioTab: View {
    let workspace: IPAWorkspaceStore
    let config: APIConfigStore
    let chat: AIChatStore

    @State private var showModelPicker = false
    @State private var showFileImporter = false
    @State private var isDropTargeted = false
    @Namespace private var glassNamespace

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack {
                    if chat.messages.isEmpty {
                        ContentUnavailableView {
                            Label("AI Studio v6", systemImage: "sparkles")
                        } description: {
                            Text(
                                workspace.summary == nil
                                ? "Đặt câu hỏi hoặc đính kèm ảnh, PDF, mã nguồn, DOCX, XLSX, PPTX, ZIP."
                                : "Đang gắn với \(workspace.summary?.displayName ?? "IPA"). Kéo thả hoặc bấm + để đính kèm tệp."
                            )
                        } actions: {
                            Button {
                                Haptics.light()
                                showFileImporter = true
                            } label: {
                                Label("Đính kèm tệp", systemImage: "paperclip")
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(chat.messages) { msg in
                                    AIMessageBubble(
                                        message: msg,
                                        canApplyPatch: workspace.summary != nil,
                                        onApply: { chat.applyAIPatch(messageID: msg.id) },
                                        onRetry: { chat.retryFailedMessage(id: msg.id) },
                                        onCopy: {
                                            UIPasteboard.general.string = msg.text
                                            Haptics.light()
                                            workspace.showToast("Đã sao chép")
                                        },
                                        onPreviewAttachment: { url in
                                            Haptics.light()
                                            chat.openQuickLook(url: url)
                                        }
                                    )
                                    .id(msg.id)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("chatBottomAnchor")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: chat.messages.count) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("chatBottomAnchor", anchor: .bottom)
                            }
                        }
                    }

                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                            .padding(12)
                            .overlay {
                                Label("Thả tệp vào đây để đính kèm", systemImage: "arrow.down.doc.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: .capsule)
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .dropDestination(for: DroppedFileTransfer.self) { items, _ in
                    let urls = items.map(\.copiedURL)
                    guard !urls.isEmpty else { return false }
                    chat.importAttachments(from: urls)
                    return true
                } isTargeted: { targeted in
                    withAnimation(.snappy(duration: 0.2)) {
                        isDropTargeted = targeted
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    AIStudioHeaderBar(
                        config: config,
                        glassNamespace: glassNamespace,
                        onOpenModelPicker: {
                            Haptics.light()
                            showModelPicker = true
                        }
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    AIStudioComposerBar(
                        chat: chat,
                        glassNamespace: glassNamespace,
                        onOpenFileImporter: {
                            Haptics.light()
                            showFileImporter = true
                        }
                    )
                }
            }
            .navigationTitle("AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !chat.messages.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            chat.clearChat()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Xóa lịch sử trò chuyện")
                    }
                }

                if workspace.canUndo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            workspace.performUndo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .accessibilityLabel("Hoàn tác")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        showModelPicker = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Chọn model AI")
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    chat.importAttachments(from: urls)
                case .failure(let error):
                    Haptics.error()
                    workspace.showToast("Không mở được tệp: \(error.localizedDescription)", isError: true)
                }
            }
            .sheet(isPresented: $showModelPicker) {
                AIModelSelectorSheet(config: config)
            }
            .sheet(item: Bindable(chat).previewQuickLookItem) { item in
                QuickLookPreviewSheet(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Top Header Bar (Tách View con để đổi chế độ/model mượt tức thì)
private struct AIStudioHeaderBar: View {
    let config: APIConfigStore
    let glassNamespace: Namespace.ID
    let onOpenModelPicker: () -> Void

    private var indicatorColor: Color {
        switch config.validationState(for: config.selectedProvider) {
        case .empty: return .orange
        case .scanning: return .blue
        case .valid: return .green
        case .invalid: return .red
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onOpenModelPicker) {
                    HStack(spacing: 6) {
                        if case .scanning = config.validationState(for: config.selectedProvider) {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Circle()
                                .fill(indicatorColor)
                                .frame(width: 8, height: 8)
                        }
                        Text(config.activeModel)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
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
                        let isSelected = config.contextDepth == depth
                        Button {
                            withAnimation(.snappy(duration: 0.26, extraBounce: 0.08)) {
                                config.switchDepth(depth)
                            }
                        } label: {
                            Text(depth.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.24))
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
}

// MARK: - Bottom Composer Bar (Tách state inputText để gõ phím không re-render list tin nhắn)
private struct AIStudioComposerBar: View {
    let chat: AIChatStore
    let glassNamespace: Namespace.ID
    let onOpenFileImporter: () -> Void

    @State private var inputText = ""

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if chat.isProcessingAttachments {
                HStack(spacing: 10) {
                    ProgressView(value: chat.attachmentProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text(chat.attachmentStatus)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !chat.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.pendingAttachments) { item in
                            AttachmentChipView(
                                attachment: item,
                                onTap: { chat.openQuickLook(url: item.localURL) },
                                onRemove: {
                                    withAnimation(.snappy) {
                                        chat.removePendingAttachment(id: item.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: onOpenFileImporter) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .glassEffectID("attachButton", in: glassNamespace)
                    .accessibilityLabel("Đính kèm tệp")

                    TextField("Nhập yêu cầu...", text: $inputText, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                        .glassEffectID("composerField", in: glassNamespace)

                    if chat.isAIThinking {
                        Button {
                            withAnimation(.snappy) {
                                chat.stopAI()
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
                                chat.sendMessage(text)
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!canSend || chat.isProcessingAttachments)
                        .glassEffectID("composerAction", in: glassNamespace)
                        .accessibilityLabel("Gửi yêu cầu")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .animation(.snappy, value: chat.isProcessingAttachments)
        .animation(.snappy, value: chat.pendingAttachments.count)
    }
}

// MARK: - Attachment Chip (Hỗ trợ nhấn để xem QuickLook)
private struct AttachmentChipView: View {
    let attachment: ChatAttachment
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil

    private let thumbShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 7) {
                    if let thumbData = attachment.imageThumbnailData, let uiImg = UIImage(data: thumbData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(thumbShape)
                    } else {
                        Image(systemName: attachment.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(attachment.tintColor)
                            .frame(width: 24, height: 24)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.fileName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: 145, alignment: .leading)
                        Text(attachment.formattedSize)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Gỡ tệp \(attachment.fileName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Message Bubble (Chỉ render lại chính bubble đang streaming nhờ @Observable)
struct AIMessageBubble: View {
    let message: AIMessage
    let canApplyPatch: Bool
    let onApply: () -> Void
    let onRetry: () -> Void
    let onCopy: () -> Void
    let onPreviewAttachment: (URL) -> Void

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

            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { att in
                            AttachmentChipView(
                                attachment: att,
                                onTap: { onPreviewAttachment(att.localURL) }
                            )
                        }
                    }
                }
            }

            Group {
                if message.text.isEmpty && message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let note = message.statusNote {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        } else {
                            Text(message.waitingSeconds > 0 ? "Đang kết nối... (\(message.waitingSeconds)s)" : "Đang kết nối...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
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
                message.isUser
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
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

// MARK: - Model & API Selector Sheet (Auto-Scan on Key Paste, Keychain & Fast/Deep Roles)
struct AIModelSelectorSheet: View {
    let config: APIConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingDepth: AIContextDepth = .fast
    @State private var customModelInput = ""
    @State private var modelSearchText = ""

    private var activeProvider: AIProvider {
        config.selectedProvider
    }

    private var validationState: KeyValidationState {
        config.validationState(for: activeProvider)
    }

    private var displayedModels: [String] {
        let all = config.availableModels(for: activeProvider)
        let q = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var selectedModelForEditingDepth: String {
        config.model(for: activeProvider, depth: editingDepth)
    }

    private var detectedProviderMismatch: AIProvider? {
        guard let detected = AIProvider.detectProvider(fromKey: config.currentAPIKey),
              detected != activeProvider else { return nil }
        return detected
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Nhà cung cấp AI API") {
                    ForEach(AIProvider.allCases) { provider in
                        Button {
                            config.switchProvider(provider)
                            modelSearchText = ""
                        } label: {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .foregroundStyle(.primary)
                                Spacer()
                                statusPill(for: provider)
                                if activeProvider == provider {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    SecureField(
                        activeProvider.keyPlaceholder,
                        text: Binding(
                            get: { config.apiKey(for: activeProvider) },
                            set: { config.updateAPIKey($0, for: activeProvider) }
                        )
                    )
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if let suggested = detectedProviderMismatch {
                        Button {
                            let pastedKey = config.currentAPIKey
                            config.updateAPIKey("", for: activeProvider)
                            config.switchProvider(suggested)
                            config.updateAPIKey(pastedKey, for: suggested)
                        } label: {
                            Label("Key này giống của \(suggested.rawValue) — Chuyển nhanh", systemImage: "arrow.triangle.swap")
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if activeProvider == .gemini {
                        Picker(
                            "Cổng kết nối",
                            selection: Binding(
                                get: { config.geminiEndpointMode },
                                set: { config.setGeminiEndpointMode($0) }
                            )
                        ) {
                            ForEach(GeminiEndpointMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                    }

                    if activeProvider == .custom {
                        TextField(
                            "https://.../v1/chat/completions",
                            text: Binding(
                                get: { config.customEndpoint },
                                set: { config.setCustomEndpoint($0) }
                            )
                        )
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    validationBanner

                    Button {
                        Haptics.light()
                        config.scanModels(for: activeProvider, userInitiated: true)
                    } label: {
                        HStack {
                            Label(isScanning ? "Đang quét model khả dụng..." : "Quét lại", systemImage: "arrow.clockwise")
                            Spacer()
                            if isScanning { ProgressView() }
                        }
                    }
                    .disabled(isScanning || !config.hasKey(for: activeProvider))
                } header: {
                    Text("2. API Key (Lưu an toàn trong Keychain)")
                } footer: {
                    Text("Khi dán API Key, app tự kiểm tra key, liệt kê model thực sự dùng được và tự chọn cặp model Nhanh / Sâu.")
                }

                Section("3. Model cho chế độ Nhanh & Sâu (\(displayedModels.count))") {
                    Picker("Đang gán cho", selection: $editingDepth) {
                        Text("Nhanh (\(config.model(for: activeProvider, depth: .fast)))")
                            .tag(AIContextDepth.fast)
                        Text("Sâu (\(config.model(for: activeProvider, depth: .deep)))")
                            .tag(AIContextDepth.deep)
                    }
                    .pickerStyle(.segmented)

                    if config.availableModels(for: activeProvider).count > 8 {
                        TextField("Lọc tên model...", text: $modelSearchText)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    ForEach(displayedModels, id: \.self) { m in
                        Button {
                            config.setModel(m, for: activeProvider, depth: editingDepth)
                        } label: {
                            HStack {
                                Text(m)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if config.model(for: activeProvider, depth: .fast) == m {
                                    Text("Nhanh")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.16), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                                if config.model(for: activeProvider, depth: .deep) == m {
                                    Text("Sâu")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.16), in: Capsule())
                                        .foregroundStyle(.purple)
                                }
                                if selectedModelForEditingDepth == m {
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
                                config.setModel(clean, for: activeProvider, depth: editingDepth)
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
            .onAppear {
                editingDepth = config.contextDepth
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = validationState { return true }
        return false
    }

    @ViewBuilder
    private var validationBanner: some View {
        switch validationState {
        case .empty:
            EmptyView()
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Đang xác thực key & quét model khả dụng...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .valid(let count, let note):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(note == nil ? "Key hợp lệ • \(count) model khả dụng" : "Key hợp lệ (\(note!)) • \(count) model")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        case .invalid(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func statusPill(for provider: AIProvider) -> some View {
        switch config.validationState(for: provider) {
        case .empty:
            EmptyView()
        case .scanning:
            ProgressView().controlSize(.mini)
        case .valid(let count, _):
            Text("\(count) model")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .invalid:
            Text("Lỗi key")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Tab 1: IPA Overview, Mach-O Inspector & Mod Tools
struct IPAOverviewTab: View {
    let store: IPAWorkspaceStore

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
                        Section {
                            VStack(spacing: 16) {
                                HStack(spacing: 14) {
                                    if let img = store.appIconImage {
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
                                    Haptics.medium()
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

                        Section("Công cụ Mod") {
                            Button {
                                Haptics.light()
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
                                Haptics.light()
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
                            Haptics.light()
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
                        Haptics.light()
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
    let store: IPAWorkspaceStore
    let xml: String?

    var body: some View {
        Group {
            if let xml {
                List {
                    Section {
                        Toggle("Gửi Entitlements này cho AI", isOn: Bindable(store).includeEntitlementsInAI)
                        Button {
                            UIPasteboard.general.string = xml
                            Haptics.light()
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
    let store: IPAWorkspaceStore
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
                    Toggle("Gửi danh sách URL này cho AI", isOn: Bindable(store).includeBinaryURLsInAI)
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
                                    Haptics.light()
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

// MARK: - Tab 3: Deep IPA File Explorer (Hoàn toàn bất đồng bộ ngoài Main Thread + QuickLook)
struct FileExplorerTab: View {
    let store: IPAWorkspaceStore

    var body: some View {
        NavigationStack {
            if let sum = store.summary {
                FolderBrowserView(
                    folderURL: sum.appBundleURL,
                    appBundleURL: sum.appBundleURL,
                    title: sum.appBundleURL.lastPathComponent,
                    isRoot: true,
                    store: store
                )
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
    let appBundleURL: URL
    let title: String
    var isRoot: Bool = false
    let store: IPAWorkspaceStore

    @State private var searchText = ""
    @State private var items: [IPAFileNode] = []
    @State private var deepResults: [IPAFileNode] = []
    @State private var isLoading = false
    @State private var refreshTick = 0
    @State private var searchTask: Task<Void, Never>?

    var displayedItems: [IPAFileNode] {
        if !searchText.isEmpty && isRoot {
            return deepResults
        }
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if isLoading && displayedItems.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Đang đọc thư mục...")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(displayedItems) { node in
                    if node.isDirectory {
                        NavigationLink {
                            FolderBrowserView(
                                folderURL: node.url,
                                appBundleURL: appBundleURL,
                                title: node.name,
                                isRoot: false,
                                store: store
                            )
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
                    let targets = offsets.map { displayedItems[$0].url }
                    Task {
                        await Task.detached(priority: .userInitiated) {
                            for url in targets {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }.value
                        refreshTick += 1
                        store.refreshWorkspace()
                        Haptics.light()
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: isRoot ? "Tìm toàn bộ tệp trong .app..." : "Lọc tệp trong thư mục...")
        .task(id: refreshTick) {
            isLoading = true
            let dir = folderURL
            let bundle = appBundleURL
            let loaded = await Task.detached(priority: .userInitiated) {
                IPAWorkspaceStore.listDirectory(dir, appBundleURL: bundle)
            }.value
            items = loaded
            isLoading = false
        }
        .onChange(of: searchText) {
            guard isRoot else { return }
            searchTask?.cancel()
            let query = searchText
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                deepResults = []
                return
            }
            let rootURL = folderURL
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                let hits = await Task.detached(priority: .userInitiated) {
                    IPAWorkspaceStore.searchAllFiles(in: rootURL, query: query)
                }.value
                if !Task.isCancelled && searchText == query {
                    deepResults = hits
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    NativeFilePicker.shared.pick(allowsMultiple: true) { urls in
                        store.injectFiles(urls, into: folderURL) {
                            refreshTick += 1
                        }
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
    let store: IPAWorkspaceStore

    @State private var textContent = ""
    @State private var hexPreview = ""
    @State private var previewImage: UIImage?
    @State private var isPlist = false
    @State private var isLoading = true
    @State private var quickLookItem: QuickLookItem?

    private let previewShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var isPinned: Bool {
        store.pinnedFilesForAI.contains(node.relativePath)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Đang đọc \(node.name)...")
            } else if node.isTextEditable {
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
                            Haptics.light()
                            NativeFilePicker.shared.pick(types: [.image, .png, .jpeg]) { urls in
                                if let picked = urls.first {
                                    store.replaceFile(at: node.url, with: picked, relativePath: node.relativePath) {
                                        Task { await reloadPreviewImage() }
                                    }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    quickLookItem = QuickLookItem(url: node.url)
                } label: {
                    Image(systemName: "eye")
                }
                .accessibilityLabel("Xem nhanh QuickLook")
            }

            if node.isTextEditable {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)

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
        .sheet(item: $quickLookItem) { item in
            QuickLookPreviewSheet(url: item.url)
                .ignoresSafeArea()
        }
        .task {
            await loadFileAsync()
        }
    }

    private func reloadPreviewImage() async {
        let url = node.url
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        previewImage = data.flatMap { UIImage(data: $0) }
    }

    private func loadFileAsync() async {
        isLoading = true
        let fileURL = node.url
        let editable = node.isTextEditable
        let isImg = node.isImageFile
        let plistFlag = fileURL.pathExtension.lowercased() == "plist"
        isPlist = plistFlag

        if editable {
            let content = await Task.detached(priority: .userInitiated) { () -> String in
                if plistFlag, let xml = PlistHelper.plistToXMLString(url: fileURL) {
                    return xml
                } else if let str = try? String(contentsOf: fileURL, encoding: .utf8) {
                    return str
                } else {
                    return "// Không đọc được dưới dạng UTF-8"
                }
            }.value
            textContent = content
        } else if isImg {
            await reloadPreviewImage()
        } else {
            let hex = await Task.detached(priority: .userInitiated) { () -> String in
                guard let handle = try? FileHandle(forReadingFrom: fileURL),
                      let sample = try? handle.read(upToCount: 2048) else { return "" }
                try? handle.close()
                let bytes = [UInt8](sample)
                var lines: [String] = []
                for offset in stride(from: 0, to: bytes.count, by: 16) {
                    let end = min(offset + 16, bytes.count)
                    let slice = bytes[offset..<end]
                    let hexRow = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let paddedHex = hexRow.padding(toLength: 47, withPad: " ", startingAt: 0)
                    let ascii = slice.map { ($0 >= 32 && $0 <= 126) ? String(UnicodeScalar($0)) : "." }.joined()
                    lines.append("\(String(format: "%04X", offset)): \(paddedHex)  \(ascii)")
                }
                return lines.joined(separator: "\n")
            }.value
            hexPreview = hex
        }
        isLoading = false
    }

    private func saveFile() {
        let fileURL = node.url
        let relPath = node.relativePath
        let name = node.name
        let content = textContent
        let plistFlag = isPlist

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if plistFlag {
                        try PlistHelper.validateAndSaveXMLPlist(content, to: fileURL)
                    } else {
                        try Data(content.utf8).write(to: fileURL, options: .atomic)
                    }
                }.value
                store.changeLog.insert("✓ Đã sửa thủ công: \(relPath)", at: 0)
                store.refreshWorkspace()
                Haptics.success()
                store.showToast("Đã lưu \(name)")
            } catch {
                Haptics.error()
                store.showToast("Lỗi lưu tệp: \(error.localizedDescription)", isError: true)
            }
        }
    }
}

// MARK: - Tab 4: AI API Settings (Keychain + Auto-Scan + Fast/Deep Summary)
struct APISettingsTab: View {
    let workspace: IPAWorkspaceStore
    let config: APIConfigStore

    var body: some View {
        NavigationStack {
            Form {
                Section("AI đang hoạt động") {
                    LabeledContent("Nhà cung cấp", value: config.selectedProvider.rawValue)
                    LabeledContent("Model Nhanh", value: config.model(for: config.selectedProvider, depth: .fast))
                    LabeledContent("Model Sâu", value: config.model(for: config.selectedProvider, depth: .deep))

                    Picker(
                        "Chế độ hiện tại",
                        selection: Binding(
                            get: { config.contextDepth },
                            set: { config.switchDepth($0) }
                        )
                    ) {
                        ForEach(AIContextDepth.allCases) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }

                    Toggle(
                        "Streaming hiện chữ trực tiếp",
                        isOn: Binding(
                            get: { config.useStreaming },
                            set: { config.setUseStreaming($0) }
                        )
                    )

                    if config.selectedProvider == .gemini {
                        Picker(
                            "Cổng Gemini",
                            selection: Binding(
                                get: { config.geminiEndpointMode },
                                set: { config.setGeminiEndpointMode($0) }
                            )
                        ) {
                            ForEach(GeminiEndpointMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                    }
                }

                Section {
                    ForEach(AIProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(provider.rawValue, systemImage: provider.icon)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                providerStatusView(for: provider)
                            }

                            HStack(spacing: 8) {
                                SecureField(
                                    provider.keyPlaceholder,
                                    text: Binding(
                                        get: { config.apiKey(for: provider) },
                                        set: { config.updateAPIKey($0, for: provider) }
                                    )
                                )
                                .font(.caption.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                if config.hasKey(for: provider) {
                                    Button {
                                        Haptics.light()
                                        config.scanModels(for: provider, userInitiated: true)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.mini)
                                    .accessibilityLabel("Quét lại model cho \(provider.rawValue)")
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Kho API Key (Keychain mã hóa)")
                } footer: {
                    Text("Tất cả API Key được lưu an toàn bằng iOS Keychain, không lưu plain text và không ghi log. Dán key xong app tự quét model.")
                }

                Section("Custom OpenAI-Compatible Endpoint") {
                    TextField(
                        "https://.../v1/chat/completions",
                        text: Binding(
                            get: { config.customEndpoint },
                            set: { config.setCustomEndpoint($0) }
                        )
                    )
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section("Đóng gói IPA") {
                    Toggle(
                        "Nén ZLIB khi xuất IPA",
                        isOn: Binding(
                            get: { workspace.compressOnExport },
                            set: { workspace.setCompressOnExport($0) }
                        )
                    )
                    Button("Xóa thư mục giải nén tạm", role: .destructive) {
                        workspace.clearWorkspace()
                    }
                }
            }
            .navigationTitle("AI API & Cài đặt")
        }
    }

    @ViewBuilder
    private func providerStatusView(for provider: AIProvider) -> some View {
        switch config.validationState(for: provider) {
        case .empty:
            if config.selectedProvider == provider {
                Text("Đang chọn")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        case .scanning:
            ProgressView().controlSize(.mini)
        case .valid(let count, _):
            Text("\(count) model")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .invalid:
            Text("Key lỗi")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Root ContentView (v6 — Pure iOS 26+ Liquid Glass TabView & @Observable Stores)
struct ContentView: View {
    @State private var workspaceStore: IPAWorkspaceStore
    @State private var apiConfigStore: APIConfigStore
    @State private var chatStore: AIChatStore
    @State private var selectedTab: Int = 0

    init() {
        let ws = IPAWorkspaceStore()
        let api = APIConfigStore()
        let chat = AIChatStore(workspace: ws, config: api)
        _workspaceStore = State(initialValue: ws)
        _apiConfigStore = State(initialValue: api)
        _chatStore = State(initialValue: chat)
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("IPA", systemImage: "shippingbox.fill", value: 0) {
                    IPAOverviewTab(store: workspaceStore)
                }

                Tab("AI Studio", systemImage: "sparkles", value: 1) {
                    AIStudioTab(
                        workspace: workspaceStore,
                        config: apiConfigStore,
                        chat: chatStore
                    )
                }

                Tab("Tệp IPA", systemImage: "folder.fill", value: 2) {
                    FileExplorerTab(store: workspaceStore)
                }

                Tab("AI API", systemImage: "cpu", value: 3) {
                    APISettingsTab(
                        workspace: workspaceStore,
                        config: apiConfigStore
                    )
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)

            if workspaceStore.isBusy {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView(value: workspaceStore.busyProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                        Text(workspaceStore.busyTitle)
                            .font(.headline)
                        Text(workspaceStore.busyDetail)
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
            if let toast = workspaceStore.toast {
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
        .animation(.snappy, value: workspaceStore.isBusy)
        .animation(.snappy, value: workspaceStore.toast)
        .alert("TueeHub IPA Studio", isPresented: Binding(
            get: { workspaceStore.alertMessage != nil },
            set: { if !$0 { workspaceStore.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceStore.alertMessage ?? "")
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "ipa" {
                selectedTab = 0
                workspaceStore.importIPA(from: url)
            } else {
                selectedTab = 1
                chatStore.importAttachments(from: [url])
            }
        }
    }
}
