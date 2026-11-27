import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Theme System
enum ThemeAccent: String, CaseIterable, Identifiable, Codable {
    case cyber = "Cyber Blue"
    case neon = "Neon Purple"
    case emerald = "Emerald"
    case sunset = "Sunset"

    var id: String { rawValue }

    var primary: Color {
        switch self {
        case .cyber: return Color(red: 0/255, green: 185/255, blue: 255/255)
        case .neon: return Color(red: 155/255, green: 95/255, blue: 255/255)
        case .emerald: return Color(red: 30/255, green: 215/255, blue: 150/255)
        case .sunset: return Color(red: 255/255, green: 115/255, blue: 95/255)
        }
    }

    var secondary: Color {
        switch self {
        case .cyber: return Color(red: 110/255, green: 85/255, blue: 255/255)
        case .neon: return Color(red: 245/255, green: 75/255, blue: 175/255)
        case .emerald: return Color(red: 0/255, green: 165/255, blue: 225/255)
        case .sunset: return Color(red: 235/255, green: 65/255, blue: 155/255)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
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
    var isFeatured: Bool = false

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
        let raw = versions?.first?.version ?? version ?? "1.0"
        return raw.hasPrefix("v") ? raw : "v\(raw)"
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

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription
        case iconURL, downloadURL, version, size, versions
    }
}

// MARK: - Certificate & Library Models
struct CertificateRecord: Codable, Identifiable {
    let id: UUID
    var label: String
    var p12FileName: String?
    var provisionFileName: String?
    var password: String
    var teamName: String
    var teamID: String
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
        if p12FileName == nil || provisionFileName == nil {
            return "Thiếu file"
        }
        if isExpired {
            return "Hết hạn"
        }
        if let days = daysRemaining {
            return "Còn \(days) ngày"
        }
        return "Hoạt động"
    }

    var isReady: Bool {
        p12FileName != nil && provisionFileName != nil && !isExpired
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

struct ActiveDownloadTask: Identifiable {
    let id: String
    let appName: String
    let version: String
    let bundleID: String
    var progress: Double
    var writtenBytes: Int64
    var totalBytes: Int64
}

enum AppCategory: String, CaseIterable, Identifiable {
    case all = "All Apps"
    case emu = "EMU"
    case ports = "Ports"
    case sideload = "Sideloading"
    case games = "Games"
    case tools = "Tools"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .emu: return "gamecontroller.fill"
        case .ports: return "arrow.left.arrow.right"
        case .sideload: return "square.stack.3d.up.fill"
        case .games: return "flame.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }
}

enum AppSortMode: String, CaseIterable, Identifiable {
    case featured = "Nổi bật"
    case nameAZ = "Tên A → Z"
    case sizeDesc = "Dung lượng"

    var id: String { rawValue }
}

enum MainTab: Int, CaseIterable {
    case apps, repos, certs, library, settings

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .repos: return "Repos"
        case .certs: return "Certs"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .apps: return "square.stack.3d.up.fill"
        case .repos: return "globe.asia.australia.fill"
        case .certs: return "checkmark.seal.fill"
        case .library: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - MobileProvision XML Parser
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
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let startRange = data.range(of: Data("<plist".utf8)),
              let endRange = data.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<data.endIndex) else {
            return nil
        }

        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let name = (plist["Name"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
        let teamName = (plist["TeamName"] as? String) ?? "Unknown Team"
        let teamIDs = (plist["TeamIdentifier"] as? [String]) ?? []
        let teamID = teamIDs.first ?? "N/A"
        let expDate = plist["ExpirationDate"] as? Date
        let isEnterprise = (plist["ProvisionsAllDevices"] as? Bool) ?? false
        let devices = (plist["ProvisionedDevices"] as? [String]) ?? []

        return ParsedInfo(
            name: name,
            teamName: teamName,
            teamID: teamID,
            expirationDate: expDate,
            isEnterprise: isEnterprise,
            deviceCount: devices.count
        )
    }
}

// MARK: - URLSession Download Delegate Bridge
final class DownloadSessionBridge: NSObject, URLSessionDownloadDelegate {
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
        DispatchQueue.main.async { [weak self] in
            self?.onError?(id, error.localizedDescription)
        }
    }
}

// MARK: - Main Store Manager
@MainActor
final class IPAStoreManager: ObservableObject {
    @Published var apps: [AltApp] = []
    @Published var sourceURLs: [String] = []
    @Published var favoriteIDs: Set<String> = []
    @Published var certificates: [CertificateRecord] = []
    @Published var selectedCertID: UUID?
    @Published var localIPAs: [LocalIPAItem] = []
    @Published var activeDownloads: [String: ActiveDownloadTask] = [:]
    @Published var isLoading = false
    @Published var toastMessage: String?

