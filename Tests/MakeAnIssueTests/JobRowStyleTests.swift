import XCTest
import SwiftUI
@testable import MakeAnIssue

final class JobRowStyleTests: XCTestCase {

    // MARK: - iconName(for:)

    func testJobRowStyleIconPerState() {
        let states: [FilingJobState] = [.filing, .done, .failed, .cancelled]
        let icons = states.map { JobRowStyle.iconName(for: $0) }

        for icon in icons {
            XCTAssertFalse(icon.isEmpty, "iconName(for:) must return a non-empty SF Symbol name")
        }
        XCTAssertEqual(Set(icons).count, icons.count, "all four states must map to distinct icons (JOBS-01/D-01)")
    }

    // MARK: - tintColor(for:)

    func testJobRowStyleColorPerState() {
        XCTAssertEqual(JobRowStyle.tintColor(for: .filing), .blue)
        XCTAssertEqual(JobRowStyle.tintColor(for: .done), .green)
        XCTAssertEqual(JobRowStyle.tintColor(for: .failed), Color.amberStyle)
        XCTAssertEqual(JobRowStyle.tintColor(for: .cancelled), .secondary)
    }

    // MARK: - openableIssueURL(_:)

    func testOpenableIssueURLAcceptsHTTPS() {
        let url = JobRowStyle.openableIssueURL("https://github.com/o/r/issues/1")

        XCTAssertNotNil(url, "https URLs must be accepted")
        XCTAssertEqual(url?.absoluteString, "https://github.com/o/r/issues/1")
    }

    func testOpenableIssueURLRejectsNonHTTPS() {
        XCTAssertNil(JobRowStyle.openableIssueURL("http://github.com/o/r/issues/1"), "http (non-https) must be rejected")
        XCTAssertNil(JobRowStyle.openableIssueURL("javascript:alert(1)"), "javascript scheme must be rejected")
        XCTAssertNil(JobRowStyle.openableIssueURL("file:///etc/passwd"), "file scheme must be rejected")
        XCTAssertNil(JobRowStyle.openableIssueURL("not a url"), "unparseable input must return nil")
    }
}
