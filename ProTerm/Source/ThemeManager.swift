import SwiftUI          // Color, ObservableObject (re‑exports Combine)
import Combine           // needed for @Published’s synthesized initializer
import AppKit            // NSColor – used to extract RGBA components from a SwiftUI Color

/* ---------- Helper that makes `Color` codable ---------- */
private struct CodableColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ color: Color) {
        // Convert SwiftUI `Color` → `NSColor` in a safe RGB color space.
        // Accessing NSColor's .redComponent/.greenComponent/.blueComponent on a non-RGB color space
        // can crash. Always convert to sRGB or deviceRGB first.
        let ns = NSColor(color)
        let rgb = ns.usingColorSpace(.sRGB) ?? ns.usingColorSpace(.deviceRGB) ?? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.red   = rgb.redComponent
        self.green = rgb.greenComponent
        self.blue  = rgb.blueComponent
        self.alpha = rgb.alphaComponent
    }

    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }
}

/* ---------- Theme model (now truly Codable) ---------- */
struct Theme: Codable, Equatable {
    var background: Color = .black
    var foreground: Color = .green
    var cursor:     Color = .white

    // Custom coding to translate `Color` ↔︎ `CodableColor`.
    enum CodingKeys: String, CodingKey {
        case background, foreground, cursor
    }

    init(background: Color = .black,
         foreground: Color = .green,
         cursor: Color = .white) {
        self.background = background
        self.foreground = foreground
        self.cursor     = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bg  = try container.decode(CodableColor.self, forKey: .background).color
        let fg  = try container.decode(CodableColor.self, forKey: .foreground).color
        let cur = try container.decode(CodableColor.self, forKey: .cursor).color
        self.background = bg
        self.foreground = fg
        self.cursor     = cur
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CodableColor(background), forKey: .background)
        try container.encode(CodableColor(foreground), forKey: .foreground)
        try container.encode(CodableColor(cursor),    forKey: .cursor)
    }
}

/* ---------- Manager that the UI observes ---------- */
@MainActor
final class ThemeManager: ObservableObject {
    // Stored, published property – changes now correctly propagate.
    @Published var current: Theme = Theme() {
        didSet { saveThemeSnapshot() }
    }
    
    @Published private(set) var profiles: [AppearanceProfile]
    @Published private(set) var activeProfileID: UUID
    @Published var syncProfilesToICloud: Bool = false {
        didSet {
            UserDefaults.standard.set(syncProfilesToICloud, forKey: defaultsKeyProfileSync)
            if syncProfilesToICloud {
                startICloudObserver()
                pushProfilesToICloud()
            } else {
                stopICloudObserver()
            }
        }
    }
    
    private weak var fontManager: FontManager?
    
    private let defaultsKeyTheme = "ProTermSelectedTheme"
    private let defaultsKeyProfileID = "ProTermSelectedProfileID"
    private let defaultsKeyProfiles = "ProTermAppearanceProfiles"
    private let defaultsKeyProfileSync = "ProTermProfileSyncEnabled"
    private let ubiquitousProfilesKey = "ProTermProfilesArchive"
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let iCloudStore = NSUbiquitousKeyValueStore.default
    private var iCloudObserver: NSObjectProtocol?
    
