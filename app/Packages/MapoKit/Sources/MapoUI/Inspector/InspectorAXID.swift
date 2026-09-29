import Foundation

/// The inspector's identifiers (ENGINEERING §4.2, UX §2.4).
extension AXID {
    public static let inspectorSegmentFiles = "inspector.segment:files"
    public static let inspectorSegmentChanges = "inspector.segment:changes"
    public static let inspectorFilesHeader = "inspector.files.header"
    public static let inspectorFilesState = "inspector.files.state"
    public static let inspectorFilesRetry = "inspector.files.retry"

    /// `inspector.files.row:<relPath>`, relative to the Files root.
    public static func inspectorFilesRow(_ relativePath: String) -> String {
        "inspector.files.row:\(relativePath)"
    }
}
