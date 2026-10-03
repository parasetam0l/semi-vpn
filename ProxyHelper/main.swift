import Foundation
import AppKit

signal(SIGPIPE, SIG_IGN)

// `SemiProxy --public-ip`: prints the public addresses this helper's
// traffic shows (PublicIPLookup.Result as JSON) and exits. macOS routes the
// helper through the VPN, so SemiVPN runs it for the addresses with the VPN.
if CommandLine.arguments.contains("--public-ip") {
    Task {
        let result = await PublicIPLookup.lookUp(avoidingTunnels: false)
        if let data = try? JSONEncoder().encode(result) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }
    dispatchMain()
}

AppLogger.log("SemiProxy helper started (pid \(ProcessInfo.processInfo.processIdentifier))")

// Monitor parent process so helper terminates cleanly when SemiVPN exits
var targetPID: pid_t = 0
if let index = CommandLine.arguments.firstIndex(of: "--parent-pid"),
   index + 1 < CommandLine.arguments.count,
   let parsed = pid_t(CommandLine.arguments[index + 1]),
   parsed > 1 {
    targetPID = parsed
} else {
    let ppid = getppid()
    if ppid > 1 {
        targetPID = ppid
    }
}

if targetPID > 1 {
    let parentMonitor = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    parentMonitor.schedule(deadline: .now() + 1, repeating: 1.0)
    parentMonitor.setEventHandler {
        if kill(targetPID, 0) != 0 && errno == ESRCH {
            AppLogger.log("SemiProxy helper exiting because parent process \(targetPID) terminated")
            exit(0)
        }
    }
    parentMonitor.resume()
}

let server = LocalProxyServer()
server.start()

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { _ in
    AppLogger.log("SemiProxy helper: system woke from sleep, restarting proxy listeners")
    server.restartListeners()
}

dispatchMain()
