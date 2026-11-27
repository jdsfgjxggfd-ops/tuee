import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    // Màu nền thẻ nhẹ nhàng kiểu LiveContainer theo từng app
    var cardTint: Color {
        let hash = abs(name.hashValue)
        let palette: [Color] = [
            Color(red: 0.24, green: 0.21, blue: 0.19), // Nâu xám ấm
            Color(red: 0.08, green: 0.24, blue: 0.14), // Xanh lá đậm
            Color(red: 0.30, green: 0.18, blue: 0.11), // Nâu cam đất
            Color(red: 0.12, green: 0.28, blue: 0.18), // Xanh ngọc tối
            Color(red: 0.21, green: 0.19, blue: 0.34), // Tím trầm
            Color(red: 0.14, green: 0.20, blue: 0.28)  // Xanh dương trầm
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
        if p12FileName == nil || provisionFileName == nil { return "Thiếu file" }
        if isExpired { return "Hết hạn" }
        if let days = daysRemaining { return "Còn \(days) ngày" }
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
    case all = "Tất cả"
    case emu = "EMU"
    case ports = "Ports"
    case sideload = "Sideloading"
    case games = "Games"
    case tools = "Tools"

    var id: String { rawValue }
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

// MARK: - Store Manager
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
    @Published var alertMessage: String?

    @Published var hapticsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: hapticsKey) }
    }

    private let sourcesKey = "TueeHub_v22_Sources"
    private let favoritesKey = "TueeHub_v22_Favorites"
    private let certsKey = "TueeHub_v22_Certs"
    private let selectedCertKey = "TueeHub_v22_SelectedCert"
    private let localIPAsKey = "TueeHub_v22_LocalIPAs"
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
        sourceURLs = UserDefaults.standard.stringArray(forKey: sourcesKey) ?? ["https://apps.altstore.io"]
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
                bundleID: meta?.bundleID ?? "com.tueehub.imported",
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
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        if !sourceURLs.contains(trimmed) {
            triggerHaptic(.medium)
            sourceURLs.append(trimmed)
            UserDefaults.standard.set(sourceURLs, forKey: sourcesKey)
            Task { await refreshAll() }
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
                alertMessage = "Không đồng bộ được nguồn: \(url.host ?? urlString)"
            }
        }

        apps = combined
        isLoading = false
    }

    func startIPADownload(for app: AltApp) {
        guard let url = URL(string: app.bestDownloadURL), !app.bestDownloadURL.isEmpty else { return }
        if activeDownloads[app.id] != nil { return }

        triggerHaptic(.medium)
        activeDownloads[app.id] = ActiveDownloadTask(
            id: app.id,
            appName: app.name,
            version: app.bestVersion,
            bundleID: app.safeBundleID,
            progress: 0.02,
            writtenBytes: 0,
            totalBytes: app.rawSizeBytes
        )

        let task = downloadSession.downloadTask(with: url)
        task.taskDescription = app.id
        runningTasks[app.id] = task
        task.resume()
    }

    func cancelDownload(id: String) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
    }

    func importLocalIPA(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "ipa" else {
            alertMessage = "Vui lòng chọn đúng file đuôi .ipa"
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
        } catch {
            alertMessage = "Lỗi nhập IPA: \(error.localizedDescription)"
        }
    }

    func urlForLocalIPA(_ item: LocalIPAItem) -> URL {
        ipasDir.appendingPathComponent(item.fileName)
    }

    func deleteLocalIPA(at offsets: IndexSet) {
        for idx in offsets {
            let item = localIPAs[idx]
            try? FileManager.default.removeItem(at: urlForLocalIPA(item))
        }
        localIPAs.remove(atOffsets: offsets)
        persistLocalIPAs()
    }

    private func persistLocalIPAs() {
        if let encoded = try? JSONEncoder().encode(localIPAs) {
            UserDefaults.standard.set(encoded, forKey: localIPAsKey)
        }
    }

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

        if finalLabel.isEmpty { finalLabel = "Chứng chỉ #\(certificates.count + 1)" }

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

