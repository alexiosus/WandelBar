import AppKit
import SwiftUI

/// Only application-owned constants are used for official navigation.
enum AppInformation {
    static let copyright = "© 2026 Alexey Eremeev"
    static let repository = URL(string: "https://github.com/alexiosus/WandelBar")!
    static let donations = URL(string: "https://ko-fi.com/alexiosus")!
    static let releases = URL(string: "https://github.com/alexiosus/WandelBar/releases")!
    static let exchange = URL(string: "https://github.com/alexiosus/WandelBar/discussions/categories/preset-exchange")!
    static let newDiscussion = URL(string: "https://github.com/alexiosus/WandelBar/discussions/new?category=preset-exchange")!
    static let license = URL(string: "https://github.com/alexiosus/WandelBar/blob/master/LICENSE")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
}

struct AboutWandelBarView: View {
    @State private var showingNotices = false
    private let noticesText = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("WandelBar").font(.title.bold())
                    Text("Version \(AppInformation.version)").foregroundStyle(.secondary)
                    Text(AppInformation.copyright).font(.callout)
                }
            }
            Text("A personal surface for your menu bar.")
            HStack {
                Link("Official project", destination: AppInformation.repository)
                Link("Downloads", destination: AppInformation.releases)
                Link("GPL-3.0 license", destination: AppInformation.license)
            }
            Link("Support WandelBar on Ko-fi", destination: AppInformation.donations)
            if let noticesText {
                Button("Third-party notices") { showingNotices = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .sheet(isPresented: $showingNotices) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Third-party notices").font(.title2.bold())
                            ScrollView {
                                Text(noticesText)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Spacer()
                                Button("Done") { showingNotices = false }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(24)
                        .frame(width: 560, height: 400)
                    }
            }
        }
        .padding(24).frame(width: 470)
    }
}
