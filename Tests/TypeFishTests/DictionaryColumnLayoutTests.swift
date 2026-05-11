import XCTest
@testable import TypeFish

final class DictionaryColumnLayoutTests: XCTestCase {
    func testReplacementColumnsStayReadableAfterSingleColumnMode() {
        let singleColumn = DictionaryColumnLayout.widths(
            availableWidth: 720,
            showsReplacementColumns: false
        )

        XCTAssertEqual(singleColumn.wrong, 720)
        XCTAssertEqual(singleColumn.replacement, 0)
        XCTAssertEqual(singleColumn.source, 0)

        let replacementColumns = DictionaryColumnLayout.widths(
            availableWidth: 720,
            showsReplacementColumns: true
        )

        XCTAssertGreaterThanOrEqual(replacementColumns.wrong, DictionaryColumnLayout.minimumWrongWidth)
        XCTAssertGreaterThanOrEqual(replacementColumns.replacement, DictionaryColumnLayout.minimumReplacementWidth)
        XCTAssertEqual(replacementColumns.source, DictionaryColumnLayout.sourceWidth)
        XCTAssertLessThan(replacementColumns.wrong, 720 - DictionaryColumnLayout.minimumReplacementWidth)
    }

    func testNarrowReplacementLayoutPreservesMinimumWidths() {
        let columns = DictionaryColumnLayout.widths(
            availableWidth: 520,
            showsReplacementColumns: true
        )

        XCTAssertGreaterThanOrEqual(columns.wrong, DictionaryColumnLayout.minimumWrongWidth)
        XCTAssertEqual(columns.replacement, DictionaryColumnLayout.minimumReplacementWidth)
        XCTAssertEqual(columns.source, DictionaryColumnLayout.sourceWidth)
        XCTAssertEqual(
            columns.wrong + columns.replacement + columns.source,
            DictionaryColumnLayout.minimumWrongWidth
                + DictionaryColumnLayout.minimumReplacementWidth
                + DictionaryColumnLayout.sourceWidth
        )
    }
}
