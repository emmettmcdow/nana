import Foundation

enum BuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let gitSHA = "0ecd066"
    static var label: String { "\(version)+\(gitSHA)" }
}
