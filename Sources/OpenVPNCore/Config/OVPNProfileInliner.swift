import Foundation

public enum OVPNInlineError: Error, Equatable, Sendable, LocalizedError {
    case missingFile(directive: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let directive, let path):
            return "The '\(directive)' file '\(path)' could not be read. Keep it next to the profile and import again."
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
            let url = resolve(path, relativeTo: baseDirectory)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                throw OVPNInlineError.missingFile(directive: directive, path: path)
            }
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
        return changed ? output.joined(separator: "\n") : text
    }

    static func resolve(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return base.appendingPathComponent(expanded)
    }
}
