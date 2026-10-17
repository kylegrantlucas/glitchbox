import Foundation
import Testing
@testable import VideobedKit

struct DevShellResolverTests {
    @Test func parseEnv0DropsSessionVarsAndKeepsEquals() {
        let raw = "PATH=/a:/b\0TMPDIR=/tmp/x\0PWD=/here\0SHLVL=2\0OPTS=a=b=c\0EMPTY=\0"
        let env = DevShellResolver.parseEnv0(Data(raw.utf8))
        #expect(env == ["PATH": "/a:/b", "OPTS": "a=b=c", "EMPTY": ""])
    }

    @Test func cacheWithCollectedStorePathsIsStale() {
        #expect(!DevShellResolver.storePathsExist(["PATH": "/usr/bin:/nix/store/00000000000000000000000000000000-gone/bin"]))
        // Only store paths are checked; ordinary PATH entries may legitimately be absent.
        #expect(DevShellResolver.storePathsExist(["PATH": "/usr/bin:/opt/not-installed/bin"]))
    }
}
