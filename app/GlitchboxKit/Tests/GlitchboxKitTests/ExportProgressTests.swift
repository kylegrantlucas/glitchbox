import Testing
@testable import GlitchboxKit

struct ExportProgressTests {
    @Test func notAvailableTimeHasNoFraction() {
        let p = ExportProgress.parse("frame=0\nout_time_us=N/A\nout_time_ms=N/A\nout_time=N/A\nprogress=continue\n")
        #expect(p == ExportProgress(outTime: nil, ended: false))
        #expect(p.fraction(of: 4) == nil)
    }

    @Test func latestBlockWins() {
        let text = """
        out_time_us=N/A
        progress=continue
        out_time_us=1000000
        out_time_ms=1000000
        progress=continue
        out_time_us=3000000
        out_time_ms=3000000
        progress=continue

        """
        let p = ExportProgress.parse(text)
        #expect(p.outTime == 3)
        #expect(p.fraction(of: 4) == 0.75)
    }

    @Test func endIsComplete() {
        let p = ExportProgress.parse("out_time_us=3966667\nprogress=continue\nout_time_us=3966667\nprogress=end\n")
        #expect(p.ended)
        #expect(p.fraction(of: 4) == 1)
        #expect(p.fraction(of: nil) == 1)
    }

    @Test func fractionIsClamped() {
        #expect(ExportProgress(outTime: 5).fraction(of: 4) == 1)
        #expect(ExportProgress(outTime: 1).fraction(of: 0) == nil)
    }

    @Test func partialTrailingLineIsIgnored() {
        // ffmpeg may be mid-write when the file is read; "25" is the start of "2500000".
        #expect(ExportProgress.parse("out_time_us=2000000\nprogress=continue\nout_time_us=25").outTime == 2)
    }
}
