import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Security
import CryptoKit

// MARK: - Native UIKit Document Picker (Fix triệt để lỗi đơ & xám file)
@MainActor
final class NativeFilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeFilePicker()
    private var completion: (([URL]) -> Void)?

    nonisolated static var allSupportedTypes: [UTType] {
        var types: [UTType] = [.item, .data, .content, .archive, .zip, .pkcs12, .json]
        let customExts = ["ipa", "p12", "mobileprovision", "dylib", "deb", "json"]
        for ext in customExts {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }

    func pick(
        types: [UTType] = NativeFilePicker.allSupportedTypes,
        allowsMultiple: Bool = false,
        completion: @escaping ([URL]) -> Void
    ) {
        guard let presenter = Self.topViewController() else {
            completion([])
            return
        }
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
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

    private static func topViewController() -> UIViewController? {
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

// MARK: - iOS 26/27 Adaptive Modifiers
extension View {
    @ViewBuilder
    func applyLiquidTabBehavior() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Appearance & Preferences
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system = "Hệ thống"
    case dark = "Tối"
    case light = "Sáng"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum CardStyleMode: String, CaseIterable, Identifiable {
    case tinted = "Màu trầm (LiveContainer)"
    case native = "Xám gốc Apple"

    var id: String { rawValue }
}

enum MainTab: Hashable {
    case apps, sources, library, settings, search
}

// MARK: - AltSource Models
struct AltSource: Codable {
    let name: String?
    let identifier: String?
    let apps: [AltApp]?
}

struct AltAppVersion: Codable {
    let version: String?
    let downloadURL: String?
    let size: Int64?
}

struct AltApp: Codable, Identifiable {
    var id: String { "\(bundleIdentifier ?? name)|\(name)|\(sourceName ?? "local")" }
    let name: String
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let localizedDescription: String?
    let iconURL: String?
    let downloadURL: String?
    let version: String?
    let size: Int64?
    let versions: [AltAppVersion]?
    var sourceName: String? = nil
    var manualCategory: String? = nil

    var safeBundleID: String {
        bundleIdentifier ?? "com.tueehub.\(name.lowercased().replacingOccurrences(of: " ", with: ""))"
    }

    var bestDownloadURL: String {
        versions?.first?.downloadURL ?? downloadURL ?? ""
    }

    var isDirectIPA: Bool {
        let lower = bestDownloadURL.lowercased()
        return lower.hasSuffix(".ipa") || lower.contains(".ipa?")
    }

    var bestVersion: String {
        versions?.first?.version ?? version ?? "1.0"
    }

    var rawSizeBytes: Int64 {
        versions?.first?.size ?? size ?? 0
    }

    var formattedSize: String {
        let bytes = rawSizeBytes
        if bytes <= 0 { return "IPA" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var resolvedCategory: AppCategory {
        if let manual = manualCategory, let cat = AppCategory(rawValue: manual) {
            return cat
        }
        let text = "\(name) \(subtitle ?? "") \(localizedDescription ?? "") \(safeBundleID)".lowercased()
        if text.contains("emu") || text.contains("dolphin") || text.contains("delta") || text.contains("ppsspp") || text.contains("retro") || text.contains("nintendo") {
            return .emu
        }
        if text.contains("sideload") || text.contains("feather") || text.contains("sidestore") || text.contains("altstore") || text.contains("livecontainer") || text.contains("sign") {
            return .sideload
        }
        if text.contains("port") || text.contains("minecraft") || text.contains("pojav") || text.contains("openttd") || text.contains("doom") {
            return .ports
        }
        if text.contains("game") || text.contains("arcade") || text.contains("rpg") {
            return .games
        }
        return .tools
    }

    var cardTint: Color {
        let hash = abs(name.hashValue)
        let palette: [Color] = [
            Color(red: 0.24, green: 0.21, blue: 0.19),
            Color(red: 0.08, green: 0.24, blue: 0.14),
            Color(red: 0.30, green: 0.18, blue: 0.11),
            Color(red: 0.12, green: 0.28, blue: 0.18),
            Color(red: 0.21, green: 0.19, blue: 0.34),
            Color(red: 0.14, green: 0.20, blue: 0.28)
        ]
        return palette[hash % palette.count]
    }

    var buttonTint: Color {
        let hash = abs(name.hashValue)
        let palette: [Color] = [
            Color(red: 0.45, green: 0.41, blue: 0.38),
            Color(red: 0.15, green: 0.46, blue: 0.25),
            Color(red: 0.62, green: 0.40, blue: 0.28),
            Color(red: 0.22, green: 0.66, blue: 0.36),
            Color(red: 0.44, green: 0.40, blue: 0.72),
            Color(red: 0.24, green: 0.45, blue: 0.68)
        ]
        return palette[hash % palette.count]
    }

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription
        case iconURL, downloadURL, version, size, versions
    }
}

enum AppCategory: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case emu = "EMU"
    case ports = "Ports"
    case sideload = "Sideloading"
    case games = "Games"
    case tools = "Tools"

    var id: String { rawValue }
}

enum AppSortOrder: String, CaseIterable, Identifiable {
    case defaultOrder = "Mặc định"
    case nameAZ = "Tên A → Z"
    case sizeDesc = "Dung lượng lớn"

    var id: String { rawValue }
}

// MARK: - Certificate, IPA & Tweak Models
enum P12VerifyStatus: String, Codable {
    case verified = "P12 hợp lệ"
    case wrongPassword = "Sai mật khẩu P12"
    case invalidFile = "File P12 lỗi"
    case missing = "Chưa có P12"
}

struct CertificateRecord: Codable, Identifiable {
    let id: UUID
    var label: String
    var p12FileName: String?
    var provisionFileName: String?
    var password: String
    var teamName: String
    var teamID: String
    var p12SubjectName: String?
    var p12Status: P12VerifyStatus
    var expirationDate: Date?
    var isEnterprise: Bool
    var deviceCount: Int
    var addedAt: Date

    var isExpired: Bool {
        guard let exp = expirationDate else { return false }
        return exp < Date()
    }

    var daysRemaining: Int? {
        guard let exp = expirationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: exp).day
    }

    var statusText: String {
        if p12FileName == nil || provisionFileName == nil { return "Thiếu file" }
        if p12Status == .wrongPassword { return "Sai mật khẩu" }
        if p12Status == .invalidFile { return "P12 lỗi" }
        if isExpired { return "Hết hạn" }
        if let days = daysRemaining { return "Còn \(days) ngày" }
        return "Hoạt động"
    }

    var isReady: Bool {
        p12FileName != nil && provisionFileName != nil && p12Status == .verified && !isExpired
    }
}

struct LocalIPAItem: Codable, Identifiable {
    let id: UUID
    var appName: String
    var fileName: String
    var version: String
    var bundleID: String
    var sizeBytes: Int64
    var addedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct LocalTweakItem: Codable, Identifiable {
    let id: UUID
    var name: String
    var fileName: String
    var fileExtension: String
    var sizeBytes: Int64
    var addedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct ActiveDownloadTask: Identifiable {
    let id: String
    let appName: String
    let version: String
    let bundleID: String
    var progress: Double
    var writtenBytes: Int64
    var totalBytes: Int64

    var formattedProgress: String {
        let written = ByteCountFormatter.string(fromByteCount: writtenBytes, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(written) / \(total)"
        }
        return written
    }
}

// MARK: - Cryptographic & Profile Parsers
enum P12Verifier {
    static func verify(fileURL: URL, password: String) -> (status: P12VerifyStatus, subject: String?) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return (.invalidFile, nil)
        }
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        if status == errSecAuthFailed {
            return (.wrongPassword, nil)
        }
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first else {
            return (.invalidFile, nil)
        }

        var subject: String?
        if let rawIdentity = first[kSecImportItemIdentity as String],
           CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() {
            let identity = rawIdentity as! SecIdentity
            var cert: SecCertificate?
            if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert = cert {
                subject = SecCertificateCopySubjectSummary(cert) as String?
            }
        }
        return (.verified, subject)
    }
}

enum MobileProvisionParser {
    struct ParsedInfo {
        var name: String
        var teamName: String
        var teamID: String
        var expirationDate: Date?
        var isEnterprise: Bool
        var deviceCount: Int
    }

    static func parse(fileURL: URL) -> ParsedInfo? {
        guard let data = try? Data(contentsOf: fileURL),
              let startRange = data.range(of: Data("<plist".utf8)),
              let endRange = data.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<data.endIndex) else {
            return nil
        }

        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return ParsedInfo(
            name: (plist["Name"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent,
            teamName: (plist["TeamName"] as? String) ?? "Unknown Team",
            teamID: ((plist["TeamIdentifier"] as? [String])?.first) ?? "N/A",
            expirationDate: plist["ExpirationDate"] as? Date,
            isEnterprise: (plist["ProvisionsAllDevices"] as? Bool) ?? false,
            deviceCount: ((plist["ProvisionedDevices"] as? [String]) ?? []).count
        )
    }
}

enum FileHasher {
    static func sha256(url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "Không đọc được" }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

// MARK: - Download Engine
final class DownloadSessionBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((String, Int64, Int64) -> Void)?
    var onFinished: ((String, URL) -> Void)?
    var onError: ((String, String) -> Void)?

    private let ipaDirectory: URL

    init(ipaDirectory: URL) {
        self.ipaDirectory = ipaDirectory
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(id, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let safeFileName = "app_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(5)).ipa"
        let destination = ipaDirectory.appendingPathComponent(safeFileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?(id, destination)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(id, "Không lưu được file IPA: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?(id, error.localizedDescription)
        }
    }
}

// MARK: - Central Store Manager
@MainActor
final class IPAStoreManager: ObservableObject {
    @Published var apps: [AltApp] = []
    @Published var sourceURLs: [String] = []
    @Published var repoAppCounts: [String: Int] = [:]
    @Published var favoriteIDs: Set<String> = []
    @Published var certificates: [CertificateRecord] = []
    @Published var selectedCertID: UUID?
    @Published var localIPAs: [LocalIPAItem] = []
    @Published var localTweaks: [LocalTweakItem] = []
    @Published var activeDownloads: [String: ActiveDownloadTask] = [:]
    @Published var isLoading = false
    @Published var alertMessage: String?

    @Published var appearance: AppAppearanceMode = .dark {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey) }
    }
    @Published var cardStyle: CardStyleMode = .tinted {
        didSet { UserDefaults.standard.set(cardStyle.rawValue, forKey: cardStyleKey) }
    }
    @Published var hapticsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: hapticsKey) }
    }

    private let sourcesKey = "TueeHub_v3_Sources"
    private let favoritesKey = "TueeHub_v3_Favorites"
    private let certsKey = "TueeHub_v3_Certs"
    private let selectedCertKey = "TueeHub_v3_SelectedCert"
    private let localIPAsKey = "TueeHub_v3_LocalIPAs"
    private let localTweaksKey = "TueeHub_v3_LocalTweaks"
    private let appearanceKey = "TueeHub_v3_Appearance"
    private let cardStyleKey = "TueeHub_v3_CardStyle"
    private let hapticsKey = "TueeHub_v3_Haptics"

    private var downloadBridge: DownloadSessionBridge!
    private var downloadSession: URLSession!
    private var runningTasks: [String: URLSessionDownloadTask] = [:]

    var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var certsDir: URL {
        let dir = documentsDir.appendingPathComponent("Certs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var ipasDir: URL {
        let dir = documentsDir.appendingPathComponent("IPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var tweaksDir: URL {
        let dir = documentsDir.appendingPathComponent("Tweaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var activeCertificate: CertificateRecord? {
        if let id = selectedCertID, let found = certificates.first(where: { $0.id == id }) {
            return found
        }
        return certificates.first(where: { $0.isReady }) ?? certificates.first
    }

    var totalStorageBytes: Int64 {
        let ipaSum = localIPAs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let tweakSum = localTweaks.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ipaSum + tweakSum
    }

    let curatedGitHubApps: [AltApp] = [
        AltApp(
            name: "PojavLauncher",
            bundleIdentifier: "net.kdt.pojavlaunch",
            developerName: "PojavLauncherTeam",
            subtitle: "Minecraft Java Edition PC Port cho iOS",
            localizedDescription: "Chạy thẳng Minecraft Java Edition mã nguồn mở trên iPhone, hỗ trợ Fabric, Forge và shader.",
            iconURL: "https://raw.githubusercontent.com/PojavLauncherTeam/PojavLauncher_iOS/main/Natives/Assets.xcassets/AppIcon-Default.appiconset/AppIcon-Default-1024.png",
            downloadURL: "https://github.com/PojavLauncherTeam/PojavLauncher_iOS/releases",
            version: "2.2",
            size: 118_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.ports.rawValue
        ),
        AltApp(
            name: "DolphiniOS",
            bundleIdentifier: "me.oatmealdome.dolphinios",
            developerName: "OatmealDome",
            subtitle: "Giả lập GameCube & Wii 60 FPS",
            localizedDescription: "Trình giả lập GameCube và Wii mã nguồn mở mượt nhất cho iOS, hỗ trợ tay cầm Bluetooth.",
            iconURL: "https://raw.githubusercontent.com/OatmealDome/dolphin-ios/master/Source/iOS/App/DolphiniOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            downloadURL: "https://github.com/OatmealDome/dolphin-ios/releases",
            version: "4.0",
            size: 46_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.emu.rawValue
        ),
        AltApp(
            name: "Delta Emulator",
            bundleIdentifier: "com.rileytestut.Delta",
            developerName: "Riley Testut",
            subtitle: "NES, SNES, N64, GBC, GBA, DS",
            localizedDescription: "Giả lập đa hệ máy Nintendo mã nguồn mở, hỗ trợ cheat code và đồng bộ save.",
            iconURL: "https://raw.githubusercontent.com/rileytestut/Delta/main/Delta/Assets.xcassets/AppIcon.appiconset/Icon-1024.png",
            downloadURL: "https://github.com/rileytestut/Delta/releases",
            version: "1.6",
            size: 38_500_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.emu.rawValue
        ),
        AltApp(
            name: "PPSSPP",
            bundleIdentifier: "org.ppsspp.ppsspp",
            developerName: "hrydgard",
            subtitle: "Giả lập PSP độ phân giải HD",
            localizedDescription: "Chơi game PSP mượt mà với đồ họa nâng cấp và tùy biến phím bấm.",
            iconURL: "https://raw.githubusercontent.com/hrydgard/ppsspp/master/icons/icon-512.png",
            downloadURL: "https://github.com/hrydgard/ppsspp/releases",
            version: "1.18",
            size: 31_200_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.emu.rawValue
        ),
        AltApp(
            name: "UTM",
            bundleIdentifier: "com.utmapp.UTM",
            developerName: "utmapp",
            subtitle: "Máy ảo Windows & Linux trên iOS",
            localizedDescription: "Chạy hệ điều hành Windows, Ubuntu, Arch Linux trực tiếp trên iPhone bằng QEMU.",
            iconURL: "https://raw.githubusercontent.com/utmapp/UTM/main/Platform/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon1024x1024.png",
            downloadURL: "https://github.com/utmapp/UTM/releases",
            version: "4.6",
            size: 165_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.tools.rawValue
        ),
        AltApp(
            name: "Feather",
            bundleIdentifier: "kh.crysalis.feather",
            developerName: "khcrysalis",
            subtitle: "Trình ký IPA & inject dylib trên máy",
            localizedDescription: "Ứng dụng ký file IPA mã nguồn mở, hỗ trợ quản lý nguồn AltSource.",
            iconURL: "https://raw.githubusercontent.com/khcrysalis/Feather/main/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            downloadURL: "https://github.com/khcrysalis/Feather/releases",
            version: "1.4",
            size: 14_800_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.sideload.rawValue
        )
    ]

    init() {
        loadSavedState()
        setupDownloadEngine()
        Task { await refreshAll() }
    }

    private func loadSavedState() {
        sourceURLs = UserDefaults.standard.stringArray(forKey: sourcesKey)
            ?? UserDefaults.standard.stringArray(forKey: "TueeHub_v22_Sources")
            ?? ["https://apps.altstore.io"]

        if let savedFavs = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            favoriteIDs = Set(savedFavs)
        }
        if let data = UserDefaults.standard.data(forKey: certsKey),
           let decoded = try? JSONDecoder().decode([CertificateRecord].self, from: data) {
            certificates = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: selectedCertKey) {
            selectedCertID = UUID(uuidString: idStr)
        }
        if let data = UserDefaults.standard.data(forKey: localIPAsKey),
           let decoded = try? JSONDecoder().decode([LocalIPAItem].self, from: data) {
            localIPAs = decoded
        }
        if let data = UserDefaults.standard.data(forKey: localTweaksKey),
           let decoded = try? JSONDecoder().decode([LocalTweakItem].self, from: data) {
            localTweaks = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: appearanceKey),
           let parsed = AppAppearanceMode(rawValue: raw) {
            appearance = parsed
        }
        if let raw = UserDefaults.standard.string(forKey: cardStyleKey),
           let parsed = CardStyleMode(rawValue: raw) {
            cardStyle = parsed
        }
        if UserDefaults.standard.object(forKey: hapticsKey) != nil {
            hapticsEnabled = UserDefaults.standard.bool(forKey: hapticsKey)
        }
    }

    private func setupDownloadEngine() {
        downloadBridge = DownloadSessionBridge(ipaDirectory: ipasDir)
        downloadBridge.onProgress = { [weak self] id, written, total in
            guard let self = self, var task = self.activeDownloads[id] else { return }
            task.writtenBytes = written
            task.totalBytes = total
            if total > 0 { task.progress = min(max(Double(written) / Double(total), 0.0), 1.0) }
            self.activeDownloads[id] = task
        }

        downloadBridge.onFinished = { [weak self] id, destURL in
            guard let self = self else { return }
            let meta = self.activeDownloads[id]
            self.activeDownloads.removeValue(forKey: id)
            self.runningTasks.removeValue(forKey: id)

            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            let newItem = LocalIPAItem(
                id: UUID(),
                appName: meta?.appName ?? destURL.deletingPathExtension().lastPathComponent,
                fileName: destURL.lastPathComponent,
                version: meta?.version ?? "1.0",
                bundleID: meta?.bundleID ?? "com.tueehub.downloaded",
                sizeBytes: size,
                addedAt: Date()
            )
            self.localIPAs.insert(newItem, at: 0)
            self.persistLocalIPAs()
            self.triggerHaptic(.medium)
        }

        downloadBridge.onError = { [weak self] id, err in
            guard let self = self else { return }
            self.activeDownloads.removeValue(forKey: id)
            self.runningTasks.removeValue(forKey: id)
            self.alertMessage = "Lỗi tải: \(err)"
        }

        downloadSession = URLSession(configuration: .default, delegate: downloadBridge, delegateQueue: nil)
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func toggleFavorite(_ app: AltApp) {
        triggerHaptic(.medium)
        if favoriteIDs.contains(app.id) { favoriteIDs.remove(app.id) } else { favoriteIDs.insert(app.id) }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: favoritesKey)
    }

    func isFavorite(_ app: AltApp) -> Bool {
        favoriteIDs.contains(app.id)
    }

    func addSource(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            alertMessage = "Đường dẫn JSON không hợp lệ."
            return
        }
        if !sourceURLs.contains(trimmed) {
            triggerHaptic(.medium)
            sourceURLs.append(trimmed)
            UserDefaults.standard.set(sourceURLs, forKey: sourcesKey)
            Task { await refreshAll() }
        }
    }

    func importLocalJSONRepo(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AltSource.self, from: data)
            let repoName = decoded.name ?? url.deletingPathExtension().lastPathComponent
            var added = 0
            var existingKeys = Set(apps.map { "\($0.safeBundleID.lowercased())|\($0.name.lowercased())" })
            for var item in decoded.apps ?? [] {
                let key = "\(item.safeBundleID.lowercased())|\(item.name.lowercased())"
                if !existingKeys.contains(key) {
                    existingKeys.insert(key)
                    item.sourceName = repoName
                    apps.append(item)
                    added += 1
                }
            }
            triggerHaptic(.medium)
            alertMessage = "Đã nạp \(added) ứng dụng từ file \(url.lastPathComponent)."
        } catch {
            alertMessage = "File JSON không đúng chuẩn AltSource: \(error.localizedDescription)"
        }
    }

    func removeSource(at offsets: IndexSet) {
        sourceURLs.remove(atOffsets: offsets)
        UserDefaults.standard.set(sourceURLs, forKey: sourcesKey)
        Task { await refreshAll() }
    }

    func refreshAll() async {
        isLoading = true
        var combined: [AltApp] = curatedGitHubApps
        var seen = Set(curatedGitHubApps.map { "\($0.safeBundleID.lowercased())|\($0.name.lowercased())" })
        var counts: [String: Int] = [:]

        for urlString in sourceURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(AltSource.self, from: data)
                let repoName = decoded.name ?? (url.host ?? "Repo")
                let list = decoded.apps ?? []
                counts[urlString] = list.count
                for var item in list {
                    let key = "\(item.safeBundleID.lowercased())|\(item.name.lowercased())"
                    if !seen.contains(key) {
                        seen.insert(key)
                        item.sourceName = repoName
                        combined.append(item)
                    }
                }
            } catch {
                counts[urlString] = 0
            }
        }

        repoAppCounts = counts
        apps = combined
        isLoading = false
    }

    // MARK: - Downloads & Direct URL
    func startIPADownload(for app: AltApp) {
        guard let url = URL(string: app.bestDownloadURL), !app.bestDownloadURL.isEmpty else { return }
        startDirectURLDownload(url: url, appName: app.name, version: app.bestVersion, bundleID: app.safeBundleID, expectedSize: app.rawSizeBytes, taskID: app.id)
    }

    func startDirectURLDownload(url: URL, appName: String? = nil, version: String = "Direct", bundleID: String = "com.tueehub.direct", expectedSize: Int64 = 0, taskID: String? = nil) {
        let id = taskID ?? UUID().uuidString
        if activeDownloads[id] != nil { return }
        let name = appName ?? url.deletingPathExtension().lastPathComponent

        triggerHaptic(.medium)
        activeDownloads[id] = ActiveDownloadTask(
            id: id,
            appName: name.isEmpty ? "Downloaded App" : name,
            version: version,
            bundleID: bundleID,
            progress: 0.02,
            writtenBytes: 0,
            totalBytes: expectedSize
        )

        let task = downloadSession.downloadTask(with: url)
        task.taskDescription = id
        runningTasks[id] = task
        task.resume()
    }

    func cancelDownload(id: String) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
    }

    // MARK: - Local IPA & Tweak Importers
    func importLocalIPAs(from urls: [URL]) {
        var successCount = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "ipa" || ext == "zip" else { continue }
            let safeName = "\(UUID().uuidString.prefix(6))_\(url.lastPathComponent)"
            let dest = ipasDir.appendingPathComponent(safeName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                let item = LocalIPAItem(
                    id: UUID(),
                    appName: url.deletingPathExtension().lastPathComponent,
                    fileName: safeName,
                    version: "Local",
                    bundleID: "local.imported.ipa",
                    sizeBytes: size,
                    addedAt: Date()
                )
                localIPAs.insert(item, at: 0)
                successCount += 1
            } catch {
                alertMessage = "Không nhập được \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if successCount > 0 {
            persistLocalIPAs()
            triggerHaptic(.medium)
        } else if !urls.isEmpty {
            alertMessage = "Vui lòng chọn file có đuôi .ipa."
        }
    }

    func importLocalTweaks(from urls: [URL]) {
        var successCount = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "dylib" || ext == "deb" || ext == "framework" || ext == "zip" else { continue }
            let safeName = "\(UUID().uuidString.prefix(6))_\(url.lastPathComponent)"
            let dest = tweaksDir.appendingPathComponent(safeName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                let item = LocalTweakItem(
                    id: UUID(),
                    name: url.deletingPathExtension().lastPathComponent,
                    fileName: safeName,
                    fileExtension: ext.uppercased(),
                    sizeBytes: size,
                    addedAt: Date()
                )
                localTweaks.insert(item, at: 0)
                successCount += 1
            } catch {
                alertMessage = "Không nhập được tweak: \(error.localizedDescription)"
            }
        }
        if successCount > 0 {
            persistLocalTweaks()
            triggerHaptic(.medium)
        } else if !urls.isEmpty {
            alertMessage = "Vui lòng chọn file đuôi .dylib hoặc .deb."
        }
    }

    func urlForLocalIPA(_ item: LocalIPAItem) -> URL {
        ipasDir.appendingPathComponent(item.fileName)
    }

    func urlForTweak(_ item: LocalTweakItem) -> URL {
        tweaksDir.appendingPathComponent(item.fileName)
    }

    func deleteLocalIPA(at offsets: IndexSet) {
        for idx in offsets {
            try? FileManager.default.removeItem(at: urlForLocalIPA(localIPAs[idx]))
        }
        localIPAs.remove(atOffsets: offsets)
        persistLocalIPAs()
    }

    func deleteLocalTweak(at offsets: IndexSet) {
        for idx in offsets {
            try? FileManager.default.removeItem(at: urlForTweak(localTweaks[idx]))
        }
        localTweaks.remove(atOffsets: offsets)
        persistLocalTweaks()
    }

    private func persistLocalIPAs() {
        if let encoded = try? JSONEncoder().encode(localIPAs) {
            UserDefaults.standard.set(encoded, forKey: localIPAsKey)
        }
    }

    private func persistLocalTweaks() {
        if let encoded = try? JSONEncoder().encode(localTweaks) {
            UserDefaults.standard.set(encoded, forKey: localTweaksKey)
        }
    }

    // MARK: - Certificate Vault
    func saveNewCertificate(label: String, p12SourceURL: URL?, provisionSourceURL: URL?, password: String) {
        var savedP12Name: String?
        var savedProvName: String?
        var teamName = "Chưa xác định"
        var teamID = "N/A"
        var p12Subject: String?
        var p12Status: P12VerifyStatus = .missing
        var expDate: Date?
        var isEnterprise = false
        var deviceCount = 0
        var finalLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        if let p12URL = p12SourceURL {
            let destName = "cert_\(UUID().uuidString.prefix(8)).p12"
            let dest = certsDir.appendingPathComponent(destName)
            if (try? FileManager.default.copyItem(at: p12URL, to: dest)) != nil {
                savedP12Name = destName
                let verified = P12Verifier.verify(fileURL: dest, password: password)
                p12Status = verified.status
                p12Subject = verified.subject
            }
        }

        if let provURL = provisionSourceURL {
            let destName = "prov_\(UUID().uuidString.prefix(8)).mobileprovision"
            let dest = certsDir.appendingPathComponent(destName)
            if (try? FileManager.default.copyItem(at: provURL, to: dest)) != nil {
                savedProvName = destName
                if let info = MobileProvisionParser.parse(fileURL: dest) {
                    teamName = info.teamName
                    teamID = info.teamID
                    expDate = info.expirationDate
                    isEnterprise = info.isEnterprise
                    deviceCount = info.deviceCount
                    if finalLabel.isEmpty { finalLabel = info.name }
                }
            }
        }

        if finalLabel.isEmpty {
            finalLabel = p12Subject ?? "Chứng chỉ #\(certificates.count + 1)"
        }

        let record = CertificateRecord(
            id: UUID(),
            label: finalLabel,
            p12FileName: savedP12Name,
            provisionFileName: savedProvName,
            password: password,
            teamName: teamName,
            teamID: teamID,
            p12SubjectName: p12Subject,
            p12Status: p12Status,
            expirationDate: expDate,
            isEnterprise: isEnterprise,
            deviceCount: deviceCount,
            addedAt: Date()
        )

        certificates.insert(record, at: 0)
        selectedCertID = record.id
        persistCertificates()
        triggerHaptic(.medium)

        if p12Status == .wrongPassword {
            alertMessage = "Đã lưu chứng chỉ nhưng mật khẩu file .p12 không đúng. Bạn hãy kiểm tra lại mật khẩu."
        }
    }

    func selectCertificate(_ cert: CertificateRecord) {
        selectedCertID = cert.id
        UserDefaults.standard.set(cert.id.uuidString, forKey: selectedCertKey)
        triggerHaptic(.light)
    }

    func deleteCertificate(at offsets: IndexSet) {
        for idx in offsets {
            let cert = certificates[idx]
            if let p12 = cert.p12FileName { try? FileManager.default.removeItem(at: certsDir.appendingPathComponent(p12)) }
            if let prov = cert.provisionFileName { try? FileManager.default.removeItem(at: certsDir.appendingPathComponent(prov)) }
        }
        certificates.remove(atOffsets: offsets)
        if let sel = selectedCertID, !certificates.contains(where: { $0.id == sel }) {
            selectedCertID = certificates.first?.id
        }
        persistCertificates()
    }

    func clearTempCache() {
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        triggerHaptic(.medium)
        alertMessage = "Đã dọn sạch bộ nhớ đệm tạm thời."
    }

    private func persistCertificates() {
        if let encoded = try? JSONEncoder().encode(certificates) {
            UserDefaults.standard.set(encoded, forKey: certsKey)
        }
        if let id = selectedCertID {
            UserDefaults.standard.set(id.uuidString, forKey: selectedCertKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedCertKey)
        }
    }
}

