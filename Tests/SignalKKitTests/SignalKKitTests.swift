import XCTest
@testable import SignalKKit

final class SignalKKitTests: XCTestCase {
    func testServerScopedStorageKeyIncludesNormalizedHostAndPort() throws {
        let url = try XCTUnwrap(URL(string: "https://SignalK.local:3443"))

        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "accessToken", baseURL: url),
            "SignalKKit.signalk.local:3443.accessToken"
        )
        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "pendingHref", baseURL: url),
            "SignalKKit.signalk.local:3443.pendingHref"
        )
        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "deniedState", baseURL: url),
            "SignalKKit.signalk.local:3443.deniedState"
        )
    }

    func testServerIdentifierUsesDefaultPortWhenURLOmitsPort() throws {
        let httpURL = try XCTUnwrap(URL(string: "http://SIGNALK.local"))
        let httpsURL = try XCTUnwrap(URL(string: "https://SIGNALK.local"))

        XCTAssertEqual(SignalKAPIClient.normalizedServerIdentifier(for: httpURL), "signalk.local:80")
        XCTAssertEqual(SignalKAPIClient.normalizedServerIdentifier(for: httpsURL), "signalk.local:443")
    }
}
