import CoreText
import WEFormat
import XCTest
@testable import WERender

final class TextObjectTests: XCTestCase {
    let locator = AssetLocator(project: FileManager.default.temporaryDirectory, assets: nil)

    func text(_ fields: [String: Any]) -> TextObject {
        TextObject(object: fields, properties: UserProperties(project: [:]))
    }

    func testParsingDefaultsAndUserBinding() {
        let t = text(["text": ["script": "x", "value": "12:34"], "pointsize": 20, "padding": 8,
                      "horizontalalign": "right", "verticalalign": "top"])
        XCTAssertEqual(t.value, "12:34"); XCTAssertEqual(t.font, "systemfont_sansserif")
        XCTAssertEqual(t.pointSize, 20); XCTAssertEqual(t.padding, 8)
        XCTAssertEqual(t.horizontal, .end); XCTAssertEqual(t.vertical, .start)
        XCTAssertNil(t.maxWidth); XCTAssertNil(t.maxRows)
        let bound = TextObject(object: ["text": ["user": "caption", "value": "default"]],
                               properties: UserProperties(project: [:], overrides: ["caption": "custom"]))
        XCTAssertEqual(bound.value, "custom")
        XCTAssertEqual(text(["text": "plain"]).value, "plain")
    }

    func testBoxOffsetFollowsAlignment() {
        let size = SIMD2<Float>(100, 40)
        XCTAssertEqual(text([:]).boxOffset(size), [0, 0])
        XCTAssertEqual(text(["horizontalalign": "left", "verticalalign": "top"]).boxOffset(size), [50, 20])
        XCTAssertEqual(text(["horizontalalign": "right", "verticalalign": "bottom"]).boxOffset(size), [-50, -20])
    }

    func testBoxIsLineMetricsAt300DPIPlusPadding() {
        let t = text(["pointsize": 12, "padding": 10, "font": "systemfont_sansserif"])
        let r = TextRasterizer(t, locator: locator)
        let one = r.render("Hello"), two = r.render("Hello\nWorld")
        let font = TextRasterizer.font("systemfont_sansserif", size: CGFloat(12 * TextObject.pixelsPerPoint), locator: locator)
        let line = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        XCTAssertEqual(one.height, Int((line + 20).rounded(.up)))
        XCTAssertEqual(two.height, Int((2 * line + 20).rounded(.up)))
        XCTAssertEqual(one.coverage.count, one.width * one.height)
        XCTAssertGreaterThan(one.coverage.max() ?? 0, 200, "glyphs are drawn")
        // Padding stays empty.
        XCTAssertEqual(one.coverage.prefix(one.width * 10).max(), 0)
    }

    func testWrappingRowLimitAndEllipsis() {
        let long = String(repeating: "word ", count: 40)
        let wrapped = TextRasterizer(text(["limitwidth": true, "maxwidth": 300, "pointsize": 10]), locator: locator)
        let lines = wrapped.layoutLines(long)
        XCTAssertGreaterThan(lines.count, 2)
        for line in lines { XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line), 300) }
        let limited = TextRasterizer(text(["limitwidth": true, "maxwidth": 300, "pointsize": 10, "limitrows": true,
                                           "maxrows": 2, "limituseellipsis": true]), locator: locator)
        let rows = limited.layoutLines(long)
        XCTAssertEqual(rows.count, 2)
        let last = rows[1]
        XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(last, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(last), 300)
        // Without the ellipsis flag the extra rows are simply dropped.
        let cut = TextRasterizer(text(["limitrows": true, "maxrows": 1]), locator: locator).layoutLines("a\nb\nc")
        XCTAssertEqual(cut.count, 1)
    }
}
