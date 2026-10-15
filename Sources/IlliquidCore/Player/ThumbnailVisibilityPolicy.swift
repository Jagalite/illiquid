/// Thumbnail preparation depends on actual visibility, not key-window or
/// application-active status. A visible player can keep working behind another
/// app; hidden, miniaturized, fully occluded and closed players cannot.
public enum ThumbnailVisibilityPolicy {
    public static func isVisible(hasWindow: Bool, isApplicationHidden: Bool,
                                 isWindowVisible: Bool, isMiniaturized: Bool,
                                 isOccluded: Bool) -> Bool {
        hasWindow && !isApplicationHidden && isWindowVisible && !isMiniaturized && !isOccluded
    }
}