// MARK: - Root ContentView (iOS 27 Native Liquid Glass TabView)
struct ContentView: View {
    @StateObject private var store = IPAStoreManager()
    @State private var selectedTab: MainTab = .apps
    @State private var globalSearchText = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Apps", systemImage: "square.stack.3d.up.fill", value: MainTab.apps) {
                AppsTabView(store: store)
            }

            Tab("Sources", systemImage: "books.vertical.fill", value: MainTab.sources) {
                SourcesTabView(store: store)
            }

            Tab("Library", systemImage: "tray.full.fill", value: MainTab.library) {
                LibraryTabView(store: store)
            }
            .badge(store.activeDownloads.count)

            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                SettingsTabView(store: store)
            }

            Tab(value: MainTab.search, role: .search) {
                GlobalSearchView(store: store, query: $globalSearchText)
            }
        }
        .applyLiquidTabBehavior()
        .preferredColorScheme(store.appearance.colorScheme)
        .alert("TueeHub", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

// MARK: - Tab 1: My Apps
struct AppsTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var selectedCategory: AppCategory = .all
    @State private var sortOrder: AppSortOrder = .defaultOrder
    @State private var favoritesOnly = false
    @State private var selectedApp: AltApp?
    @State private var showCertSheet = false
    @Environment(\.openURL) private var openURL

    var filteredApps: [AltApp] {
        let list = store.apps.filter { app in
            let matchesFav = !favoritesOnly || store.isFavorite(app)
            let matchesCat = selectedCategory == .all || app.resolvedCategory == selectedCategory
            return matchesFav && matchesCat
        }
        switch sortOrder {
        case .defaultOrder: return list
        case .nameAZ: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .sizeDesc: return list.sorted { $0.rawSizeBytes > $1.rawSizeBytes }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Bộ lọc danh mục tối giản chuẩn iOS 27
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AppCategory.allCases) { cat in
                                let isSelected = selectedCategory == cat
                                Button {
                                    store.triggerHaptic(.light)
                                    withAnimation(.snappy) { selectedCategory = cat }
                                } label: {
                                    Text(cat.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                                        .foregroundStyle(isSelected ? .white : .secondary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Thẻ danh sách ứng dụng kiểu LiveContainer
                    LazyVStack(spacing: 12) {
                        ForEach(filteredApps) { app in
                            NativeAppCard(
                                app: app,
                                cardStyle: store.cardStyle,
                                isFavorite: store.isFavorite(app),
                                downloadTask: store.activeDownloads[app.id],
                                onSelect: { selectedApp = app },
                                onAction: {
                                    if app.isDirectIPA {
                                        store.startIPADownload(for: app)
                                    } else if let url = URL(string: app.bestDownloadURL) {
                                        openURL(url)
                                    } else {
                                        selectedApp = app
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    Text("\(filteredApps.count) apps total")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .padding(.top, 4)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("My Apps")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        NativeFilePicker.shared.pick(allowsMultiple: true) { urls in
                            store.importLocalIPAs(from: urls)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }

                    Button {
                        showCertSheet = true
                    } label: {
                        Image(systemName: store.activeCertificate?.isReady == true ? "checkmark.seal.fill" : "checkmark.seal")
                            .foregroundStyle(store.activeCertificate?.isReady == true ? .green : .primary)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                            .foregroundStyle(favoritesOnly ? .pink : .primary)
                    }

                    Menu {
                        Picker("Sắp xếp", selection: $sortOrder) {
                            ForEach(AppSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        Button {
                            Task { await store.refreshAll() }
                        } label: {
                            Label("Làm mới nguồn", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailSheet(app: app, store: store)
            }
            .sheet(isPresented: $showCertSheet) {
                NavigationStack {
                    CertVaultView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Đóng") { showCertSheet = false }
                            }
                        }
                }
            }
        }
    }
}

struct NativeAppCard: View {
    let app: AltApp
    let cardStyle: CardStyleMode
    let isFavorite: Bool
    let downloadTask: ActiveDownloadTask?
    let onSelect: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.2)
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.headline)
                        .foregroundStyle(cardStyle == .tinted ? .white : .primary)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                }

                Text("\(app.bestVersion) - \(app.safeBundleID)")
                    .font(.subheadline)
                    .foregroundStyle(cardStyle == .tinted ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)

                Text(app.subtitle ?? app.sourceName ?? "GitHub Official")
                    .font(.caption2.monospaced())
                    .foregroundStyle(cardStyle == .tinted ? .white.opacity(0.55) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if let dl = downloadTask {
                ProgressView(value: dl.progress)
                    .progressViewStyle(.circular)
                    .tint(cardStyle == .tinted ? .white : .accentColor)
                    .frame(width: 68)
            } else {
                Button(action: onAction) {
                    Text(app.isDirectIPA ? "Get" : "Open")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 34)
                        .background(cardStyle == .tinted ? app.buttonTint : Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(cardStyle == .tinted ? app.cardTint : Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Tab 2: Sources
struct SourcesTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showAddAlert = false
    @State private var newRepoURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Nguồn AltSource JSON (\(store.sourceURLs.count))") {
                    ForEach(store.sourceURLs, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(string: url)?.host ?? "JSON Repo")
                                    .font(.headline)
                                Text(url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let count = store.repoAppCounts[url] {
                                Text("\(count)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = url
                            } label: {
                                Label("Copy đường dẫn", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .onDelete(perform: store.removeSource)
                }

                Section("Thêm nhanh nguồn cộng đồng") {
                    Button("AltStore Official") {
                        store.addSource("https://apps.altstore.io")
                    }
                    Button("SideStore Community") {
                        store.addSource("https://community-apps.sidestore.io/sidecommunity.json")
                    }
                }
            }
            .navigationTitle("Sources")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        NativeFilePicker.shared.pick(types: [.json, .data, .item]) { urls in
                            if let first = urls.first {
                                store.importLocalJSONRepo(from: first)
                            }
                        }
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }

                    Button {
                        showAddAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Thêm nguồn JSON", isPresented: $showAddAlert) {
                TextField("https://.../apps.json", text: $newRepoURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Thêm") {
                    store.addSource(newRepoURL)
                    newRepoURL = ""
                }
                Button("Hủy", role: .cancel) { newRepoURL = "" }
            } message: {
                Text("Dán đường dẫn file JSON chuẩn AltStore / SideStore / Feather.")
            }
        }
    }
}

// MARK: - Tab 3: Library (IPAs + Tweaks + Direct Link)
struct LibraryTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var segment = 0
    @State private var inspectingItem: LocalIPAItem?
    @State private var showDirectURLAlert = false
    @State private var directURLText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mục", selection: $segment) {
                        Text("IPAs (\(store.localIPAs.count))").tag(0)
                        Text("Tweaks (\(store.localTweaks.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !store.activeDownloads.isEmpty {
                    Section("Đang tải xuống") {
                        ForEach(Array(store.activeDownloads.values)) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(task.appName).font(.headline)
                                    Spacer()
                                    Text("\(Int(task.progress * 100))%")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Button("Hủy", role: .destructive) {
                                        store.cancelDownload(id: task.id)
                                    }
                                    .font(.caption)
                                }
                                ProgressView(value: task.progress)
                                Text(task.formattedProgress)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if segment == 0 {
                    Section("Kho file IPA trên máy") {
                        if store.localIPAs.isEmpty {
                            ContentUnavailableView(
                                "Chưa có file IPA",
                                systemImage: "shippingbox",
                                description: Text("Bấm nút + để nhập file .ipa từ app Tệp hoặc dán link tải trực tiếp.")
                            )
                        } else {
                            ForEach(store.localIPAs) { item in
                                Button {
                                    inspectingItem = item
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "shippingbox.fill")
                                            .font(.title2)
                                            .foregroundStyle(.blue)
                                            .frame(width: 40, height: 40)
                                            .background(Color.blue.opacity(0.14))
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.appName)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(item.version) • \(item.formattedSize)")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Text("Mở / Ký")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.accentColor.opacity(0.16))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .onDelete(perform: store.deleteLocalIPA)
                        }
                    }
                } else {
                    Section("Kho Tweaks (.dylib / .deb)") {
                        if store.localTweaks.isEmpty {
                            ContentUnavailableView(
                                "Chưa có Tweak",
                                systemImage: "wrench.and.screwdriver",
                                description: Text("Bấm nút + để nhập tệp .dylib hoặc .deb từ app Tệp.")
                            )
                        } else {
                            ForEach(store.localTweaks) { tweak in
                                HStack(spacing: 12) {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .font(.title3)
                                        .foregroundStyle(.purple)
                                        .frame(width: 38, height: 38)
                                        .background(Color.purple.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tweak.name)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text("\(tweak.fileExtension) • \(tweak.formattedSize)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    ShareLink(item: store.urlForTweak(tweak)) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                            }
                            .onDelete(perform: store.deleteLocalTweak)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if segment == 0 {
                        Button {
                            showDirectURLAlert = true
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                    }

                    Button {
                        NativeFilePicker.shared.pick(allowsMultiple: true) { urls in
                            if segment == 0 {
                                store.importLocalIPAs(from: urls)
                            } else {
                                store.importLocalTweaks(from: urls)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Tải IPA từ đường dẫn", isPresented: $showDirectURLAlert) {
                TextField("https://.../app.ipa", text: $directURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Tải về") {
                    if let url = URL(string: directURLText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        store.startDirectURLDownload(url: url)
                    } else {
                        store.alertMessage = "Đường dẫn tải IPA không hợp lệ."
                    }
                    directURLText = ""
                }
                Button("Hủy", role: .cancel) { directURLText = "" }
            } message: {
                Text("Nhập link tải trực tiếp đuôi .ipa để lưu thẳng vào Library.")
            }
            .sheet(item: $inspectingItem) { item in
                IPAInspectorSheet(item: item, store: store)
            }
        }
    }
}

struct IPAInspectorSheet: View {
    let item: LocalIPAItem
    @ObservedObject var store: IPAStoreManager
    @Environment(\.dismiss) private var dismiss

    @State private var customName = ""
    @State private var customBundleID = ""
    @State private var enableFileSharing = true
    @State private var removeDeviceLimit = true
    @State private var selectedTweakIDs: Set<UUID> = []
    @State private var sha256Hash = "Đang tính..."

    var body: some View {
        NavigationStack {
            Form {
                Section("Chứng chỉ ký mặc định") {
                    if let cert = store.activeCertificate {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cert.label).font(.headline)
                                Text("\(cert.teamName) • \(cert.statusText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: cert.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(cert.isReady ? .green : .orange)
                        }
                    } else {
                        Text("Chưa nhập chứng chỉ trong Cert Vault")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Tùy chỉnh cấu hình IPA") {
                    TextField("Tên hiển thị", text: $customName)
                    TextField("Bundle ID", text: $customBundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Bật Chia sẻ tệp (UIFileSharingEnabled)", isOn: $enableFileSharing)
                    Toggle("Gỡ giới hạn thiết bị", isOn: $removeDeviceLimit)
                }

                if !store.localTweaks.isEmpty {
                    Section("Gắn kèm Tweaks (.dylib / .deb)") {
                        ForEach(store.localTweaks) { tweak in
                            Button {
                                if selectedTweakIDs.contains(tweak.id) {
                                    selectedTweakIDs.remove(tweak.id)
                                } else {
                                    selectedTweakIDs.insert(tweak.id)
                                }
                            } label: {
                                HStack {
                                    Text(tweak.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedTweakIDs.contains(tweak.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Thông tin tệp") {
                    LabeledContent("Dung lượng", value: item.formattedSize)
                    LabeledContent("Ngày thêm", value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(sha256Hash)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section {
                    ShareLink(item: store.urlForLocalIPA(item)) {
                        Label("Gửi sang Feather / LiveContainer / SideStore", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } footer: {
                    Text("Chọn Feather, LiveContainer hoặc SideStore từ bảng chia sẻ gốc của iOS để ký và cài đặt ngay.")
                }
            }
            .navigationTitle(item.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
            .task {
                customName = item.appName
                customBundleID = item.bundleID
                sha256Hash = await FileHasher.sha256(url: store.urlForLocalIPA(item))
            }
        }
    }
}

// MARK: - Certificate Vault View & Importer (Fix triệt để chọn file)
struct CertVaultView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showImportSheet = false

    var body: some View {
        List {
            if store.certificates.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Chưa có chứng chỉ",
                        systemImage: "checkmark.seal",
                        description: Text("Bấm nút + góc trên để nhập file .p12 và .mobileprovision từ app Tệp.")
                    )
                }
            } else {
                Section("Chứng chỉ đã lưu (\(store.certificates.count))") {
                    ForEach(store.certificates) { cert in
                        Button {
                            store.selectCertificate(cert)
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(cert.label)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(cert.statusText)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(cert.isReady ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                            .foregroundStyle(cert.isReady ? .green : .orange)
                                            .clipShape(Capsule())
                                    }

                                    Text("\(cert.teamName) • \(cert.teamID)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        Text(cert.p12Status.rawValue)
                                            .font(.caption2.bold())
                                            .foregroundStyle(cert.p12Status == .verified ? .green : .orange)
                                        if cert.isEnterprise {
                                            Text("Enterprise")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.purple)
                                        } else if cert.deviceCount > 0 {
                                            Text("Ad-Hoc (\(cert.deviceCount) UDID)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let exp = cert.expirationDate {
                                        Text("Hết hạn: \(exp.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if store.activeCertificate?.id == cert.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                    .onDelete(perform: store.deleteCertificate)
                }
            }
        }
        .navigationTitle("Cert Vault")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImportSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportCertificateSheet(store: store)
        }
    }
}

struct ImportCertificateSheet: View {
    @ObservedObject var store: IPAStoreManager
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var password = ""
    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var p12CheckText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Chọn tệp chứng chỉ") {
                    Button {
                        NativeFilePicker.shared.pick { urls in
                            if let url = urls.first {
                                p12URL = url
                                updateP12Check()
                            }
                        }
                    } label: {
                        HStack {
                            Label("Chọn file .p12", systemImage: "key.fill")
                            Spacer()
                            Text(p12URL?.lastPathComponent ?? "Bấm để chọn")
                                .foregroundStyle(p12URL == nil ? Color.secondary : Color.blue)

                                .lineLimit(1)
                        }
                    }

                    Button {
                        NativeFilePicker.shared.pick { urls in
                            if let url = urls.first {
                                provisionURL = url
                            }
                        }
                    } label: {
                        HStack {
                            Label("Chọn .mobileprovision", systemImage: "doc.badge.gearshape")
                            Spacer()
                            Text(provisionURL?.lastPathComponent ?? "Bấm để chọn")
                                .foregroundStyle(provisionURL == nil ? .secondary : .blue)
                                .lineLimit(1)
                        }
                    }
                }

                Section("2. Mật khẩu & Tên gợi nhớ") {
                    SecureField("Mật khẩu file .p12", text: $password)
                        .onChange(of: password) { _, _ in updateP12Check() }

                    if let status = p12CheckText {
                        Text(status)
                            .font(.caption.bold())
                            .foregroundStyle(status.contains("hợp lệ") ? .green : .orange)
                    }

                    TextField("Tên gợi nhớ (để trống tự lấy)", text: $label)
                }
            }
            .navigationTitle("Nhập Chứng Chỉ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Lưu") {
                        store.saveNewCertificate(
                            label: label,
                            p12SourceURL: p12URL,
                            provisionSourceURL: provisionURL,
                            password: password
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(p12URL == nil && provisionURL == nil)
                }
            }
        }
    }

    private func updateP12Check() {
        guard let url = p12URL else {
            p12CheckText = nil
            return
        }
        let check = P12Verifier.verify(fileURL: url, password: password)
        if let name = check.subject, check.status == .verified {
            p12CheckText = "✓ P12 hợp lệ (\(name))"
        } else {
            p12CheckText = check.status.rawValue
        }
    }
}

// MARK: - Tab 4: Settings
struct SettingsTabView: View {
    @ObservedObject var store: IPAStoreManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Chứng chỉ ký") {
                    NavigationLink {
                        CertVaultView(store: store)
                    } label: {
                        HStack {
                            Label("Cert Vault", systemImage: "checkmark.seal.fill")
                            Spacer()
                            Text(store.activeCertificate?.label ?? "Chưa nhập")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Giao diện iOS 27") {
                    Picker("Chế độ màu", selection: $store.appearance) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Picker("Kiểu thẻ ứng dụng", selection: $store.cardStyle) {
                        ForEach(CardStyleMode.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    Toggle("Phản hồi rung (Haptics)", isOn: $store.hapticsEnabled)
                }

                Section("Lưu trữ & Bộ nhớ") {
                    LabeledContent("Ứng dụng từ nguồn", value: "\(store.apps.count)")
                    LabeledContent("File IPA đã lưu", value: "\(store.localIPAs.count)")
                    LabeledContent("Tweaks đã lưu", value: "\(store.localTweaks.count)")
                    LabeledContent("Dung lượng đã dùng", value: ByteCountFormatter.string(fromByteCount: store.totalStorageBytes, countStyle: .file))
                    Button("Dọn bộ nhớ đệm tạm", role: .destructive) {
                        store.clearTempCache()
                    }
                }

                Section("Thông tin") {
                    LabeledContent("Ứng dụng", value: "TueeHub")
                    LabeledContent("Phiên bản", value: "3.0 (iOS 27 Liquid Glass)")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Tab 5: Global Search (Nút kính lúp tách rời góc phải)
struct GlobalSearchView: View {
    @ObservedObject var store: IPAStoreManager
    @Binding var query: String
    @State private var selectedApp: AltApp?
    @State private var inspectingIPA: LocalIPAItem?

    var matchingApps: [AltApp] {
        guard !query.isEmpty else { return Array(store.apps.prefix(6)) }
        return store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.safeBundleID.localizedCaseInsensitiveContains(query) ||
            ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var matchingIPAs: [LocalIPAItem] {
        guard !query.isEmpty else { return [] }
        return store.localIPAs.filter {
            $0.appName.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var matchingTweaks: [LocalTweakItem] {
        guard !query.isEmpty else { return [] }
        return store.localTweaks.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !matchingIPAs.isEmpty {
                    Section("Library IPA") {
                        ForEach(matchingIPAs) { item in
                            Button {
                                inspectingIPA = item
                            } label: {
                                LabeledContent(item.appName, value: item.formattedSize)
                            }
                        }
                    }
                }

                if !matchingTweaks.isEmpty {
                    Section("Tweaks") {
                        ForEach(matchingTweaks) { tweak in
                            LabeledContent(tweak.name, value: tweak.fileExtension)
                        }
                    }
                }

                Section(query.isEmpty ? "Gợi ý nổi bật" : "Ứng dụng (\(matchingApps.count))") {
                    ForEach(matchingApps) { app in
                        Button {
                            selectedApp = app
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.2)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(app.safeBundleID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Tìm app, IPA, tweak, bundle ID...")
            .sheet(item: $selectedApp) { app in
                AppDetailSheet(app: app, store: store)
            }
            .sheet(item: $inspectingIPA) { item in
                IPAInspectorSheet(item: item, store: store)
            }
        }
    }
}

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    let app: AltApp
    @ObservedObject var store: IPAStoreManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.25)
                            }
                        }
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title3.bold())
                            Text(app.developerName ?? "Open-Source")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("v\(app.bestVersion) • \(app.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        if app.isDirectIPA {
                            store.startIPADownload(for: app)
                            dismiss()
                        } else if let url = URL(string: app.bestDownloadURL) {
                            openURL(url)
                        }
                    } label: {
                        Label(app.isDirectIPA ? "Tải IPA vào Library" : "Mở trang GitHub", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Giới thiệu") {
                    Text(app.localizedDescription ?? app.subtitle ?? "Không có mô tả.")
                        .font(.subheadline)
                }

                Section("Chi tiết") {
                    LabeledContent("Bundle ID", value: app.safeBundleID)
                    LabeledContent("Nguồn", value: app.sourceName ?? "GitHub Official")
                    Button {
                        UIPasteboard.general.string = app.bestDownloadURL
                        copied = true
                    } label: {
                        Label(copied ? "Đã copy link" : "Copy link tải", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .navigationTitle("Chi tiết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.toggleFavorite(app)
                    } label: {
                        Image(systemName: store.isFavorite(app) ? "heart.fill" : "heart")
                            .foregroundStyle(store.isFavorite(app) ? .pink : .primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
