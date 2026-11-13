import XCTest
@testable import EntrixyCore

final class GuestBLECacheTests: XCTestCase {
    func testCacheIsAuthenticatedPreservesRevisionAndRejectsReplayAfterRelaunch() throws {
        let key = Data(repeating: 9, count: 32)
        let bundle = Data(#"{"ble":[],"obj_ids":[]}"#.utf8)
        let snapshot = Data(#"{"numbers":[]}"#.utf8)
        var cache = try GuestBLECache(bundle: bundle, snapshot: snapshot, key: key, epoch: 1000)
        let revision = cache.revision, cipher = cache.cipher
        XCTAssertFalse(cipher.contains("numbers"))
        XCTAssertEqual(try cache.open(key: key).bundle, bundle)
        XCTAssertThrowsError(try cache.open(key: Data(repeating: 8, count: 32)))
        try cache.refresh(bundle: bundle, snapshot: snapshot, key: key, epoch: 900)
        XCTAssertEqual(cache.revision, revision); XCTAssertEqual(cache.cipher, cipher)
        XCTAssertEqual(cache.maximumEpoch, 1000)
        let proof = String(repeating: "a", count: 64)
        try cache.consume(proof: proof, epoch: 1100)
        var restored = try JSONDecoder().decode(GuestBLECache.self, from: JSONEncoder().encode(cache))
        XCTAssertThrowsError(try restored.consume(proof: proof, epoch: 900))
        XCTAssertEqual(restored.maximumEpoch, 1100)
        try restored.refresh(bundle: Data(#"{"ble":[],"obj_ids":[],"welcome":"updated"}"#.utf8), snapshot: snapshot, key: key, epoch: 1000)
        XCTAssertNotEqual(restored.revision, revision)
        XCTAssertEqual(restored.usedProofs, [proof])
        XCTAssertThrowsError(try restored.consume(proof: "bad", epoch: 1000))
    }
    func testCacheBoundsAndPolicyFailuresNeverReplaceAuthenticatedMaterial() throws {
        let key = Data(repeating: 9, count: 32)
        let bundle = Data(#"{"ble":[]}"#.utf8), snapshot = Data(#"{"numbers":[]}"#.utf8)
        var cache = try GuestBLECache(bundle: bundle, snapshot: snapshot, key: key, epoch: 1000)
        let cipher = cache.cipher, revision = cache.revision
        XCTAssertThrowsError(try cache.refresh(bundle: Data(#"{"net_block":["restricted"]}"#.utf8), snapshot: snapshot, key: key, epoch: 1100))
        XCTAssertEqual(cache.cipher, cipher); XCTAssertEqual(cache.revision, revision)
        XCTAssertThrowsError(try GuestBLECache(bundle: Data(count: 1_048_577), snapshot: snapshot, key: key, epoch: 1000))
    }
}
