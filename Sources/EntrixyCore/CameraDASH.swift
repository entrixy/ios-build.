import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Rewrites every DASH network reference before an independent decoder sees it.
/// The bridge owns authorization and rejects references outside the camera origin.
public enum CameraDASHManifest {
    public static func rewriting(_ data: Data, base: URL, resource: (String, URL) throws -> String) throws -> Data {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity") else { throw GuestCrypto.Failure.invalidEnvelope }
        let builder = Builder()
        let parser = XMLParser(data: data); parser.delegate = builder; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !builder.invalid, let root = builder.root, root.local == "MPD" else { throw GuestCrypto.Failure.invalidEnvelope }
        var rewrittenBytes = 0, references = 0
        func mapped(_ value: String, _ parent: URL) throws -> String {
            references += 1
            guard references <= 32768 else { throw GuestCrypto.Failure.invalidEnvelope }
            let result = try resource(value, parent), count = result.utf8.count
            // Bound expansion while walking, before constructing the XML tree's
            // serialized string. A short segment plus a long signed base must
            // not multiply into hundreds of megabytes of local capabilities.
            guard count <= 32768, rewrittenBytes + count <= 2_097_152 else { throw GuestCrypto.Failure.invalidEnvelope }
            rewrittenBytes += count; return result
        }
        func walk(_ node: Node, _ inherited: URL) throws {
            guard !["ContentSteering", "ContentProtection"].contains(node.local) else { throw GuestCrypto.Failure.invalidEnvelope }
            var origin = inherited
            let bases = node.children.filter { $0.local == "BaseURL" }
            guard bases.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
            if let child = bases.first {
                let value = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard child.children.isEmpty, !value.isEmpty, let next = URL(string: value, relativeTo: inherited)?.absoluteURL else { throw GuestCrypto.Failure.invalidEnvelope }
                // Validate the original BaseURL even when every segment uses an
                // absolute URI. Do not leave a remote fallback in the manifest.
                child.text = try mapped(value, inherited); origin = next
            }
            for name in node.attributes.keys.sorted() {
                let local = name.split(separator: ":").last.map(String.init) ?? name
                if local == "href" { throw GuestCrypto.Failure.invalidEnvelope }
                let reference = ["media", "initialization", "index", "sourceURL"].contains(local)
                    || (node.local == "SegmentTemplate" && local == "bitstreamSwitching")
                if reference, let value = node.attributes[name], !value.isEmpty { node.attributes[name] = try mapped(value, origin) }
            }
            if ["Location", "PatchLocation"].contains(node.local) {
                node.text = try mapped(node.text.trimmingCharacters(in: .whitespacesAndNewlines), origin)
            }
            if node.local == "UTCTiming", let scheme = node.attributes["schemeIdUri"], scheme.contains(":http-"), let value = node.attributes["value"] {
                guard !value.contains(" ") else { throw GuestCrypto.Failure.invalidEnvelope }
                node.attributes["value"] = try mapped(value, origin)
            } else if node.local == "UTCTiming" {
                guard node.attributes["schemeIdUri"]?.contains(":direct:") == true else { throw GuestCrypto.Failure.invalidEnvelope }
            }
            for child in node.children where child.local != "BaseURL" { try walk(child, origin) }
        }
        try walk(root, base)
        let output = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + root.xml).utf8)
        guard output.count <= 4_194_304 else { throw GuestCrypto.Failure.invalidEnvelope }
        return output
    }
    private final class Node {
        let name: String
        var attributes: [String: String]
        var children: [Node] = []
        var text = ""
        var local: String { name.split(separator: ":").last.map(String.init) ?? name }
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        var xml: String {
            let attrs = attributes.keys.sorted().map { " " + $0 + "=\"" + Self.escape(attributes[$0]!) + "\"" }.joined()
            return "<" + name + attrs + ">" + Self.escape(text) + children.map(\.xml).joined() + "</" + name + ">"
        }
    }
    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?, stack: [Node] = []
        var count = 0, invalid = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            count += 1
            guard count <= 32768, stack.count < 64 else { invalid = true; parser.abortParsing(); return }
            let node = Node(elementName, attributeDict)
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node }
            else { invalid = true; parser.abortParsing(); return }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let value = String(data: CDATABlock, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
            stack.last?.text += value
        }
    }
}

/// Store the *unexpanded* template inside an authenticated local capability.
/// Only its DASH substitution fields are visible to the decoder. Static query
/// credentials never appear in local URLs, including with numbered segments.
public struct CameraDASHTemplate: Codable {
    public let parts: [String]
    public let fields: [String]
    public init(_ template: String, base: URL) throws {
        guard template.utf8.count <= 8192 else { throw GuestCrypto.Failure.invalidEnvelope }
        let regex = try NSRegularExpression(pattern: #"\$(?:RepresentationID|Number|Bandwidth|Time|SubNumber)(?:%0[1-9][0-9]?d)?\$|\$\$"#)
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var pieces: [String] = [], variables: [String] = [], cursor = template.startIndex
        var literal = ""
        for match in matches {
            guard let range = Range(match.range, in: template) else { throw GuestCrypto.Failure.invalidEnvelope }
            literal += template[cursor..<range.lowerBound]
            let field = String(template[range])
            if field == "$$" { literal += "%24" }
            else { pieces.append(literal); literal = ""; variables.append(field) }
            cursor = range.upperBound
        }
        literal += template[cursor...]; pieces.append(literal)
        guard variables.count <= 16, !pieces.contains(where: { $0.replacingOccurrences(of: "$$", with: "").contains("$") }) else { throw GuestCrypto.Failure.invalidEnvelope }
        // Resolve the base while substitutions are harmless placeholders, then
        // split it back. A template cannot change the scheme or authority.
        let marker = "entrixydashfield"
        guard !template.contains(marker), let absolute = URL(string: pieces.enumerated().map { $0.element + ($0.offset < variables.count ? marker + String($0.offset) : "") }.joined(), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(absolute.scheme?.lowercased() ?? ""), absolute.user == nil, absolute.password == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        var resolved: [String] = [], rest = absolute.absoluteString
        for index in variables.indices {
            guard let range = rest.range(of: marker + String(index)) else { throw GuestCrypto.Failure.invalidEnvelope }
            resolved.append(String(rest[..<range.lowerBound])); rest = String(rest[range.upperBound...])
        }
        resolved.append(rest); parts = resolved; fields = variables
        // Require all substitutions to occur after the authority.
        guard variables.isEmpty || (parts[0].range(of: #"^https?://[^/]+/"#, options: .regularExpression) != nil) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func expanded(_ values: [String]) throws -> URL {
        guard parts.count == fields.count + 1, values.count == fields.count,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && $0 != "." && $0 != ".." && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95,126].contains($0) } }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var value = parts[0]
        for index in values.indices { value += values[index] + parts[index + 1] }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        return url
    }
}
