import Foundation

enum StandardError {
    static func print(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
