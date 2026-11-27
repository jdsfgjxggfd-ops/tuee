import SwiftUI

// MARK: - Models (Chuẩn AltSource JSON)
struct AltSource: Codable {
    let name: String
    let identifier: String?
    let apps: [AltApp]
}

struct AltAppVersion: Codable {
    let version: String
    let downloadURL: String
    let size: Int64?
}

struct AltApp: Codable, Identifiable {
    var id: String { "\(bundleIdentifier)-\(name)" }
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let localizedDescription: String?
    let iconURL: String?
    let downloadURL: String?
    let version: String?
    let size: Int64?
    let versions: [AltAppVersion]?
    var sourceName: String?

    var bestDownloadURL: String {
        versions?.first?.downloadURL ?? downloadURL ?? ""
    }

    var bestVersion: String {
        versions?.first?.version ?? version ?? "1.0"
    }

    var formattedSize: String {
        let bytes = versions?.first?.size ?? size ?? 0
        if bytes <= 0 { return "IPA" }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription
        case iconURL, downloadURL, version, size, versions
    }
}

// MARK: - Store Manager
@MainActor
class IPAStoreManager: ObservableObject {
    @Published var apps: [AltApp] = []
    @Published var sourceURLs: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let savedSourcesKey = "SavedIPASourceURLs_v1"

    // Danh sách game & giả lập mã nguồn mở uy tín trên GitHub (có sẵn)
    let featuredGitHubApps: [AltApp] = [
        AltApp(
            name: "PojavLauncher",
            bundleIdentifier: "net.kdt.pojavlaunch",
            developerName: "PojavLauncherTeam",
            subtitle: "Minecraft Java Edition bản PC trên iOS",
            localizedDescription: "Chạy thẳng Minecraft Java Edition từ GitHub chính chủ, hỗ trợ Fabric, Forge và shader. Cần bật JIT.",
            iconURL: "https://raw.githubusercontent.com/PojavLauncherTeam/PojavLauncher_iOS/main/Natives/Assets.xcassets/AppIcon-Default.appiconset/AppIcon-Default-1024.png",
            downloadURL: "https://github.com/PojavLauncherTeam/PojavLauncher_iOS/releases",
            version: "GitHub",
            size: nil,
            versions: nil,
            sourceName: "GitHub Official"
        ),
        AltApp(
            name: "DolphiniOS",
            bundleIdentifier: "me.oatmealdome.dolphinios",
            developerName: "OatmealDome",
            subtitle: "Giả lập GameCube & Wii 60 FPS",
            localizedDescription: "Trình giả lập GameCube và Wii mã nguồn mở mượt nhất cho iOS. Hỗ trợ tay cầm và xuất màn hình ngoài.",
            iconURL: "https://raw.githubusercontent.com/OatmealDome/dolphin-ios/master/Source/iOS/App/DolphiniOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            downloadURL: "https://github.com/OatmealDome/dolphin-ios/releases",
            version: "GitHub",
            size: nil,
            versions: nil,
            sourceName: "GitHub Official"
        ),
        AltApp(
            name: "Delta Emulator",
            bundleIdentifier: "com.rileytestut.Delta",
            developerName: "Riley Testut",
            subtitle: "Giả lập NES, SNES, N64, GBC, GBA, DS",
            localizedDescription: "Trình giả lập đa hệ máy Nintendo mã nguồn mở, hỗ trợ cheat code, skin tay cầm và đồng bộ save.",
            iconURL: "https://raw.githubusercontent.com/rileytestut/Delta/main/Delta/Assets.xcassets/AppIcon.appiconset/Icon-1024.png",
            downloadURL: "https://github.com/rileytestut/Delta/releases",
            version: "GitHub",
            size: nil,
            versions: nil,
            sourceName: "GitHub Official"
        ),
        AltApp(
            name: "PPSSPP",
            bundleIdentifier: "org.ppsspp.ppsspp",
            developerName: "hrydgard",
            subtitle: "Giả lập PSP độ phân giải cao",
            localizedDescription: "Chơi game PSP (God of War, Pes, GTA...) với đồ họa nâng cấp HD và hỗ trợ tay cầm Bluetooth.",
            iconURL: "https://raw.githubusercontent.com/hrydgard/ppsspp/master/icons/icon-512.png",
            downloadURL: "https://github.com/hrydgard/ppsspp/releases",
            version: "GitHub",
            size: nil,
            versions: nil,
            sourceName: "GitHub Official"
        ),
        AltApp(
            name: "UTM",
            bundleIdentifier: "com.utmapp.UTM",
            developerName: "utmapp",
            subtitle: "Chạy máy ảo Windows & Linux trên iOS",
            localizedDescription: "Máy ảo mã nguồn mở cho phép cài đặt và chạy Windows, Ubuntu, Arch Linux ngay trên iPhone.",
            iconURL: "https://raw.githubusercontent.com/utmapp/UTM/main/Platform/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon1024x1024.png",
            downloadURL: "https://github.com/utmapp/UTM/releases",
            version: "GitHub",
            size: nil,
            versions: nil,
            sourceName: "GitHub Official"
        )
    ]

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: savedSourcesKey) {
            self.sourceURLs = saved
        } else {
            // Nguồn JSON mẫu uy tín mặc định (SideStore / AltStore Official)
            self.sourceURLs = [
                "https://apps.altstore.io"
            ]
        }
        Task { await refreshAll() }
    }

    func addSource(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        if !sourceURLs.contains(trimmed) {
            sourceURLs.append(trimmed)
            UserDefaults.standard.set(sourceURLs, forKey: savedSourcesKey)
            Task { await refreshAll() }
        }
    }

    func removeSource(at offsets: IndexSet) {
        sourceURLs.remove(atOffsets: offsets)
        UserDefaults.standard.set(sourceURLs, forKey: savedSourcesKey)
        Task { await refreshAll() }
    }

    func refreshAll() async {
        isLoading = true
        errorMessage = nil
        var loadedApps: [AltApp] = featuredGitHubApps

        for urlStr in sourceURLs {
            guard let url = URL(string: urlStr) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(AltSource.self, from: data)
                let tagged = decoded.apps.map { app -> AltApp in
                    var copy = app
                    copy.sourceName = decoded.name
                    return copy
                }
                loadedApps.append(contentsOf: tagged)
            } catch {
                errorMessage = "Không đọc được 1 nguồn JSON: \(urlStr)"
            }
        }

        self.apps = loadedApps
        self.isLoading = false
    }
}

