import XCTest
@testable import EntrixyCore

final class CameraVideoHTTPTests: XCTestCase {
    func testExpandedPlaylistCannotAllocateUnboundedResourceAddresses() throws {
        let body = Data(("#EXTM3U\n" + Array(repeating:"part.ts",count:200).joined(separator:"\n")).utf8)
        let expanded = URL(string:"http://127.0.0.1/")!.appendingPathComponent(String(repeating:"a",count:32000))
        XCTAssertThrowsError(try CameraHLSPlaylist.rewriting(body,base:URL(string:"https://camera.invalid/index.m3u8")!,resource:{ _ in expanded }))
    }
    func testPlaylistRewritesVariantsSegmentsAndKeysIncludingQueriesWithoutForwardingRawAddresses() throws {
        let original = Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"../secret/key?id=7\"\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio/index.m3u8\"\n#EXTINF:2,\npart.ts?token=private\n".utf8)
        var urls: [URL] = []
        let result = try CameraHLSPlaylist.rewriting(original,base:URL(string:"https://camera.invalid/video/index.m3u8")!) { url in urls.append(url); return URL(string:"http://127.0.0.1:1234/session/\(urls.count)")! }
        XCTAssertEqual(urls.map(\.absoluteString),["https://camera.invalid/secret/key?id=7","https://camera.invalid/video/audio/index.m3u8","https://camera.invalid/video/part.ts?token=private"])
        let text = String(decoding:result,as:UTF8.self)
        XCTAssertFalse(text.contains("camera.invalid")); XCTAssertFalse(text.contains("token=private")); XCTAssertTrue(text.contains("URI=\"http://127.0.0.1:1234/session/1\""))
    }
    func testPlaylistRejectsNonHTTPResourcesMalformedAttributesAndMissingHeader() throws {
        for body in ["not a playlist","#EXTM3U\nfile:///private/file", "#EXTM3U\n#EXT-X-KEY:URI=unquoted", "#EXTM3U\nhttps://user:password@camera.invalid/file", "#EXTM3U\n#EXT-X-KEY:URI=\"skd://key\""] {
            XCTAssertThrowsError(try CameraHLSPlaylist.rewriting(Data(body.utf8),base:URL(string:"https://camera.invalid/index.m3u8")!,resource:{ $0 }))
        }
    }
    func testPlayerRequestsAcceptOnlyReadMethodsAndSingleRangeWithoutRequestBodies() throws {
        let request = try CameraVideoHTTPRequest(Data("GET /opaque/segment.mp4 HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nRange: bytes=0-1\r\n\r\n".utf8))
        XCTAssertEqual(request.range,"bytes=0-1"); XCTAssertEqual(request.method,"GET"); XCTAssertEqual(request.path,"/opaque/segment.mp4")
        for header in ["Range: bytes=0-1,5-8","Range: bytes=bad","Content-Length: 5","Transfer-Encoding: chunked","Host: another-host"] {
            XCTAssertThrowsError(try CameraVideoHTTPRequest(Data(("GET /opaque/segment.mp4 HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n" + header + "\r\n\r\n").utf8)))
        }
        XCTAssertThrowsError(try CameraVideoHTTPRequest(Data("POST /opaque HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n".utf8)))
    }
}
