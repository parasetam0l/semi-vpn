import Foundation
import NetworkExtension

// The tunnel runs as a Network Extension system extension (required for
// Developer ID distribution): hand control to NetworkExtension, which creates
// a TunnelProvider for each tunnel it starts.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
