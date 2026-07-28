import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "5378e8f"
    static var label: String { "\(version)+\(gitSHA)" }
}
