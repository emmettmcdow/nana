import SwiftUI

#if DISABLE_NANAKIT
    private func nana_import(_: UnsafePointer<Int8>, _: UnsafeMutablePointer<Int8>?, _: UInt32) -> Int32 {
        return 1 // Success
    }

    private func nana_deinit() -> Int32 {
        return 0 // Success
    }

    private func nana_doctor() -> Int32 {
        return 0 // Success
    }

    enum NanaError: Int {
        case Success = 0
        case GenericFail = -8
        case DoubleInit = -9
        case NotInit = -10
        case PathTooLong = -11
        case FileNotFound = -12
        case InvalidFiletype = -13
    }
#else
    import NanaKit
#endif

struct ImportItem {
    var filename: String
    var message: String
    var status: ImportStatus
}

enum ImportStatus {
    case queued
    case success
    case skip
    case fail
}

func filesInDir(dirURL: URL) -> [String] {
    var files: [String] = []
    let resourceKeys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey, .pathKey]
    let fileNumberEnumerator = FileManager.default.enumerator(at: dirURL,
                                                              includingPropertiesForKeys: resourceKeys,
                                                              options: [.skipsHiddenFiles],
                                                              errorHandler: { url, error -> Bool in
                                                                  print("directoryEnumerator error at \(url): ", error)
                                                                  return true
                                                              })!
    for case let fileURL as URL in fileNumberEnumerator {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if !resourceValues.isDirectory! {
                if let path = resourceValues.path {
                    files.append(path)
                }
            }
        } catch {
            print(error)
        }
    }
    return files
}

func import_from_dir(result: Result<[URL], any Error>,
                     onProgress: @MainActor @escaping (_ files: [ImportItem]) -> Void) async throws
{
    let gottenResult = try result.get()
    guard let dirURL = gottenResult.first else {
        await onProgress([ImportItem(filename: "Directory", message: "No directory selected", status: .fail)])
        return
    }
    guard dirURL.startAccessingSecurityScopedResource() else {
        await onProgress([ImportItem(filename: "Directory", message: "Failed to start accessing security-scoped resource", status: .fail)])
        return
    }
    defer { dirURL.stopAccessingSecurityScopedResource() }

    var files: [ImportItem] = []
    for path in filesInDir(dirURL: dirURL) {
        files.append(ImportItem(filename: path, message: "", status: .queued))
    }

    await importFiles(files: files,
                      onProgress: onProgress)
}

func import_from_doctor(onProgress: @MainActor @escaping (_ files: [ImportItem]) -> Void) async {
    await doctor(onProgress: onProgress)
}

func doctor(onProgress: @MainActor @escaping (_ files: [ImportItem]) -> Void) async
{
    let err = nana_doctor()

    if err != 0 {
        await onProgress([ImportItem(filename: "Doctor", message: "Doctor failed with error: \(err)", status: .fail)])
    } else {
        await onProgress([ImportItem(filename: "Doctor", message: "Completed", status: .success)])
    }
}

func importFiles(
    files: [ImportItem],
    onProgress: @MainActor @escaping (_ files: [ImportItem]) -> Void
) async {
    var newFiles = files
    for i in files.indices {
        let res = files[i].filename.withCString { cString in
            nana_import(cString, nil, 0)
        }

        if res > 0 {
            newFiles[i].status = .success
        } else if res == 0 {
            newFiles[i].status = .skip
            newFiles[i].message = "File isn't a note."
        } else if res == -13 {
            newFiles[i].status = .skip
            newFiles[i].message = "Invalid filetype."
        } else {
            newFiles[i].status = .fail
            newFiles[i].message = "Failed to import note with error: \(res)"
        }
        await onProgress(newFiles)
    }
}

struct ImportReport: View {
    var status: ImportStatus
    var files: [ImportItem]
    @State private var expanded = false

    private var headerText: String {
        let count = files.count
        switch status {
        case .success:
            return "\(count) file\(count == 1 ? "" : "s") imported"
        case .skip:
            return "\(count) file\(count == 1 ? "" : "s") skipped"
        default:
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
    var files: [ImportItem] = []

    var body: some View {
        let nCompleted = files.filter { $0.status != .queued }.count
        let skipped = files.filter { $0.status == .skip }
        let failed = files.filter { $0.status == .fail }
        let complete = files.filter { $0.status == .success }

        if files.count != 0 {
            Section(header: Text("Progress")) {
                VStack(alignment: .leading) {
                    if nCompleted != files.count {
                        Text("\(action.capitalized)ing \(files.count) files...")
                        ProgressView(value: Float(nCompleted), total: Float(files.count))
                            .progressViewStyle(.linear)
                            .padding(.horizontal)
                    } else if action == "doctor" {
                        if failed.isEmpty {
                            Text("Successfully fixed data")
                        } else {
                            Text("Failed to fix data")
                            ImportReport(status: ImportStatus.fail, files: failed)
                        }
                    } else {
                        Text("Finished \(action)ing \(files.count) files")
                        ImportReport(status: ImportStatus.success, files: complete)
                        ImportReport(status: ImportStatus.skip, files: skipped)
                        ImportReport(status: ImportStatus.fail, files: failed)
                    }
                }
            }
        }
    }
}
