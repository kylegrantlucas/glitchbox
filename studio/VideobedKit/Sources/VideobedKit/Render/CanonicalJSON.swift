import Foundation

public enum CanonicalJSON {
    public static func data<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every value hashed here is plain data; encoding cannot fail.
        return try! e.encode(value)
    }
}
