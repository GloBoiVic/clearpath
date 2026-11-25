import ClearpathCore
import Foundation

/// Atomic replacements change the inode. The change time also detects in-place
/// edits. Polling the path follows replacements without watching a stale inode.
struct PolicyVersion: Equatable {
    let device: dev_t
    let inode: ino_t
    let changedSeconds: Int
    let changedNanoseconds: Int

    init?(file: URL) {
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

func watchPolicy(_ file: URL, initialVersion: PolicyVersion?, server: LoopbackServer) -> DispatchSourceTimer {
    var lastVersion = initialVersion
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
    timer.setEventHandler {
        let version = PolicyVersion(file: file)
        guard version != lastVersion else { return }
        lastVersion = version
        guard version != nil, let updated = try? Policy(file: file.resolvingSymlinksInPath()) else {
            FileHandle.standardError.write(Data("Policy reload rejected; keeping the previous policy.\n".utf8))
            return
        }
        server.updatePolicy(updated)
    }
    timer.resume()
    return timer
}
