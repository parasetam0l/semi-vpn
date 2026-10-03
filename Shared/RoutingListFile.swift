import Foundation

/// The text files the website and app lists are exported to and imported
/// from: one entry per line; `#` starts a comment.
///
///     *.example.com            the site and its subdomains
///     example.org              the site and its www variant
///     example.net paused       in the list, but switched off
///
///     com.example.App          an app, by bundle identifier
///     com.example.Other off    in the list, but switched off
///     /Applications/Some.app   an app by path also works on import
public enum RoutingListFile {
    public struct Result<Entry> {
        public var entries: [Entry]
        /// Lines that could not be read: line number and text.
        public var rejected: [(line: Int, text: String)]
    }

    public struct AppLine: Equatable {
        /// A bundle identifier, or the path of an .app bundle.
        public var identifier: String
        public var enabled: Bool

        public init(identifier: String, enabled: Bool = true) {
            self.identifier = identifier
            self.enabled = enabled
        }
    }

    // MARK: - Websites

    public static func websites(from text: String) -> Result<SharedConfig.DomainRule> {
        var result = Result<SharedConfig.DomainRule>(entries: [], rejected: [])
        for (number, line) in contentLines(text) {
            var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let pattern = words.removeFirst()
            let includeSubdomains = pattern.hasPrefix("*.")
            let host = includeSubdomains ? String(pattern.dropFirst(2)) : pattern
            guard let domain = SharedConfig.routingDomain(host) else {
                result.rejected.append((number, line))
                continue
            }
            result.entries.append(SharedConfig.DomainRule(
                domain: domain,
                includeSubdomains: includeSubdomains,
                enabled: !isSwitchedOff(words)
            ))
        }
        return result
    }

    public static func text(forWebsites rules: [SharedConfig.DomainRule]) -> String {
        var lines = [
            "# SemiVPN websites",
            "# *.example.com includes subdomains; \"paused\" keeps a site switched off.",
        ]
        for rule in rules {
            lines.append((rule.includeSubdomains ? "*." : "") + rule.domain + (rule.enabled ? "" : " paused"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Apps

    public static func apps(from text: String) -> Result<AppLine> {
        var result = Result<AppLine>(entries: [], rejected: [])
        for (number, line) in contentLines(text) {
            // A path may contain spaces: it runs to the end of ".app".
            if line.hasPrefix("/"), let end = line.range(of: ".app", options: .caseInsensitive) {
                let path = String(line[..<end.upperBound])
                let words = line[end.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
                result.entries.append(AppLine(identifier: path, enabled: !isSwitchedOff(words)))
                continue
            }
            var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let identifier = words.removeFirst()
            guard identifier.contains("."), !identifier.hasPrefix("/"),
                  identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
                result.rejected.append((number, line))
                continue
            }
            result.entries.append(AppLine(identifier: identifier, enabled: !isSwitchedOff(words)))
        }
        return result
    }

    public static func text(forApps apps: [AppLine]) -> String {
        var lines = [
            "# SemiVPN apps",
            "# One bundle identifier per line; \"off\" keeps an app switched off.",
        ]
        for app in apps {
            lines.append(app.identifier + (app.enabled ? "" : " off"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Lines

    /// Non-empty lines without comments, with their 1-based numbers. A `#`
    /// starts a comment at the beginning of a line or after a space, so a
    /// URL's `#fragment` is kept.
    static func contentLines(_ text: String) -> [(Int, String)] {
        var lines: [(Int, String)] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = rawLine
            if let comment = line.range(of: "#"),
               comment.lowerBound == line.startIndex || line[line.index(before: comment.lowerBound)].isWhitespace {
                line = String(line[..<comment.lowerBound])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                lines.append((index + 1, line))
            }
        }
        return lines
    }

    private static func isSwitchedOff(_ words: [String]) -> Bool {
        words.contains { ["paused", "off", "disabled"].contains($0.lowercased()) }
    }
}
