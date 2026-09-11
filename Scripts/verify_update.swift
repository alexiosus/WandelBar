import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

final class Enclosure: NSObject, XMLParserDelegate {
    var attributes: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { attributes.append(attributeDict) }
    }
}
let args = CommandLine.arguments
guard args.count == 4 else { fatalError("Expected app plist, feed and DMG") }
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[1])), format: nil) as! [String: Any]
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as! String)!)
let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: args[2])))
let delegate = Enclosure()
parser.delegate = delegate
guard parser.parse(), delegate.attributes.count == 1,
      let enclosure = delegate.attributes.first,
      let encoded = enclosure["sparkle:edSignature"], let signature = Data(base64Encoded: encoded)
else { fatalError("Missing unambiguous signed update enclosure") }
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
let version = plist["CFBundleShortVersionString"] as! String
let expectedURL = "https://github.com/alexiosus/WandelBar/releases/download/v\(version)/WandelBar-\(version)-macOS-arm64.dmg"
guard enclosure["url"] == expectedURL,
      enclosure["length"] == String(archive.count),
      publicKey.isValidSignature(signature, for: archive)
else { fatalError("Archive signature, URL or length does not match the app's pinned configuration") }
print("Update archive signature verified against the app's public key")