// MARK: - Main View
struct ContentView: View {
    @StateObject private var store = IPAStoreManager()
    @State private var searchText = ""
    @State private var selectedApp: AltApp?
    @State private var showAddSource = false
    @State private var newSourceURL = ""

    var filteredApps: [AltApp] {
        if searchText.isEmpty { return store.apps }
        return store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.developerName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        TabView {
            // TAB 1: KHO GAME IPA
            NavigationStack {
                List {
                    if store.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Đang đồng bộ kho IPA...")
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }

                    ForEach(filteredApps) { app in
                        Button {
                            selectedApp = app
                        } label: {
                            AppRowView(app: app)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Kho IPA")
                .searchable(text: $searchText, prompt: "Tìm game, giả lập, dev...")
                .refreshable {
                    await store.refreshAll()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await store.refreshAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .sheet(item: $selectedApp) { app in
                    AppDetailSheet(app: app)
                }
            }
            .tabItem {
                Label("Kho Game", systemImage: "gamecontroller.fill")
            }

            // TAB 2: QUẢN LÝ NGUỒN JSON
            NavigationStack {
                List {
                    Section {
                        ForEach(store.sourceURLs, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(string: url)?.host ?? "Nguồn JSON")
                                    .font(.headline)
                                Text(url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .onDelete(perform: store.removeSource)
                    } header: {
                        Text("Nguồn AltSource JSON đang bật")
                    } footer: {
                        Text("Dán link file .json từ GitHub (chuẩn AltStore / SideStore / Feather) để app tự động cập nhật thêm game.")
                    }

                    if let err = store.errorMessage {
                        Section("Thông báo") {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle("Nguồn IPA")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAddSource = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
                .alert("Thêm nguồn JSON mới", isPresented: $showAddSource) {
                    TextField("https://.../apps.json", text: $newSourceURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Thêm") {
                        store.addSource(newSourceURL)
                        newSourceURL = ""
                    }
                    Button("Hủy", role: .cancel) { newSourceURL = "" }
                } message: {
                    Text("Nhập đường dẫn trực tiếp đến file JSON kho IPA uy tín.")
                }
            }
            .tabItem {
                Label("Nguồn", systemImage: "tray.full.fill")
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Row View
struct AppRowView: View {
    let app: AltApp

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.blue.opacity(0.2))
                        Image(systemName: "app.dashed").foregroundStyle(.blue)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(app.subtitle ?? app.developerName ?? "Open Source")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(app.bestVersion)")
                    Text("•")
                    Text(app.sourceName ?? "GitHub")
                }
                .font(.caption2)
                .foregroundStyle(.blue)
            }

            Spacer()

            Text("Tải")
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.2))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail Sheet
struct AppDetailSheet: View {
    let app: AltApp
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                RoundedRectangle(cornerRadius: 18).fill(.blue.opacity(0.2))
                            }
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.title2.bold())
                            Text(app.developerName ?? "Unknown Developer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Phiên bản \(app.bestVersion) • \(app.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let url = URL(string: app.bestDownloadURL) {
                                openURL(url)
                            }
                        } label: {
                            Label("Tải / Mở GitHub", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.bestDownloadURL.isEmpty)

                        Button {
                            UIPasteboard.general.string = app.bestDownloadURL
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.headline)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Giới thiệu")
                            .font(.headline)
                        Text(app.localizedDescription ?? app.subtitle ?? "Không có mô tả chi tiết.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thông tin kỹ thuật")
                            .font(.headline)
                        Text("Bundle ID: \(app.bundleIdentifier)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Nguồn: \(app.sourceName ?? "GitHub")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Chi tiết IPA")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
