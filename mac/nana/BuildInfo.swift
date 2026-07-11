import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "ebfb302"
    static var label: String { "\(version)+\(gitSHA)" }
}
