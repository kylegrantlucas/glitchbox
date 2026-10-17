import Testing
@testable import VideobedKit

struct TemplateExpanderTests {
    @Test func expandsPlaceholders() throws {
        let s = try TemplateExpander.expand("-i {in} --amount={p.amount}", values: ["in": "/a b.mkv", "p.amount": "8"])
        #expect(s == "-i /a b.mkv --amount=8")
    }

    @Test func doubledBracesAreEscapes() throws {
        #expect(try TemplateExpander.expand("{{x}}", values: [:]) == "{x}")
        #expect(try TemplateExpander.expand("a}b", values: [:]) == "a}b")
        #expect(try TemplateExpander.placeholders(in: "{{in}} {out}") == ["out"])
    }

    @Test func rejectsUnknownPlaceholder() {
        #expect(throws: TemplateError.unknownPlaceholder("bogus")) {
            try TemplateExpander.expand("{bogus}", values: [:])
        }
    }

    @Test func rejectsUnterminatedBrace() {
        #expect(throws: TemplateError.unterminated) {
            try TemplateExpander.expand("x {in", values: ["in": "y"])
        }
    }
}
