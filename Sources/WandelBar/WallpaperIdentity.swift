import Foundation

enum WallpaperIdentity: Equatable, Sendable {
    case file(URL)
    case photosAsset(String)

    var stableIdentifier: String {
        switch self {
        case .file(let url):
            return "file:\(url.standardizedFileURL.absoluteString)"
        case .photosAsset(let identifier):
            return "photos:\(identifier)"
        }
    }

    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }

    init?(stableIdentifier: String) {
        if stableIdentifier.hasPrefix("file:"),
           let url = URL(string: String(stableIdentifier.dropFirst("file:".count))) {
            self = .file(url)
        } else if stableIdentifier.hasPrefix("photos:") {
            self = .photosAsset(String(stableIdentifier.dropFirst("photos:".count)))
        } else {
            return nil
        }
    }
}