    @Published var theme: ThemeAccent = .cyber {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: themeKey) }
    }
    @Published var auroraEnabled: Bool = true {
        didSet { UserDefaults.standard.set(auroraEnabled, forKey: auroraKey) }
    }
    @Published var hapticsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: hapticsKey) }
    }

    private let sourcesKey = "TueeHub_v22_Sources"
    private let favoritesKey = "TueeHub_v22_Favorites"
    private let certsKey = "TueeHub_v22_Certs"
    private let selectedCertKey = "TueeHub_v22_SelectedCert"
    private let localIPAsKey = "TueeHub_v22_LocalIPAs"
    private let themeKey = "TueeHub_v22_Theme"
    private let auroraKey = "TueeHub_v22_Aurora"
    private let hapticsKey = "TueeHub_v22_Haptics"

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

    var activeCertificate: CertificateRecord? {
        if let id = selectedCertID, let found = certificates.first(where: { $0.id == id }) {
            return found
        }
        return certificates.first(where: { $0.isReady }) ?? certificates.first
    }

    let curatedGitHubApps: [AltApp] = [
        AltApp(
            name: "PojavLauncher",
            bundleIdentifier: "net.kdt.pojavlaunch",
            developerName: "PojavLauncherTeam",
            subtitle: "Minecraft Java Edition PC Port cho iOS",
            localizedDescription: "Chạy thẳng Minecraft Java Edition mã nguồn mở trên iPhone, hỗ trợ Fabric, Forge và shader. Khuyên bật JIT để đạt FPS cao.",
            iconURL: "https://raw.githubusercontent.com/PojavLauncherTeam/PojavLauncher_iOS/main/Natives/Assets.xcassets/AppIcon-Default.appiconset/AppIcon-Default-1024.png",
            downloadURL: "https://github.com/PojavLauncherTeam/PojavLauncher_iOS/releases",
            version: "2.2",
            size: 118_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.ports.rawValue,
            isFeatured: true
        ),
        AltApp(
            name: "DolphiniOS",
            bundleIdentifier: "me.oatmealdome.dolphinios",
            developerName: "OatmealDome",
            subtitle: "Giả lập GameCube & Wii 60 FPS",
            localizedDescription: "Trình giả lập GameCube và Wii mã nguồn mở mượt nhất cho iOS, hỗ trợ tay cầm Bluetooth và xuất màn hình ngoài.",
            iconURL: "https://raw.githubusercontent.com/OatmealDome/dolphin-ios/master/Source/iOS/App/DolphiniOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            downloadURL: "https://github.com/OatmealDome/dolphin-ios/releases",
            version: "4.0",
            size: 46_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.emu.rawValue,
            isFeatured: true
        ),
        AltApp(
            name: "UTM",
            bundleIdentifier: "com.utmapp.UTM",
            developerName: "utmapp",
            subtitle: "Máy ảo Windows & Linux ngay trên iPhone",
            localizedDescription: "Chạy hệ điều hành Windows, Ubuntu, Arch Linux trực tiếp trên iPhone bằng QEMU mã nguồn mở.",
            iconURL: "https://raw.githubusercontent.com/utmapp/UTM/main/Platform/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon1024x1024.png",
            downloadURL: "https://github.com/utmapp/UTM/releases",
            version: "4.6",
            size: 165_000_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.tools.rawValue,
            isFeatured: true
        ),
        AltApp(
            name: "Delta Emulator",
            bundleIdentifier: "com.rileytestut.Delta",
            developerName: "Riley Testut",
            subtitle: "NES, SNES, N64, GBC, GBA, DS",
            localizedDescription: "Giả lập đa hệ máy Nintendo mã nguồn mở, hỗ trợ cheat code, tùy chỉnh skin và đồng bộ save.",
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
            localizedDescription: "Chơi game PSP mượt mà với đồ họa nâng cấp và tùy biến phím bấm linh hoạt.",
            iconURL: "https://raw.githubusercontent.com/hrydgard/ppsspp/master/icons/icon-512.png",
            downloadURL: "https://github.com/hrydgard/ppsspp/releases",
            version: "1.18",
            size: 31_200_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.emu.rawValue
        ),
        AltApp(
            name: "Feather",
            bundleIdentifier: "kh.crysalis.feather",
            developerName: "khcrysalis",
            subtitle: "Trình ký IPA & inject dylib trên máy",
            localizedDescription: "Ứng dụng ký file IPA mã nguồn mở, hỗ trợ quản lý nguồn AltSource và tinh chỉnh dylib trực tiếp trên iPhone.",
            iconURL: "https://raw.githubusercontent.com/khcrysalis/Feather/main/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            downloadURL: "https://github.com/khcrysalis/Feather/releases",
            version: "1.4",
            size: 14_800_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.sideload.rawValue
        ),
        AltApp(
            name: "Aidoku",
            bundleIdentifier: "xyz.skitty.Aidoku",
            developerName: "Skittyblock",
            subtitle: "Đọc Manga mã nguồn mở viết bằng Swift",
            localizedDescription: "Giao diện mượt như app gốc Apple, hỗ trợ cài nguồn mở rộng WASM và đọc offline.",
            iconURL: "https://raw.githubusercontent.com/Aidoku/Aidoku/main/iOS/Assets.xcassets/AppIcon.appiconset/Icon-1024.png",
            downloadURL: "https://github.com/Aidoku/Aidoku/releases",
            version: "0.6",
            size: 19_400_000,
            versions: nil,
            sourceName: "GitHub Official",
            manualCategory: AppCategory.tools.rawValue
        )
    ]

    init() {
        loadSavedState()
        setupDownloadEngine()
        Task { await refreshAll() }
    }

    private func loadSavedState() {
        if let saved = UserDefaults.standard.stringArray(forKey: sourcesKey) {
            sourceURLs = saved
        } else {
            sourceURLs = ["https://apps.altstore.io"]
        }

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

        if let savedTheme = UserDefaults.standard.string(forKey: themeKey),
           let parsedTheme = ThemeAccent(rawValue: savedTheme) {
            theme = parsedTheme
        }

        if UserDefaults.standard.object(forKey: auroraKey) != nil {
            auroraEnabled = UserDefaults.standard.bool(forKey: auroraKey)
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
            if total > 0 {
                task.progress = min(max(Double(written) / Double(total), 0.0), 1.0)
            }
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
                version: meta?.version ?? "v1.0",
                bundleID: meta?.bundleID ?? "com.tueehub.imported",
                sizeBytes: size,
                addedAt: Date()
            )
            self.localIPAs.insert(newItem, at: 0)
            self.persistLocalIPAs()
            self.triggerHaptic(.medium)
            self.showToast("Đã tải xong \(newItem.appName) vào Library")
        }

        downloadBridge.onError = { [weak self] id, err in
            guard let self = self else { return }
            self.activeDownloads.removeValue(forKey: id)
            self.runningTasks.removeValue(forKey: id)
            self.showToast("Lỗi tải: \(err)")
        }

        downloadSession = URLSession(configuration: .default, delegate: downloadBridge, delegateQueue: nil)
    }

    func showToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) {
                if self?.toastMessage == message {
                    self?.toastMessage = nil
                }
            }
        }
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - Favorites & Repos
    func toggleFavorite(_ app: AltApp) {
        triggerHaptic(.medium)
        if favoriteIDs.contains(app.id) {
            favoriteIDs.remove(app.id)
        } else {
            favoriteIDs.insert(app.id)
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: favoritesKey)
    }

    func isFavorite(_ app: AltApp) -> Bool {
        favoriteIDs.contains(app.id)
    }

    func addSource(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            showToast("Đường dẫn JSON không hợp lệ")
            return
        }
        if !sourceURLs.contains(trimmed) {
            triggerHaptic(.medium)
            sourceURLs.append(trimmed)
            UserDefaults.standard.set(sourceURLs, forKey: sourcesKey)
            showToast("Đã thêm nguồn mới, đang đồng bộ...")
            Task { await refreshAll() }
        }
    }

    func removeSource(_ url: String) {
        sourceURLs.removeAll { $0 == url }
        UserDefaults.standard.set(sourceURLs, forKey: sourcesKey)
        Task { await refreshAll() }
    }

    func refreshAll() async {
        isLoading = true
        var combined: [AltApp] = curatedGitHubApps
        var seen = Set(curatedGitHubApps.map { "\($0.safeBundleID.lowercased())|\($0.name.lowercased())" })

        for urlString in sourceURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(AltSource.self, from: data)
                let repoName = decoded.name ?? (url.host ?? "Repo")
                for var item in decoded.apps ?? [] {
                    let key = "\(item.safeBundleID.lowercased())|\(item.name.lowercased())"
                    if !seen.contains(key) {
                        seen.insert(key)
                        item.sourceName = repoName
                        combined.append(item)
                    }
                }
            } catch {
                showToast("Lỗi đọc nguồn: \(url.host ?? urlString)")
            }
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            apps = combined
            isLoading = false
        }
    }

    // MARK: - In-App IPA Downloads & Local Imports
    func startIPADownload(for app: AltApp) {
        guard let url = URL(string: app.bestDownloadURL), !app.bestDownloadURL.isEmpty else {
            showToast("Ứng dụng chưa có link tải")
            return
        }
        if activeDownloads[app.id] != nil {
            showToast("Đang tải \(app.name)...")
            return
        }

        triggerHaptic(.medium)
        let active = ActiveDownloadTask(
            id: app.id,
            appName: app.name,
            version: app.bestVersion,
            bundleID: app.safeBundleID,
            progress: 0.02,
            writtenBytes: 0,
            totalBytes: app.rawSizeBytes
        )
        activeDownloads[app.id] = active

        let task = downloadSession.downloadTask(with: url)
        task.taskDescription = app.id
        runningTasks[app.id] = task
        task.resume()
        showToast("Bắt đầu tải \(app.name)...")
    }

    func cancelDownload(id: String) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
        showToast("Đã hủy tải xuống")
    }

    func importLocalIPA(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" else {
            showToast("Vui lòng chọn đúng file đuôi .ipa")
            return
        }

        let safeName = "\(UUID().uuidString.prefix(6))_\(url.lastPathComponent)"
        let dest = ipasDir.appendingPathComponent(safeName)
        do {
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
            persistLocalIPAs()
            triggerHaptic(.medium)
            showToast("Đã nhập \(item.appName).ipa vào Library")
        } catch {
            showToast("Lỗi nhập IPA: \(error.localizedDescription)")
        }
    }

    func urlForLocalIPA(_ item: LocalIPAItem) -> URL {
        ipasDir.appendingPathComponent(item.fileName)
    }

    func deleteLocalIPA(_ item: LocalIPAItem) {
        let fileURL = urlForLocalIPA(item)
        try? FileManager.default.removeItem(at: fileURL)
        localIPAs.removeAll { $0.id == item.id }
        persistLocalIPAs()
    }

    private func persistLocalIPAs() {
        if let encoded = try? JSONEncoder().encode(localIPAs) {
            UserDefaults.standard.set(encoded, forKey: localIPAsKey)
        }
    }

    // MARK: - Certificate Vault Management
    func saveNewCertificate(label: String, p12SourceURL: URL?, provisionSourceURL: URL?, password: String) {
        var savedP12Name: String?
        var savedProvName: String?
        var teamName = "Chưa xác định"
        var teamID = "N/A"
        var expDate: Date?
        var isEnterprise = false
        var deviceCount = 0
        var finalLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        if let p12URL = p12SourceURL {
            let accessed = p12URL.startAccessingSecurityScopedResource()
            defer { if accessed { p12URL.stopAccessingSecurityScopedResource() } }
            let destName = "cert_\(UUID().uuidString.prefix(8)).p12"
            let dest = certsDir.appendingPathComponent(destName)
            if (try? FileManager.default.copyItem(at: p12URL, to: dest)) != nil {
                savedP12Name = destName
            }
        }

        if let provURL = provisionSourceURL {
            let accessed = provURL.startAccessingSecurityScopedResource()
            defer { if accessed { provURL.stopAccessingSecurityScopedResource() } }
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
            finalLabel = "Chứng chỉ #\(certificates.count + 1)"
        }

        let record = CertificateRecord(
            id: UUID(),
            label: finalLabel,
            p12FileName: savedP12Name,
            provisionFileName: savedProvName,
            password: password,
            teamName: teamName,
            teamID: teamID,
            expirationDate: expDate,
            isEnterprise: isEnterprise,
            deviceCount: deviceCount,
            addedAt: Date()
        )

        certificates.insert(record, at: 0)
        selectedCertID = record.id
        persistCertificates()
        triggerHaptic(.medium)
        showToast("Đã lưu chứng chỉ \(record.label)")
    }

    func selectCertificate(_ cert: CertificateRecord) {
        selectedCertID = cert.id
        UserDefaults.standard.set(cert.id.uuidString, forKey: selectedCertKey)
        triggerHaptic(.light)
        showToast("Đang dùng chứng chỉ: \(cert.label)")
    }

    func deleteCertificate(_ cert: CertificateRecord) {
        if let p12 = cert.p12FileName {
            try? FileManager.default.removeItem(at: certsDir.appendingPathComponent(p12))
        }
        if let prov = cert.provisionFileName {
            try? FileManager.default.removeItem(at: certsDir.appendingPathComponent(prov))
        }
        certificates.removeAll { $0.id == cert.id }
        if selectedCertID == cert.id {
            selectedCertID = certificates.first?.id
        }
        persistCertificates()
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

// MARK: - Styling & Glass Modifiers
struct ScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var accent: Color = Color(red: 0/255, green: 185/255, blue: 255/255)

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 16/255, green: 21/255, blue: 34/255).opacity(0.78))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.42))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), accent.opacity(0.18), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, accent: Color = Color(red: 0/255, green: 185/255, blue: 255/255)) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, accent: accent))
    }
}

