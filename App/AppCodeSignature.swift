import Foundation
import Security

/// Code-signing information needed to create macOS native per-app VPN rules.
enum AppCodeSignature {
    /// Returns the exact designated requirement macOS uses to identify the
    /// executable at `url`. This works for both Developer ID/development
    /// signatures and the ad-hoc test apps used by this project.
    static func designatedRequirement(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }

        var requirementString: CFString?
        guard SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
              let requirementString else {
            return nil
        }
        return requirementString as String
    }
}
