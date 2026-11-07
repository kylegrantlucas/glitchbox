import SwiftUI
import WebKit

/// Credits and the licence texts of every bundled component (`Toolchain/Credits.html`,
/// `Toolchain/licenses/<component>/…`, staged by packaging/build.sh).
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private let paths = AppPaths.current()

    var body: some View {
        NavigationStack {
            List {
                if FileManager.default.fileExists(atPath: paths.credits.path) {
                    Section {
                        NavigationLink("Credits") {
                            WebView(url: paths.credits)
                                .navigationTitle("Credits")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
                Section("Licenses") {
                    ForEach(Self.children(of: paths.licenses), id: \.self) { component in
                        NavigationLink(component.lastPathComponent) {
                            LicenseComponentView(directory: component)
                        }
                    }
                }
            }
            .overlay {
                if !PlatformActions.licensesAvailable {
                    ContentUnavailableView("No Licenses Bundled", systemImage: "doc.text",
                                           description: Text("This build has no Toolchain/licenses folder."))
                }
            }
            .navigationTitle("Third-Party Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
    }

    static func children(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// One component's licence files; a single file opens directly.
private struct LicenseComponentView: View {
    let directory: URL

    var body: some View {
        let files = LicensesView.children(of: directory)
        Group {
            if files.count == 1, let file = files.first {
                LicenseTextView(file: file)
            } else {
                List(files, id: \.self) { file in
                    NavigationLink(file.lastPathComponent) { LicenseTextView(file: file) }
                }
            }
        }
        .navigationTitle(directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let file: URL

    var body: some View {
        Group {
            if ["html", "htm"].contains(file.pathExtension.lowercased()) {
                WebView(url: file)
            } else {
                ScrollView {
                    Text((try? String(contentsOf: file, encoding: .utf8)) ?? "Cannot read \(file.lastPathComponent).")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(file.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}
