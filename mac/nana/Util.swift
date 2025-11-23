import SwiftUI

#if DISABLE_NANAKIT
    private func nana_import(_: UnsafePointer<Int8>, _: Bool, _: Bool) -> Int32 {
        return 1 // Success
    }
#else
    import NanaKit
#endif

struct ImportResult {
    var filename: String
    var message: String
}

enum ImportStatus {
    case success
    case skip
    case fail
}

/// Imports a list of files using `nana_import`.
///
/// - Parameters:
///   - files: Array of file path strings to import.
///   - copy: Whether the files need to be copied, or if they can be left in place.
///   - addExt: Whether the numbered files with a missing extension should have an extension added.
///   - onProgress: Called on MainActor when a file is processed. Receives (completeCount, skippedCount).
/// - Returns: `true` if all files imported successfully, `false` if an error occurred.
@MainActor
func importFiles(
    _ files: [String],
    copy: Bool,
    addExt: Bool,
    onProgress: @escaping (_ complete: [ImportResult],
                           _ skipped: [ImportResult],
                           _ errored: [ImportResult]) -> Void
) async {
    var completeFiles: [ImportResult] = []
    var skippedFiles: [ImportResult] = []
    var erroredFiles: [ImportResult] = []

    for fileURL in files {
        let res = fileURL.withCString { cString in
            nana_import(cString, copy, addExt)
        }

        if res > 0 {
            completeFiles.append(contentsOf: [ImportResult(filename: fileURL, message: "")])
        } else if res == -13 {
            skippedFiles.append(contentsOf: [ImportResult(filename: fileURL,
                                                          message: "File isn't a note.")])
        } else {
            erroredFiles.append(contentsOf: [ImportResult(filename: fileURL,
                                                          message: "Failed to import note with error: \(res)")])
        }
        onProgress(completeFiles, skippedFiles, erroredFiles)
    }
}

struct ImportReport: View {
    var status: ImportStatus
    var files: [ImportResult]
    @State private var expanded = false

    private var headerText: String {
        let count = files.count
        switch status {
        case .success:
            return "\(count) file\(count == 1 ? "" : "s") imported"
        case .skip:
            return "\(count) file\(count == 1 ? "" : "s") skipped"
        case .fail:
            return "\(count) file\(count == 1 ? "" : "s") failed"
        }
    }

    var body: some View {
        if !files.isEmpty {
            DisclosureGroup(headerText, isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(files, id: \.filename) { file in
                            switch status {
                            case .success:
                                Text("'\(file.filename)'")
                                    .font(.body.monospaced())
                            default:
                                Text("'\(file.filename)': \(file.message)")
                                    .font(.body.monospaced())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 150, alignment: .leading)
            }
        }
    }
}

struct Progress: View {
    var action: String
    var totalFiles: Int
    var skippedFiles: [ImportResult] = []
    var erroredFiles: [ImportResult] = []
    var completeFiles: [ImportResult] = []

    var body: some View {
        let nCompleted = skippedFiles.count + erroredFiles.count + completeFiles.count
        VStack(alignment: .leading) {
            if nCompleted != totalFiles {
                Text("\(action.capitalized)ing \(totalFiles) files...")
                ProgressView(value: Float(nCompleted), total: Float(totalFiles))
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
            } else if totalFiles != 0 {
                Text("Finished \(action)ing \(totalFiles) files")
                ImportReport(status: ImportStatus.success, files: completeFiles)
                ImportReport(status: ImportStatus.skip, files: skippedFiles)
                ImportReport(status: ImportStatus.fail, files: erroredFiles)
            }
        }
    }
}
