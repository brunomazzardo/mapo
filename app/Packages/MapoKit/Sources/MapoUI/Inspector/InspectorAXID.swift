import Foundation

/// The inspector's identifiers (ENGINEERING §4.2, UX §2.4).
extension AXID {
    public static let inspectorSegmentFiles = "inspector.segment:files"
    public static let inspectorSegmentChanges = "inspector.segment:changes"
    public static let inspectorFilesHeader = "inspector.files.header"
    public static let inspectorFilesState = "inspector.files.state"
    public static let inspectorFilesRetry = "inspector.files.retry"

    public static let inspectorChangesSummary = "inspector.changes.summary"
    public static let inspectorChangesWarning = "inspector.changes.warning"
    public static let inspectorChangesState = "inspector.changes.state"
    public static let inspectorChangesRetry = "inspector.changes.retry"

    /// `inspector.changes.row:<relPath>`, relative to the repository root.
    public static func inspectorChangesRow(_ relativePath: String) -> String {
        "inspector.changes.row:\(relativePath)"
    }

    /// `inspector.files.row:<relPath>`, relative to the Files root.
    public static func inspectorFilesRow(_ relativePath: String) -> String {
        "inspector.files.row:\(relativePath)"
    }
}