// MARK: - Aurora Space Background
struct AuroraBackgroundView: View {
    let enabled: Bool
    let theme: ThemeAccent

    private let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.11, 0.07, 2.2, 0.55), (0.84, 0.05, 1.8, 0.45), (0.45, 0.13, 2.5, 0.40),
        (0.22, 0.27, 1.6, 0.35), (0.91, 0.23, 2.4, 0.50), (0.68, 0.18, 1.5, 0.30),
        (0.08, 0.47, 2.0, 0.35), (0.76, 0.41, 2.1, 0.42), (0.35, 0.61, 1.8, 0.30),
        (0.88, 0.67, 2.6, 0.48), (0.16, 0.77, 2.0, 0.38), (0.58, 0.84, 1.7, 0.32)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 6/255, green: 9/255, blue: 17/255),
                    Color(red: 11/255, green: 16/255, blue: 29/255),
                    Color(red: 7/255, green: 11/255, blue: 21/255)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if enabled {
                GeometryReader { geo in
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [theme.primary.opacity(0.24), .clear], center: .center, startRadius: 10, endRadius: 215))
                            .frame(width: 430, height: 430)
                            .position(x: geo.size.width * 0.86, y: geo.size.height * 0.08)

                        Circle()
                            .fill(RadialGradient(colors: [theme.secondary.opacity(0.20), .clear], center: .center, startRadius: 10, endRadius: 220))
                            .frame(width: 440, height: 440)
                            .position(x: geo.size.width * 0.10, y: geo.size.height * 0.46)

                        Circle()
                            .fill(RadialGradient(colors: [theme.primary.opacity(0.14), .clear], center: .center, startRadius: 10, endRadius: 190))
                            .frame(width: 380, height: 380)
                            .position(x: geo.size.width * 0.80, y: geo.size.height * 0.88)

                        ForEach(0..<stars.count, id: \.self) { i in
                            let s = stars[i]
                            Circle()
                                .fill(Color.white.opacity(s.opacity))
                                .frame(width: s.size, height: s.size)
                                .position(x: geo.size.width * s.x, y: geo.size.height * s.y)
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Root ContentView
struct ContentView: View {
    @StateObject private var store = IPAStoreManager()
    @State private var selectedTab: MainTab = .apps
    @State private var selectedApp: AltApp?
    @Namespace private var dockNamespace

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackgroundView(enabled: store.auroraEnabled, theme: store.theme)

            Group {
                switch selectedTab {
                case .apps:
                    AppsExplorerView(
                        store: store,
                        selectedApp: $selectedApp,
                        onOpenCerts: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedTab = .certs }
                        },
                        onOpenRepos: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedTab = .repos }
                        }
                    )
                case .repos:
                    ReposTabView(store: store)
                case .certs:
                    CertificatesTabView(store: store)
                case .library:
                    LibraryTabView(store: store, onOpenCerts: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedTab = .certs }
                    })
                case .settings:
                    SettingsTabView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                if let toast = store.toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(store.theme.primary)
                        Text(toast)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(red: 18/255, green: 24/255, blue: 38/255).opacity(0.95)))
                    .overlay(Capsule().stroke(store.theme.primary.opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                FloatingDockBar(
                    selectedTab: $selectedTab,
                    theme: store.theme,
                    activeDownloadsCount: store.activeDownloads.count,
                    namespace: dockNamespace,
                    onTap: { store.triggerHaptic(.light) }
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app, store: store)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab 1: Apps Explorer v2.2
struct AppsExplorerView: View {
    @ObservedObject var store: IPAStoreManager
    @Binding var selectedApp: AltApp?
    let onOpenCerts: () -> Void
    let onOpenRepos: () -> Void

    @State private var searchText = ""
    @State private var selectedCategory: AppCategory = .all
    @State private var sortMode: AppSortMode = .featured
    @State private var favoritesOnly = false
    @Environment(\.openURL) private var openURL

    var featuredApps: [AltApp] {
        let curated = store.apps.filter { $0.isFeatured }
        return curated.isEmpty ? Array(store.apps.prefix(3)) : curated
    }

    var filteredApps: [AltApp] {
        let base = store.apps.filter { app in
            let matchesFav = !favoritesOnly || store.isFavorite(app)
            let matchesCat = selectedCategory == .all || app.resolvedCategory == selectedCategory
            let matchesSearch = searchText.isEmpty ||
                app.name.localizedCaseInsensitiveContains(searchText) ||
                (app.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (app.developerName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                app.safeBundleID.localizedCaseInsensitiveContains(searchText)
            return matchesFav && matchesCat && matchesSearch
        }

        switch sortMode {
        case .featured: return base
        case .nameAZ: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .sizeDesc: return base.sorted { $0.rawSizeBytes > $1.rawSizeBytes }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                TopHeaderBar(
                    store: store,
                    favoritesOnly: $favoritesOnly,
                    onOpenCerts: onOpenCerts,
                    onOpenRepos: onOpenRepos
                )

                // Brand Title + Glowing Theme Orb
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("TueeHub")
                                .font(.system(size: 34, weight: .heavy, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(colors: [.white, store.theme.primary.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                )
                            Text("v2.2")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(store.theme.primary.opacity(0.22)))
                                .foregroundStyle(store.theme.primary)
                        }
                        Text("Open-Source IPA & Cert Vault")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.52))
                    }

                    Spacer()

                    Button {
                        store.triggerHaptic(.light)
                        withAnimation(.easeInOut(duration: 0.35)) { store.auroraEnabled.toggle() }
                    } label: {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: store.auroraEnabled ? [.white, store.theme.primary, store.theme.secondary] : [.gray.opacity(0.6), .gray.opacity(0.2)],
                                    center: .topLeading,
                                    startRadius: 2,
                                    endRadius: 28
                                )
                            )
                            .frame(width: 40, height: 40)
                            .shadow(color: store.auroraEnabled ? store.theme.primary.opacity(0.55) : .clear, radius: 12)
                    }
                    .buttonStyle(ScalePressStyle())
                }

                // Glass Search + Sort Bar
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))

                        TextField("Tìm game, giả lập, bundle ID...", text: $searchText)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                        }
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 46)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))

                    Menu {
                        ForEach(AppSortMode.allCases) { mode in
                            Button {
                                store.triggerHaptic(.light)
                                sortMode = mode
                            } label: {
                                HStack {
                                    Text(mode.rawValue)
                                    if sortMode == mode { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                }

                // Featured Spotlight Carousel (only when not searching)
                if searchText.isEmpty && !favoritesOnly && selectedCategory == .all {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Spotlight")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.75))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(featuredApps) { app in
                                    FeaturedHeroCard(app: app, theme: store.theme) {
                                        store.triggerHaptic(.light)
                                        selectedApp = app
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Category Chips
                CategoryFilterBar(selectedCategory: $selectedCategory, theme: store.theme) {
                    store.triggerHaptic(.light)
                }

                // Counter Row
                HStack {
                    Text("\(filteredApps.count) apps")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))

                    if favoritesOnly {
                        Text("Favorites")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.pink.opacity(0.22)))
                            .foregroundStyle(.pink)
                    }

                    Spacer()

                    if store.isLoading {
                        ProgressView().tint(store.theme.primary)
                    }
                }

                // App Cards
                if filteredApps.isEmpty {
                    EmptyStateCard(icon: "tray", title: "Không tìm thấy ứng dụng", subtitle: "Thử đổi từ khóa tìm kiếm hoặc thêm nguồn JSON trong tab Repos.")
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(filteredApps) { app in
                            GlassAppCard(
                                app: app,
                                theme: store.theme,
                                isFavorite: store.isFavorite(app),
                                downloadTask: store.activeDownloads[app.id],
                                onSelect: {
                                    store.triggerHaptic(.light)
                                    selectedApp = app
                                },
                                onInstall: {
                                    if app.isDirectIPA {
                                        store.startIPADownload(for: app)
                                    } else if let url = URL(string: app.bestDownloadURL) {
                                        store.triggerHaptic(.medium)
                                        openURL(url)
                                    } else {
                                        selectedApp = app
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 114)
        }
        .refreshable { await store.refreshAll() }
    }
}

struct TopHeaderBar: View {
    @ObservedObject var store: IPAStoreManager
    @Binding var favoritesOnly: Bool
    let onOpenCerts: () -> Void
    let onOpenRepos: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.triggerHaptic(.medium)
                Task { await store.refreshAll() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 42, height: 42)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(store.theme.primary)
                        .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                        .animation(store.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                }
            }
            .buttonStyle(ScalePressStyle())

            // Active Certificate Status Pill
            Button(action: onOpenCerts) {
                HStack(spacing: 6) {
                    let ready = store.activeCertificate?.isReady ?? false
                    Image(systemName: ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ready ? .green : .orange)
                    Text(store.activeCertificate?.label ?? "Chưa nhập chứng chỉ")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(ScalePressStyle())

            Spacer()

            HStack(spacing: 12) {
                Button {
                    store.triggerHaptic(.light)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { favoritesOnly.toggle() }
                } label: {
                    Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(favoritesOnly ? .pink : store.theme.primary)
                }

                Divider().frame(height: 16).background(Color.white.opacity(0.2))

                Button(action: onOpenRepos) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(store.theme.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .padding(.top, 6)
    }
}

struct FeaturedHeroCard: View {
    let app: AltApp
    let theme: ThemeAccent
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GITHUB FEATURED")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.primary.opacity(0.22)))
                    .foregroundStyle(theme.primary)
                Spacer()
                Text(app.bestVersion)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            HStack(spacing: 12) {
                AppIconView(url: app.iconURL, category: app.resolvedCategory, theme: theme, size: 54, radius: 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(app.subtitle ?? app.developerName ?? "Open-source IPA")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 268)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [theme.primary.opacity(0.22), theme.secondary.opacity(0.16), Color(red: 15/255, green: 20/255, blue: 34/255).opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1.1)
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onTap)
    }
}

struct CategoryFilterBar: View {
    @Binding var selectedCategory: AppCategory
    let theme: ThemeAccent
    let onTap: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        onTap()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12, weight: .bold))
                            Text(category.rawValue)
                                .font(.system(size: 13.5, weight: .bold))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .foregroundStyle(isSelected ? .white : Color.white.opacity(0.75))
                        .background(
                            Group {
                                if isSelected {
                                    Capsule().fill(theme.gradient)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.08))
                                }
                            }
                        )
                        .overlay(Capsule().stroke(isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(ScalePressStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct AppIconView: View {
    let url: String?
    let category: AppCategory
    let theme: ThemeAccent
    var size: CGFloat = 62
    var radius: CGFloat = 16

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [theme.primary.opacity(0.38), theme.secondary.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: category.icon)
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

struct GlassAppCard: View {
    let app: AltApp
    let theme: ThemeAccent
    let isFavorite: Bool
    let downloadTask: ActiveDownloadTask?
    let onSelect: () -> Void
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .topTrailing) {
                AppIconView(url: app.iconURL, category: app.resolvedCategory, theme: theme, size: 62, radius: 16)
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.pink)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .offset(x: 4, y: -4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 16.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(app.bestVersion) • \(app.safeBundleID)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)

                Text(app.subtitle ?? app.developerName ?? "Open-source IPA")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.74))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 46/255, green: 213/255, blue: 115/255))
                        .frame(width: 7, height: 7)

                    Text(app.resolvedCategory.rawValue)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(Color.white.opacity(0.88))

                    Text(app.formattedSize)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 4)

            if let dl = downloadTask {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 3.5)
                    Circle()
                        .trim(from: 0, to: CGFloat(dl.progress))
                        .stroke(theme.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(dl.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
            } else {
                Button(action: onInstall) {
                    Text(app.isDirectIPA ? "Get" : "Open")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.gradient))
                        .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(ScalePressStyle())
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 24, accent: theme.primary)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Tab 2: Repos Manager
struct ReposTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var inputURL = ""

    private let quickRepos: [(name: String, url: String)] = [
        ("AltStore Official", "https://apps.altstore.io"),
        ("SideStore Community", "https://community-apps.sidestore.io/sidecommunity.json")
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Repos")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .padding(.top, 10)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Thêm nguồn AltSource JSON")
                        .font(.headline)

                    HStack(spacing: 10) {
                        TextField("https://.../apps.json", text: $inputURL)
                            .font(.system(size: 13.5, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))

                        Button {
                            store.addSource(inputURL)
                            inputURL = ""
                        } label: {
                            Text("Add")
                                .font(.system(size: 14, weight: .bold))
                                .padding(.horizontal, 18)
                                .frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 14).fill(store.theme.gradient))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(ScalePressStyle())
                    }

                    Text("Gợi ý nguồn mở uy tín:")
                        .font(.caption.bold())
                        .foregroundStyle(Color.white.opacity(0.6))

                    HStack(spacing: 8) {
                        ForEach(quickRepos, id: \.url) { item in
                            Button {
                                store.addSource(item.url)
                            } label: {
                                Label(item.name, systemImage: "plus.circle.fill")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(ScalePressStyle())
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 22, accent: store.theme.primary)

                Text("Nguồn đang hoạt động (\(store.sourceURLs.count))")
                    .font(.headline)
                    .foregroundStyle(Color.white.opacity(0.85))

                VStack(spacing: 10) {
                    ForEach(store.sourceURLs, id: \.self) { url in
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.title3)
                                .foregroundStyle(store.theme.primary)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Color.white.opacity(0.08)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(string: url)?.host ?? "JSON Repo")
                                    .font(.subheadline.bold())
                                Text(url)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                store.removeSource(url)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.85))
                                    .padding(8)
                                    .background(Circle().fill(Color.red.opacity(0.14)))
                            }
                        }
                        .padding(14)
                        .glassCard(cornerRadius: 18, accent: store.theme.primary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 114)
        }
    }
}

