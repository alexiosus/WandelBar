import AppKit

// A Finder alias with an embedded icon avoids Tahoe's blank symlink icon in DMGs.
// Only the alias inside the staging directory is modified, never /Applications.
let arguments = CommandLine.arguments
let verifyOnly = arguments.count == 3 && arguments[1] == "--verify"
guard arguments.count == 2 || verifyOnly else {
    fputs("Usage: dmg_applications_alias.swift [--verify] <alias path>\n", stderr)
    exit(1)
}
let alias = URL(fileURLWithPath: arguments.last!)
let target = URL(fileURLWithPath: "/Applications", isDirectory: true)
if !verifyOnly {
    guard !FileManager.default.fileExists(atPath: alias.path) else {
        fputs("Refusing to replace an existing Applications entry\n", stderr)
        exit(1)
    }
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile,
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: alias)
    guard NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(forFile: target.path),
                                     forFile: alias.path, options: []) else {
        fputs("Could not assign the Applications alias icon\n", stderr)
        exit(1)
    }
}
let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
guard values.isAliasFile == true, values.isSymbolicLink != true,
      try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting]).standardizedFileURL.path == target.path else {
    fputs("Applications alias does not resolve to /Applications\n", stderr)
    exit(1)
}
let iconResource = try Data(contentsOf: URL(fileURLWithPath: alias.path + "/..namedfork/rsrc"))
guard !iconResource.isEmpty else {
    fputs("Applications alias is missing its embedded icon\n", stderr)
    exit(1)
}
