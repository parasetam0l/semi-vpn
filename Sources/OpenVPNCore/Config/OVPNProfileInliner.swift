import Foundation

public enum OVPNInlineError: Error, Equatable, Sendable, LocalizedError {
    case missingFile(directive: String, path: String)
    case fileOutsideProfileFolder(directive: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let directive, let path):
            return "The '\(directive)' file '\(path)' could not be read. Keep it next to the profile and import again."
        case .fileOutsideProfileFolder(let directive, let path):
            return "The '\(directive)' file '\(path)' is outside the profile's folder. Only files next to the profile are imported."
        }
    }
}

/// Embeds the files a profile references (`ca ca.crt`, `tls-auth ta.key 1`,
/// `auth-user-pass creds.txt`, ...) as inline blocks, so the profile is
/// self-contained once imported.
public enum OVPNProfileInliner {
    /// Directives whose file argument becomes an inline block of the same name.
    static let fileDirectives: Set<String> = [
        "ca", "cert", "key", "extra-certs", "tls-auth", "tls-crypt", "tls-crypt-v2", "auth-user-pass",
    ]

    /// Returns `text` with every file reference resolved against
    /// `baseDirectory` and embedded. Profiles without file references are
    /// returned unchanged.
    public static func inline(_ text: String, baseDirectory: URL) throws -> String {
        try inlineReportingFiles(text, baseDirectory: baseDirectory).text
    }

    /// Like `inline`, also returning the embedded file paths (to show the
    /// user what an imported profile pulled in).
    ///
    /// Only files inside `baseDirectory` are read: a downloaded profile must
    /// not be able to embed (and send to its server) arbitrary local files
    /// such as `auth-user-pass ~/.netrc`.
    public static func inlineReportingFiles(_ text: String, baseDirectory: URL) throws -> (text: String, files: [String]) {
        var embedded: [String] = []
        var output: [String] = []
        var changed = false
        var insideBlock: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if let block = insideBlock {
                output.append(line)
                if trimmed == "</\(block)>" { insideBlock = nil }
                continue
            }
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") {
                insideBlock = String(trimmed.dropFirst().dropLast())
                output.append(line)
                continue
            }

            let tokens = OVPNParser.tokenize(line)
            guard let directive = tokens.first?.lowercased(),
                  fileDirectives.contains(directive),
                  tokens.count >= 2,
                  tokens[1] != "[inline]" else {
                output.append(line)
                continue
            }

            let path = tokens[1]
            guard let url = resolve(path, relativeTo: baseDirectory) else {
                throw OVPNInlineError.fileOutsideProfileFolder(directive: directive, path: path)
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                throw OVPNInlineError.missingFile(directive: directive, path: path)
            }
            embedded.append(path)
            changed = true
            if directive == "tls-auth", tokens.count >= 3 {
                output.append("key-direction \(tokens[2])")
            }
            if directive == "auth-user-pass" {
                // Keep the directive so the profile still declares that it
                // needs credentials.
                output.append("auth-user-pass")
            }
            output.append("<\(directive)>")
            output.append(content.trimmingCharacters(in: .newlines))
            output.append("</\(directive)>")
        }
        return (changed ? output.joined(separator: "\n") : text, embedded)
    }

    /// The file a reference names, or nil when it is outside `base`
    /// (absolute paths, `~`, `..` or symlinks leading elsewhere).
    static func resolve(_ path: String, relativeTo base: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }
}
