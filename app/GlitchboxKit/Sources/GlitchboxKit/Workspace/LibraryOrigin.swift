/// Where a library entry's effective file lives.
public enum LibraryOrigin: Sendable, Hashable {
    /// Base library only; read-only, cannot be deleted.
    case builtin
    /// User library only; deleting removes it.
    case user
    /// User copy shadowing a base entry; deleting reverts to the built-in.
    case overridden

    /// True when there is a user copy that delete would remove.
    public var hasUserCopy: Bool { self != .builtin }
}
