import Foundation

/// Browser handoff only: no credentials, upload or publication from the app.
enum DiscussionDraft {
    static func url(title: String, body: String) -> URL? {
        var components = URLComponents(url: AppInformation.newDiscussion, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "category", value: "preset-exchange"),
            URLQueryItem(name: "title", value: String(title.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(100))),
            URLQueryItem(name: "body", value: body)
        ]
        // Encode '+' as well: form-style query decoding can otherwise turn it into a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.absoluteString.utf8.count <= 7_000 else { return nil }
        return url
    }
}
