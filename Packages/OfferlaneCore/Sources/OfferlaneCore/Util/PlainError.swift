import Foundation
import GRDB

extension Error {
    /// True for "no space left" from SQLite, Foundation file writes or POSIX (also when wrapped as an underlying error).
    public var isDiskFull: Bool {
        if let db = self as? DatabaseError { return db.resultCode == .SQLITE_FULL }
        let ns = self as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        return (ns.userInfo[NSUnderlyingErrorKey] as? Error)?.isDiskFull ?? false
    }
    /// What the UI shows: the error's own text, except a full disk gets its cause and fix.
    public var plainMessage: String {
        isDiskFull ? "Your Mac's disk is full, so your last change wasn't saved. Free some space (empty the Trash or remove large files), then try again." : localizedDescription
    }
}
