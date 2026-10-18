import Foundation
import Testing
@testable import GlitchboxKit

struct SessionStateTests {
    func decode(_ json: String) throws -> SessionState {
        try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
    }

    @Test func schema1PreviewBecomesInOutAtPreviewHeight() throws {
        let s = try decode("""
        {"schema":1,"source":"/m/a.mov","mode":"preview",
         "previewSettings":{"start":2,"duration":3,"height":480,"fps":25,"stillDuration":5},"layers":[]}
        """)
        #expect(s.source == "/m/a.mov")
        #expect(s.render == RenderOptions(range: .inOut, inPoint: 2, outPoint: 5, height: 480, fps: .fps25, stillDuration: 5))
        #expect(s.render.settings(still: false) == RenderSettings(start: 2, duration: 3, height: 480, fps: .fps25))
    }

    @Test func schema1FullBecomesWholeAtNative() throws {
        let s = try decode("""
        {"schema":1,"mode":"full",
         "previewSettings":{"start":1,"duration":4,"height":720,"fps":30,"stillDuration":5},"layers":[]}
        """)
        #expect(s.render.range == .whole)
        #expect(s.render.height == nil)
        #expect(s.render.fps == .fps30)
        // The preview range survives for when the user switches back.
        #expect(s.render.inPoint == 1 && s.render.outPoint == 5)
        #expect(s.render.settings(still: false) == RenderSettings(start: 0, duration: nil, height: nil, fps: .fps30))
    }

    @Test func schema1PreviewToTheEndKeepsAnOpenOutPoint() throws {
        let s = try decode("""
        {"mode":"preview","previewSettings":{"start":1.5,"height":360,"fps":24,"stillDuration":5},"layers":[]}
        """)
        #expect(s.render.settings(still: false) == RenderSettings(start: 1.5, duration: nil, height: 360, fps: .fps24))
    }

    @Test func roundTripsAsSchema2() throws {
        let original = SessionState(source: nil, render: RenderOptions(range: .whole, fps: .fps29_97),
                                    layers: [LayerSpec(plugin: "x", enabled: true, params: [:])])
        let json = String(decoding: try Workspace.encoder().encode(original), as: UTF8.self)
        #expect(json.contains("\"schema\" : 2"))
        #expect(json.contains("\"30000/1001\""))
        #expect(!json.contains("previewSettings"))
        let back = try decode(json)
        #expect(back.render == original.render)
        #expect(back.layers == original.layers)
    }

    @Test func stillsIgnoreTheRange() {
        let options = RenderOptions(range: .inOut, inPoint: 3, outPoint: 4, stillDuration: 8)
        #expect(options.settings(still: true) == RenderSettings(start: 0, duration: nil, height: 480, fps: nil, stillDuration: 8))
    }
}
