import XCTest
@testable import ProTerm

final class AppearanceProfileTests: XCTestCase {
    func testAppearanceProfileCodableRoundTrip() throws {
        let profile = AppearanceProfile(
            name: "Test",
            theme: Theme(background: .orange, foreground: .blue, cursor: .pink),
            fontName: "SF Mono",
            fontSize: 15,
            backgroundMaterial: .vibrantDark,
            backgroundOpacity: 0.6,
            cornerRadius: 18,
            horizontalPadding: 24,
            verticalPadding: 20,
            kind: .custom
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppearanceProfile.self, from: data)
        
        XCTAssertEqual(profile, decoded)
        XCTAssertEqual(decoded.paddingInsets.leading, profile.paddingInsets.leading, accuracy: 0.01)
    }
    
    func testBuiltInProfilesAreUniqueAndNonEmpty() {
        let profiles = AppearanceProfile.builtIn
        XCTAssertFalse(profiles.isEmpty, "Built-in profiles should always exist")
        
        let ids = Set(profiles.map(\.id))
        XCTAssertEqual(ids.count, profiles.count, "Profile identifiers must be unique")
        
        for profile in profiles {
            XCTAssertFalse(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}