// MARK: - Root ContentView (100% Native iOS TabView)
struct ContentView: View {
    @StateObject private var store = IPAStoreManager()

    var body: some View {
        TabView {
            AppsTabView(store: store)
                .tabItem {
                    Label("Apps", systemImage: "square.stack.3d.up.fill")
                }

            ReposTabView(store: store)
                .tabItem {
                    Label("Sources", systemImage: "books.vertical.fill")
                }

            CertsTabView(store: store)
                .tabItem {
                    Label("Certs", systemImage: "checkmark.seal.fill")
                }

            LibraryTabView(store: store)
                .tabItem {
                    Label("Library", systemImage: "arrow.down.circle.fill")
                }
                .badge(store.activeDownloads.count)

            SettingsTabView(store: store)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .preferredColorScheme(.dark)
        .alert("Thông báo", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

// MARK: - Tab 1: Apps (Phong cách LiveContainer / iOS gốc)
struct AppsTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var searchText = ""
    @State private var selectedCategory: AppCategory = .all
    @State private var favoritesOnly = false
    @State private var selectedApp: AltApp?
    @Environment(\.openURL) private var openURL

    var filteredApps: [AltApp] {
        store.apps.filter { app in
            let matchesFav = !favoritesOnly || store.isFavorite(app)
            let matchesCat = selectedCategory == .all || app.resolvedCategory == selectedCategory
            let matchesSearch = searchText.isEmpty ||
                app.name.localizedCaseInsensitiveContains(searchText) ||
                (app.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                app.safeBundleID.localizedCaseInsensitiveContains(searchText)
            return matchesFav && matchesCat && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Dải lọc danh mục tối giản chuẩn iOS
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AppCategory.allCases) { cat in
                                let isSelected = selectedCategory == cat
                                Button {
                                    store.triggerHaptic(.light)
                                    selectedCategory = cat
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

                    // Danh sách thẻ App kiểu LiveContainer
                    LazyVStack(spacing: 12) {
                        ForEach(filteredApps) { app in
                            NativeAppCard(
                                app: app,
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
                    .padding(.bottom, 16)

                    Text("\(filteredApps.count) apps total")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                }
                .padding(.top, 4)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("My Apps")
            .searchable(text: $searchText, prompt: "Tìm ứng dụng, bundle ID...")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                            .foregroundStyle(favoritesOnly ? .pink : .primary)
                    }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailSheet(app: app, store: store)
            }
        }
    }
}

struct NativeAppCard: View {
    let app: AltApp
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
                        Color.white.opacity(0.12)
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                }

                Text("\(app.bestVersion) - \(app.safeBundleID)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Text(app.subtitle ?? app.sourceName ?? "GitHub Official")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if let dl = downloadTask {
                ProgressView(value: dl.progress)
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .frame(width: 64)
            } else {
                Button(action: onAction) {
                    Text(app.isDirectIPA ? "Get" : "Open")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 34)
                        .background(app.buttonTint)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(app.cardTint)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Tab 2: Sources (Native InsetGrouped List)
struct ReposTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showAddAlert = false
    @State private var newRepoURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Nguồn AltSource JSON") {
                    ForEach(store.sourceURLs, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(string: url)?.host ?? "JSON Repo")
                                .font(.headline)
                            Text(url)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onDelete(perform: store.removeSource)
                }

                Section("Thêm nhanh nguồn phổ biến") {
                    Button("AltStore Official") {
                        store.addSource("https://apps.altstore.io")
                    }
                    Button("SideStore Community") {
                        store.addSource("https://community-apps.sidestore.io/sidecommunity.json")
                    }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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

// MARK: - Tab 3: Cert Vault (Native List)
struct CertsTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showImportSheet = false

    var body: some View {
        NavigationStack {
            List {
                if store.certificates.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Chưa có chứng chỉ")
                                .font(.headline)
                            Text("Bấm dấu + ở góc trên để nhập file .p12 và .mobileprovision.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section("Chứng chỉ đã lưu") {
                        ForEach(store.certificates) { cert in
                            Button {
                                store.selectCertificate(cert)
                            } label: {
                                HStack {
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
            .navigationTitle("Certificates")
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
            Form {
                Section("Thông tin") {
                    TextField("Tên gợi nhớ (tùy chọn)", text: $label)
                    SecureField("Mật khẩu file .p12", text: $password)
                }

                Section("Tệp chứng chỉ") {
                    Button {
                        pickerTarget = .p12
                        showFilePicker = true
                    } label: {
                        HStack {
                            Label("Chọn file .p12", systemImage: "key.fill")
                            Spacer()
                            Text(p12URL?.lastPathComponent ?? "Chưa chọn")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Button {
                        pickerTarget = .provision
                        showFilePicker = true
                    } label: {
                        HStack {
                            Label("Chọn .mobileprovision", systemImage: "doc.badge.gearshape")
                            Spacer()
                            Text(provisionURL?.lastPathComponent ?? "Chưa chọn")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
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
                    .disabled(p12URL == nil && provisionURL == nil)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    if pickerTarget == .p12 { p12URL = url } else { provisionURL = url }
                }
            }
        }
    }
}

// MARK: - Tab 4: Library (Native List)
struct LibraryTabView: View {
    @ObservedObject var store: IPAStoreManager
    @State private var showIPAImporter = false
    @State private var signingItem: LocalIPAItem?

    var body: some View {
        NavigationStack {
            List {
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
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Kho IPA trong máy (\(store.localIPAs.count))") {
                    if store.localIPAs.isEmpty {
                        Text("Chưa có file IPA nào. Bấm dấu + để nhập từ Tệp hoặc tải từ tab Apps.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.localIPAs) { item in
                            Button {
                                signingItem = item
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.appName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("\(item.version) • \(item.formattedSize)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Ký / Cài")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.18))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .onDelete(perform: store.deleteLocalIPA)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showIPAImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    store.importLocalIPA(from: url)
                }
            }
            .sheet(item: $signingItem) { item in
                SignConfigSheet(item: item, store: store)
            }
        }
    }
}

struct SignConfigSheet: View {
    let item: LocalIPAItem
    @ObservedObject var store: IPAStoreManager
    @Environment(\.dismiss) private var dismiss

    @State private var customName = ""
    @State private var customBundleID = ""
    @State private var enableFileSharing = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Chứng chỉ đang chọn") {
                    if let cert = store.activeCertificate {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cert.label).font(.headline)
                            Text("\(cert.teamName) • \(cert.statusText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Chưa có chứng chỉ trong tab Certs")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Tùy chỉnh gói") {
                    TextField("Tên ứng dụng", text: $customName)
                    TextField("Bundle ID", text: $customBundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Bật Chia sẻ tệp", isOn: $enableFileSharing)
                }

                Section {
                    ShareLink(item: store.urlForLocalIPA(item)) {
                        Label("Gửi sang Feather / LiveContainer / SideStore", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } footer: {
                    Text("Chọn Feather, SideStore hoặc LiveContainer trong bảng chia sẻ để ký và cài đặt ngay.")
                }
            }
            .navigationTitle(item.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
            .onAppear {
                customName = item.appName
                customBundleID = item.bundleID
            }
        }
    }
}

// MARK: - Tab 5: Settings (Native Form)
struct SettingsTabView: View {
    @ObservedObject var store: IPAStoreManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Tùy chọn") {
                    Toggle("Phản hồi rung (Haptics)", isOn: $store.hapticsEnabled)
                }

                Section("Thống kê") {
                    LabeledContent("Ứng dụng", value: "\(store.apps.count)")
                    LabeledContent("Nguồn JSON", value: "\(store.sourceURLs.count)")
                    LabeledContent("Chứng chỉ", value: "\(store.certificates.count)")
                    LabeledContent("File IPA trong máy", value: "\(store.localIPAs.count)")
                }

                Section("Thông tin") {
                    LabeledContent("Ứng dụng", value: "TueeHub")
                    LabeledContent("Phiên bản", value: "2.2 Native")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - App Detail Sheet (Native Form)
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
                                Color.gray.opacity(0.3)
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
