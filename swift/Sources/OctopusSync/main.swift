import SwiftUI
import Darwin

// Kill any other live process matching our bundle identifier before the
// SwiftUI app starts. Prior runs that got force-terminated by runningboardd
// (after the 5-minute "No exit notification" timeout) can leave behind a
// process registered with Launch Services even though it's no longer
// responsive — that's what produces `open` returning -600 / procNotFound.
//
// We can't reap actual zombies (`?E` state) — only the parent (launchd) can.
// But we can SIGKILL any still-live duplicates so a clean launch proceeds.
private func killStaleInstances() {
    let myPID = getpid()
    let myBundleID = "enotix.OctopusSync"

    // sysctl KERN_PROC_ALL — enumerate every process on the system.
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    let status = procs.withUnsafeMutableBufferPointer { buf -> Int32 in
        var bufSize = buf.count * MemoryLayout<kinfo_proc>.stride
        return sysctl(&mib, u_int(mib.count), buf.baseAddress, &bufSize, nil, 0)
    }
    guard status == 0 else { return }

    for proc in procs {
        let pid = proc.kp_proc.p_pid
        guard pid > 0, pid != myPID else { continue }

        // libproc gives us the bundle ID through PROC_PIDT_BSDINFOWITHUNIQID,
        // but the most portable check is the executable path.
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard len > 0 else { continue }
        let path = String(cString: pathBuf)
        guard path.contains("/OctopusSync.app/") || path.hasSuffix("/OctopusSync") else { continue }

        // Double-check via the actual bundle identifier where possible.
        let bundleURL = URL(fileURLWithPath: path)
            .deletingLastPathComponent() // MacOS/
            .deletingLastPathComponent() // Contents/
        let infoPlist = bundleURL.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: infoPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let bundleID = plist["CFBundleIdentifier"] as? String,
           bundleID != myBundleID {
            continue
        }

        kill(pid, SIGKILL)
    }
}

killStaleInstances()
OctopusSyncApp.main()