// MARK: - Tab 3: Certificate Vault (NEW in v2.2)
struct CertificatesTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showImportSheet = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cert Vault")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                        Text("Quản lý chứng chỉ .p12 & .mobileprovision")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer()
                    Button {
                        store.triggerHaptic(.light)
                        showImportSheet = true
                    } label: {
                        Label("Nhập Cert", systemImage: "plus")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(store.theme.gradient))
                    }
                    .buttonStyle(ScalePressStyle())
                }
                .padding(.top, 10)

                if store.certificates.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 44))
                            .foregroundStyle(store.theme.primary)
                        Text("Chưa có chứng chỉ nào")
                            .font(.headline)
                        Text("Nhập file .p12 cùng file .mobileprovision để app tự đọc Team Name, ngày hết hạn và gắn hồ sơ ký mặc định.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Button {
                            showImportSheet = true
                        } label: {
                            Text("Nhập chứng chỉ đầu tiên")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(store.theme.gradient))
                        }
                        .buttonStyle(ScalePressStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .glassCard(cornerRadius: 24, accent: store.theme.primary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(store.certificates) { cert in
                            CertificateCardView(
                                cert: cert,
                                isSelected: store.activeCertificate?.id == cert.id,
                                theme: store.theme,
                                onSelect: { store.selectCertificate(cert) },
                                onDelete: { store.deleteCertificate(cert) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 114)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportCertificateSheet(store: store)
        }
    }
}

struct CertificateCardView: View {
    let cert: CertificateRecord
    let isSelected: Bool
    let theme: ThemeAccent
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    Image(systemName: cert.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(cert.isReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cert.label)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("\(cert.teamName) • \(cert.teamID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                Spacer()
                Text(cert.statusText)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(cert.isReady ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
                    .foregroundStyle(cert.isReady ? .green : .orange)
            }

            HStack(spacing: 12) {
                Label(cert.p12FileName != nil ? ".p12 OK" : "Thiếu .p12", systemImage: "key.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(cert.p12FileName != nil ? theme.primary : .orange)

                Label(cert.provisionFileName != nil ? ".mobileprovision OK" : "Thiếu Provision", systemImage: "doc.badge.gearshape.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(cert.provisionFileName != nil ? theme.primary : .orange)

                Spacer()

                if cert.isEnterprise {
                    Text("Enterprise")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.purple.opacity(0.25)))
                        .foregroundStyle(.purple)
                } else if cert.deviceCount > 0 {
                    Text("Ad-Hoc (\(cert.deviceCount) UDID)")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }

            if let exp = cert.expirationDate {
                Text("Hết hạn: \(exp.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            HStack(spacing: 10) {
                Button(action: onSelect) {
                    Text(isSelected ? "Đang chọn mặc định" : "Chọn làm mặc định")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(
                                isSelected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.white.opacity(0.1))
                            )
                        )
                }
                .buttonStyle(ScalePressStyle())

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(width: 40, height: 34)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(ScalePressStyle())
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 22, accent: isSelected ? theme.primary : .white.opacity(0.3))
    }
}

struct ImportCertificateSheet: View {
    @ObservedObject var store: IPAStoreManager
    @Environment(\.dismiss) private var dismiss

    enum PickerTarget { case p12, provision }

    @State private var label = ""
    @State private var password = ""
    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var pickerTarget: PickerTarget = .p12
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackgroundView(enabled: store.auroraEnabled, theme: store.theme)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tên gợi nhớ (tuỳ chọn)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.white.opacity(0.7))
                            TextField("VD: Chứng chỉ P12 2026 (để trống tự lấy)", text: $label)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. File chứng chỉ (.p12)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.white.opacity(0.7))
                            Button {
                                pickerTarget = .p12
                                showFilePicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "key.fill").foregroundStyle(store.theme.primary)
                                    Text(p12URL?.lastPathComponent ?? "Chọn file .p12 từ app Tệp")
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "folder.fill")
                                }
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.white)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mật khẩu file .p12")
                                .font(.caption.bold())
                                .foregroundStyle(Color.white.opacity(0.7))
                            SecureField("Nhập mật khẩu .p12 (nếu có)", text: $password)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("2. File cấu hình (.mobileprovision)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.white.opacity(0.7))
                            Button {
                                pickerTarget = .provision
                                showFilePicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "doc.badge.gearshape.fill").foregroundStyle(store.theme.primary)
                                    Text(provisionURL?.lastPathComponent ?? "Chọn file .mobileprovision từ app Tệp")
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "folder.fill")
                                }
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.white)
                            }
                        }

                        Button {
                            store.saveNewCertificate(
                                label: label,
                                p12SourceURL: p12URL,
                                provisionSourceURL: provisionURL,
                                password: password
                            )
                            dismiss()
                        } label: {
                            Text("Lưu vào Cert Vault")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 16).fill(store.theme.gradient))
                        }
                        .disabled(p12URL == nil && provisionURL == nil)
                        .opacity((p12URL == nil && provisionURL == nil) ? 0.5 : 1.0)
                        .padding(.top, 8)
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Nhập Chứng Chỉ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    if pickerTarget == .p12 {
                        p12URL = url
                    } else {
                        provisionURL = url
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab 4: Library & Active Downloads
struct LibraryTabView: View {
    @ObservedObject var store: IPAStoreManager
    let onOpenCerts: () -> Void

    @State private var showIPAImporter = false
    @State private var signingItem: LocalIPAItem?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                        Text("Kho file IPA đã tải & nhập vào máy")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer()
                    Button {
                        store.triggerHaptic(.light)
                        showIPAImporter = true
                    } label: {
                        Label("Nhập IPA", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(store.theme.gradient))
                    }
                    .buttonStyle(ScalePressStyle())
                }
                .padding(.top, 10)

                if !store.activeDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Đang tải xuống")
                            .font(.headline)
                        ForEach(Array(store.activeDownloads.values)) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(task.appName).font(.subheadline.bold())
                                    Spacer()
                                    Text("\(Int(task.progress * 100))%")
                                        .font(.caption.monospaced().bold())
                                        .foregroundStyle(store.theme.primary)
                                    Button {
                                        store.cancelDownload(id: task.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.8))
                                    }
                                }
                                ProgressView(value: task.progress)
                                    .tint(store.theme.primary)
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 18, accent: store.theme.primary)
                        }
                    }
                }

                if store.localIPAs.isEmpty {
                    EmptyStateCard(
                        icon: "archivebox",
                        title: "Thư viện IPA trống",
                        subtitle: "Bấm Get ở tab Apps với nguồn JSON có link .ipa trực tiếp, hoặc bấm Nhập IPA để thêm file từ app Tệp."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.localIPAs) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.title2)
                                    .foregroundStyle(store.theme.primary)
                                    .frame(width: 48, height: 48)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.appName)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text("\(item.version) • \(item.formattedSize)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Color.white.opacity(0.6))
                                }

                                Spacer()

                                Button {
                                    store.triggerHaptic(.light)
                                    signingItem = item
                                } label: {
                                    Text("Ký / Cài")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(store.theme.gradient))
                                }
                                .buttonStyle(ScalePressStyle())

                                Button {
                                    store.deleteLocalIPA(item)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.85))
                                        .padding(8)
                                        .background(Circle().fill(Color.red.opacity(0.14)))
                                }
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 20, accent: store.theme.primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 114)
        }
        .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                store.importLocalIPA(from: url)
            }
        }
        .sheet(item: $signingItem) { item in
            SignConfigSheet(item: item, store: store, onNeedCert: {
                signingItem = nil
                onOpenCerts()
            })
        }
    }
}

struct SignConfigSheet: View {
    let item: LocalIPAItem
    @ObservedObject var store: IPAStoreManager
    let onNeedCert: () -> Void
    @Environment(\.
