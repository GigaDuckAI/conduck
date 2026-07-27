// SPDX-License-Identifier: Apache-2.0

//
//  FileServerPropfindTests.swift
//  ConduckTests
//
//  Coverage for `FileServerClient.parsePropfindBody`.
//  The PROPFIND 207-multistatus parser is built + unit-tested now even though the
//  in-app directory browser is deferred to V1.1. The parser must be TOLERANT: it
//  never throws and returns `[]` on malformed / empty / non-XML input.
//
//  Privacy: fixtures are synthetic; nothing is logged.
//

import XCTest
@testable import Conduck

final class FileServerPropfindTests: XCTestCase {

    /// A minimal but realistic WebDAV 207 multistatus body (rclone serve webdav
    /// shape): one collection (the directory itself) + two files.
    private let sampleBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname></D:displayname>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/report.pdf</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>report.pdf</D:displayname>
            <D:getcontentlength>2048</D:getcontentlength>
            <D:resourcetype/>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/notes.txt</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>notes.txt</D:displayname>
            <D:getcontentlength>17</D:getcontentlength>
            <D:resourcetype/>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    func testParsesFileEntriesFromSample207Body() {
        let entries = FileServerClient.parsePropfindBody(Data(sampleBody.utf8))
        // At minimum the two real files must be discovered.
        let files = entries.filter { !$0.isDirectory }
        let names = Set(files.map { $0.name })
        XCTAssertTrue(names.contains("report.pdf"), "report.pdf must be parsed")
        XCTAssertTrue(names.contains("notes.txt"), "notes.txt must be parsed")

        if let report = files.first(where: { $0.name == "report.pdf" }) {
            XCTAssertEqual(report.byteSize, 2048, "getcontentlength must populate byteSize")
            XCTAssertFalse(report.isDirectory, "a plain file is not a directory")
        } else {
            XCTFail("expected report.pdf in parsed entries")
        }
    }

    func testMalformedXMLReturnsEmptyArrayAndDoesNotThrow() {
        // Truncated / broken markup must yield [] (tolerant, never throws).
        let malformed = Data("<D:multistatus><D:response><D:href>/x".utf8)
        XCTAssertEqual(FileServerClient.parsePropfindBody(malformed), [],
                       "malformed XML must return an empty array")
    }

    func testNonXMLReturnsEmptyArray() {
        let html = Data("<html><body>OpenClaw Control UI</body></html>".utf8)
        XCTAssertEqual(FileServerClient.parsePropfindBody(html), [],
                       "an HTML body (not a multistatus) yields no entries")
    }

    func testEmptyDataReturnsEmptyArray() {
        XCTAssertEqual(FileServerClient.parsePropfindBody(Data()), [],
                       "empty input must return an empty array")
    }

    func testGarbageBytesReturnEmptyArray() {
        let garbage = Data([0x00, 0xFF, 0x10, 0x42, 0x99])
        XCTAssertEqual(FileServerClient.parsePropfindBody(garbage), [],
                       "non-UTF8 garbage must return an empty array")
    }
}