    init() {
        let storedProfiles: [AppearanceProfile]
        let diskURL: URL = {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
            let directory = support.appendingPathComponent("ProTerm", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("Profiles.json", isDirectory: false)
        }()
        if let diskData = try? Data(contentsOf: diskURL),
           let decoded = try? decoder.decode([AppearanceProfile].self, from: diskData),
           !decoded.isEmpty {
            storedProfiles = decoded
        } else if let data = UserDefaults.standard.data(forKey: defaultsKeyProfiles),
                  let decoded = try? decoder.decode([AppearanceProfile].self, from: data),
                  !decoded.isEmpty {
            storedProfiles = decoded
        } else {
            storedProfiles = AppearanceProfile.builtIn
        }
        let deduped = Self.deduplicatedProfiles(from: storedProfiles)
        profiles = deduped
        
        if let idString = UserDefaults.standard.string(forKey: defaultsKeyProfileID),
           let savedID = UUID(uuidString: idString),
           deduped.contains(where: { $0.id == savedID }) {
            activeProfileID = savedID
        } else {
            activeProfileID = deduped.first?.id ?? AppearanceProfile.builtIn.first!.id
        }
        
        if let activeTheme = deduped.first(where: { $0.id == activeProfileID })?.theme {
            current = activeTheme
        } else if let data = UserDefaults.standard.data(forKey: defaultsKeyTheme),
                  let decoded = try? decoder.decode(Theme.self, from: data) {
            current = decoded
        } else {
            current = deduped.first?.theme ?? Theme()
        }
        
        writeProfilesToDisk(at: diskURL)
        
        syncProfilesToICloud = UserDefaults.standard.object(forKey: defaultsKeyProfileSync) as? Bool ?? false
        if syncProfilesToICloud {
            startICloudObserver()
            pullProfilesFromICloudIfAvailable()
        }
    }
    
    deinit {
        Task { @MainActor [weak self] in
            self?.stopICloudObserver()
        }
    }
    
    var activeProfile: AppearanceProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? AppearanceProfile.builtIn.first!
    }
    
    func attachFontManager(_ manager: FontManager) {
        fontManager = manager
        syncFontManagerWithActiveProfile()
    }
    
    func selectProfile(_ profile: AppearanceProfile) {
        guard profile.id != activeProfileID else { return }
        activeProfileID = profile.id
        current = profile.theme
        persistSelection()
        syncFontManagerWithActiveProfile()
    }
    
    func duplicateProfile(_ profile: AppearanceProfile? = nil) {
        let source = profile ?? activeProfile
        var copy = source
        copy.id = UUID()
        copy.kind = .custom
        copy.name = uniqueName(basedOn: source.name)
        copy.backgroundMaterial = source.backgroundMaterial
        profiles.append(copy)
        selectProfile(copy)
        persistProfiles()
    }
    
