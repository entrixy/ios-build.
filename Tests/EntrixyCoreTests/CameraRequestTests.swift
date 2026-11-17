import XCTest
@testable import EntrixyCore

final class CameraRequestTests: XCTestCase {
    func testInlineCredentialsAreRemovedFromPlayerAddressAndExplicitAuthorizationWins() throws {
        var settings = config("https://user:password@camera.invalid/video.mp4")
        let request = try CameraRequest(configuration:settings)
        XCTAssertEqual(request.url.absoluteString,"https://camera.invalid/video.mp4")
        XCTAssertEqual(request.headers["Authorization"],"Basic " + Data("user:password".utf8).base64EncodedString()); XCTAssertTrue(request.authenticated)
        settings.authType = "bearer"; settings.authValue = "explicit-test-token"
        XCTAssertEqual(try CameraRequest(configuration:settings).headers["Authorization"],"Bearer explicit-test-token")
    }
    private func config(_ url: String = "https://camera.invalid/frame.jpg") -> ObjectCameraConfiguration {
        var config = ObjectCameraConfiguration(); config.enabled = true; config.url = url; return config
    }
    func testAndroidPlaceholdersAndAuthorizationNeverSendGuestSigningMaterial() throws {
        var config = config("https://camera.invalid/frame.jpg?token={token}&ts={ts}&key={key_id}")
        config.authType = "basic"; config.authValue = "user:password"
        let request = try CameraRequest(configuration:config,guestUserKey:"private-test-signing-material",localKeyID:"7",epoch:123)
        XCTAssertEqual(request.url.absoluteString,"https://camera.invalid/frame.jpg?token="+String(GuestCrypto.hash(Data("private-test-signing-material".utf8)).prefix(32))+"&ts=123&key=7")
        XCTAssertFalse(request.url.absoluteString.contains("private-test-signing-material"))
        XCTAssertEqual(request.headers["Authorization"],"Basic dXNlcjpwYXNzd29yZA==")
        config.authType = "bearer"; XCTAssertEqual(try CameraRequest(configuration:config).headers["Authorization"],"Bearer user:password")
        config.authType = "header"; config.authHeader = "X-Camera-Key"
        XCTAssertEqual(try CameraRequest(configuration:config).headers["X-Camera-Key"],"user:password")
    }
    func testRedirectCannotForwardCameraCredentialsToAnotherOriginOrDowngradeTLS() throws {
        let request = try CameraRequest(configuration:config())
        XCTAssertTrue(request.allowsRedirect(to:URL(string:"https://camera.invalid/other")!))
        for url in ["https://foreign.invalid/","http://camera.invalid/","https://camera.invalid:8443/","https://user:pass@camera.invalid/"] {
            XCTAssertFalse(request.allowsRedirect(to:URL(string:url)!))
        }
    }
    func testVideoAndMultipartDetectionUsesPathNotQueryAndPreservesConfiguration() throws {
        XCTAssertEqual(try CameraRequest(configuration:config("https://camera.invalid/live.M3U8?type=.jpg")).media,.nativeVideo)
        XCTAssertEqual(try CameraRequest(configuration:config("https://camera.invalid/frame.jpg?file=.m3u8")).media,.image)
        XCTAssertEqual(try CameraRequest(configuration:config("rtsp://camera.invalid/live")).media,.otherVideo)
        var multipart = config(); multipart.contentType = "mjpeg"
        XCTAssertEqual(try CameraRequest(configuration:multipart).media,.multipartJPEG)
        multipart.enabled = false; XCTAssertThrowsError(try CameraRequest(configuration:multipart))
    }
    func testMultipartFramesAreBoundedCompleteAndDoNotReturnHeadersOrPartialImage() throws {
        var parser = CameraJPEGFrames(maximumBytes:1024)
        let bytes = Data("Content-Type: image/jpeg\r\n\r\n".utf8)+Data([0xff,0xd8,0xff,0xda,0,2,1,2,0xff,0xd9])+Data("\r\n--boundary\r\n".utf8)+Data([0xff,0xd8,0xff,0xda,0,2,3,0xff,0xd9])
        var frames: [Data] = []
        for byte in bytes { if let frame = try parser.receive(byte) { frames.append(frame) } }
        XCTAssertEqual(frames,[Data([0xff,0xd8,0xff,0xda,0,2,1,2,0xff,0xd9]),Data([0xff,0xd8,0xff,0xda,0,2,3,0xff,0xd9])])
        XCTAssertNil(try parser.receive(0xff)); XCTAssertNil(try parser.receive(0xd8))
        for byte: UInt8 in [0xff,0xda,0,2] { XCTAssertNil(try parser.receive(byte)) }
        for _ in 0..<1018 { XCTAssertNil(try parser.receive(0)) }
        XCTAssertThrowsError(try parser.receive(0))
        var metadata = CameraJPEGFrames()
        // Embedded EXIF thumbnail EOI must not truncate the outer JPEG.
        let jpeg = Data([0xff,0xd8,0xff,0xe1,0,6,0xff,0xd8,0xff,0xd9,0xff,0xda,0,2,1,0xff,0,2,0xff,0xd9])
        var extracted: [Data] = []
        for byte in jpeg { if let frame = try metadata.receive(byte) { extracted.append(frame) } }
        XCTAssertEqual(extracted,[jpeg])
    }
}