    func deleteProfile(_ profile: AppearanceProfile) {
        guard profile.isCustom else { return }
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles.first?.id ?? AppearanceProfile.builtIn.first!.id
            current = activeProfile.theme
            syncFontManagerWithActiveProfile()
        }
        persistProfiles()
        persistSelection()
    }
    
    func renameActiveProfile(to newName: String) {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateActiveProfile { profile in
            profile.name = newName
        }
    }
    
    func renameActiveProfileAsync(to newName: String) {
        Task { @MainActor [weak self] in
            self?.renameActiveProfile(to: newName)
        }
    }
    
    func updateActiveProfile(_ transform: (inout AppearanceProfile) -> Void) {
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            var profile = profiles[index]
            if profile.kind == .builtIn {
                var customCopy = profile
                customCopy.id = UUID()
                customCopy.kind = .custom
                customCopy.name = uniqueName(basedOn: "\(profile.name) Custom")
                transform(&customCopy)
                profiles.append(customCopy)
                activeProfileID = customCopy.id
                current = customCopy.theme
            } else {
                transform(&profile)
                profiles[index] = profile
                current = profile.theme
            }
        } else {
            var profile = activeProfile
            transform(&profile)
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
            current = profile.theme
        }
        persistProfiles()
        persistSelection()
        syncFontManagerWithActiveProfile()
    }
    
    func createCustomProfile() {
        let profile = AppearanceProfile(
            name: uniqueName(basedOn: "Custom Profile"),
            theme: Theme(background: .black, foreground: Color(red: 0.0, green: 0.9, blue: 0.0), cursor: .white),
            fontName: "SF Mono",
            fontSize: 13,
            backgroundMaterial: .solid,
            backgroundOpacity: 1.0,
            cornerRadius: 16,
            horizontalPadding: 20,
            verticalPadding: 16,
            kind: .custom
        )
        profiles.append(profile)
        selectProfile(profile)
        persistProfiles()
    }
    
    func resetProfilesToDefaults() {
        profiles = AppearanceProfile.builtIn
        activeProfileID = profiles.first?.id ?? UUID()
        current = profiles.first?.theme ?? Theme()
        persistProfiles()
        syncFontManagerWithActiveProfile()
    }
    
    func exportProfiles(to url: URL) throws {
        let data = try encoder.encode(profiles)
        try data.write(to: url, options: .atomic)
    }
    
    func importProfiles(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try decoder.decode([AppearanceProfile].self, from: data)
        guard !decoded.isEmpty else { return }
        profiles = Self.deduplicatedProfiles(from: decoded)
        activeProfileID = profiles.first?.id ?? UUID()
        current = profiles.first?.theme ?? Theme()
        persistProfiles()
        syncFontManagerWithActiveProfile()
    }
    
    func updateActiveProfileFont(name: String? = nil, size: Double? = nil) {
        updateActiveProfile { profile in
            if let name = name { profile.fontName = name }
            if let size = size { profile.fontSize = size }
        }
    }
    
    func updateActiveProfileAsync(_ transform: @escaping (inout AppearanceProfile) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateActiveProfile(transform)
        }
    }
    
    func updateActiveProfileFontAsync(name: String? = nil, size: Double? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateActiveProfileFont(name: name, size: size)
        }
    }
    
    // MARK: - Persistence
    
    private func persistProfiles() {
        if let data = try? encoder.encode(profiles) {
            UserDefaults.standard.set(data, forKey: defaultsKeyProfiles)
        }
        writeProfilesToDisk()
        pushProfilesToICloud()
    }
    
    private func persistSelection() {
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: defaultsKeyProfileID)
    }
    
    private func saveThemeSnapshot() {
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: defaultsKeyTheme)
        }
    }
    
    private func syncFontManagerWithActiveProfile() {
        let profile = activeProfile
        if fontManager?.fontName != profile.fontName {
            fontManager?.fontName = profile.fontName
        }
        if fontManager?.fontSize != profile.fontSize {
            fontManager?.fontSize = profile.fontSize
        }
    }
    
    private func uniqueName(basedOn base: String) -> String {
        var candidate = base
        var suffix = 2
        while profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
    
    private var profilesArchiveURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = support.appendingPathComponent("ProTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Profiles.json", isDirectory: false)
    }
    
    private func writeProfilesToDisk(at url: URL? = nil) {
        let target = url ?? profilesArchiveURL
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: target, options: .atomic)
        }
    }
    
    private func startICloudObserver() {
        guard iCloudObserver == nil else { return }
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor [weak self] in
                guard let self, self.syncProfilesToICloud else { return }
                guard let reason, reason == NSUbiquitousKeyValueStoreServerChange else { return }
                self.pullProfilesFromICloudIfAvailable()
            }
        }
        iCloudStore.synchronize()
    }
    
    private func stopICloudObserver() {
        if let token = iCloudObserver {
            NotificationCenter.default.removeObserver(token)
            iCloudObserver = nil
        }
    }
    
    private func pushProfilesToICloud() {
        guard syncProfilesToICloud, let data = try? encoder.encode(profiles) else { return }
        iCloudStore.set(data, forKey: ubiquitousProfilesKey)
        iCloudStore.synchronize()
    }
    
    private func pullProfilesFromICloudIfAvailable() {
        guard let data = iCloudStore.data(forKey: ubiquitousProfilesKey),
              let decoded = try? decoder.decode([AppearanceProfile].self, from: data),
              !decoded.isEmpty else { return }
        profiles = Self.deduplicatedProfiles(from: decoded)
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id ?? UUID()
        }
        current = profiles.first(where: { $0.id == activeProfileID })?.theme ?? profiles.first?.theme ?? current
        persistSelection()
        writeProfilesToDisk()
        syncFontManagerWithActiveProfile()
    }

    private static func deduplicatedProfiles(from profiles: [AppearanceProfile]) -> [AppearanceProfile] {
        var seen = Set<String>()
        return profiles.filter { profile in
            let key = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }
}
