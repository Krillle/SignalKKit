import XCTest
import Combine
import Starscream
@testable import SignalKKit

final class SignalKKitTests: XCTestCase {
    func testAccessAuthorizationStateIsMissingBeforeServerConfiguration() {
        let client = SignalKAPIClient()

        XCTAssertEqual(client.accessAuthorizationState, .missing)
    }

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

    func testInvalidatingUnauthorizedTokenPreservesClientIdentifier() async throws {
        let client = SignalKAPIClient()
        let host = "unauthorized-\(UUID().uuidString.lowercased()).local"
        let url = try XCTUnwrap(URL(string: "http://\(host):3000"))
        let tokenKey = try XCTUnwrap(
            SignalKAPIClient.serverScopedStorageKey(for: "accessToken", baseURL: url)
        )
        UserDefaults.standard.set("stale-token", forKey: tokenKey)
        defer { UserDefaults.standard.removeObject(forKey: tokenKey) }

        client.setBaseURL(url)
        let clientIdentifier = client.accessRequestClientIdentifier
        XCTAssertEqual(client.accessAuthorizationState, .authorized)

        let invalidatedToken = await client.invalidateStoredAccessTokenIfPresent()
        XCTAssertTrue(invalidatedToken)
        XCTAssertEqual(client.accessAuthorizationState, .missing)
        XCTAssertEqual(client.accessRequestClientIdentifier, clientIdentifier)
    }

    func testDeltaPublishesValuesOnceWithPerUpdateTimestamps() throws {
        let client = SignalKClient()
        let socket = WebSocketClientStub()
        let published = expectation(description: "Published complete delta")
        published.assertForOverFulfill = true
        var publishedValueCount = 0
        var cancellables = Set<AnyCancellable>()

        client.$pathValues
            .dropFirst()
            .sink { values in
                publishedValueCount += 1
                if values.count == 6 {
                    published.fulfill()
                }
            }
            .store(in: &cancellables)

        client.didReceive(
            event: .text(
                """
                {
                  "context": "vessels.self",
                  "updates": [
                    {
                      "timestamp": "2026-07-30T00:00:00.123Z",
                      "values": [
                        { "path": "navigation.headingTrue", "value": 1.25 },
                        { "path": "navigation.speedOverGround", "value": 2.5 }
                      ]
                    },
                    {
                      "timestamp": "2026-07-30T00:00:01Z",
                      "values": [
                        { "path": "environment.water.temperature", "value": 293.15 }
                      ]
                    }
                  ]
                }
                """
            ),
            client: socket
        )

        wait(for: [published], timeout: 1)

        XCTAssertEqual(publishedValueCount, 1)
        XCTAssertEqual(doubleValue(client.pathValues["navigation.headingTrue"]), 1.25)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.navigation.headingTrue"]), 1.25)
        XCTAssertEqual(doubleValue(client.pathValues["navigation.speedOverGround"]), 2.5)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.navigation.speedOverGround"]), 2.5)
        XCTAssertEqual(doubleValue(client.pathValues["environment.water.temperature"]), 293.15)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.environment.water.temperature"]), 293.15)

        let fractionalDate = try XCTUnwrap(
            ISO8601DateFormatter.date(
                from: "2026-07-30T00:00:00.123Z",
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            )
        )
        let plainDate = try XCTUnwrap(
            ISO8601DateFormatter.date(
                from: "2026-07-30T00:00:01Z",
                formatOptions: [.withInternetDateTime]
            )
        )
        XCTAssertEqual(client.pathTimestamps["navigation.headingTrue"], fractionalDate)
        XCTAssertEqual(client.pathTimestamps["navigation.speedOverGround"], fractionalDate)
        XCTAssertEqual(client.pathTimestamps["environment.water.temperature"], plainDate)
    }

    func testConnectionDiagnosticsPreserveStarscreamFailureDetails() throws {
        let client = SignalKClient()
        let socket = WebSocketClientStub()

        client.didReceive(
            event: .disconnected("Handshake rejected", 1002),
            client: socket
        )
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket disconnected code=1002 reason=Handshake rejected"
        )

        let error = WSError(
            type: .serverError,
            message: "Upgrade failed",
            code: 400
        )
        client.didReceive(event: .error(error), client: socket)
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket error type=serverError code=400 description=Upgrade failed"
        )

        client.didReceive(
            event: .error(
                HTTPUpgradeError.notAnUpgrade(
                    302,
                    [
                        "location": "/login",
                        "server": "Signal K",
                        "x-private-header": "must not be logged"
                    ]
                )
            ),
            client: socket
        )
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket HTTP upgrade rejected status=302 headers=location=/login,server=Signal K"
        )
    }

    private func doubleValue(_ value: CodableValue?) -> Double? {
        value?.doubleValue()
    }
}

private final class WebSocketClientStub: WebSocketClient {
    func connect() {}
    func disconnect(closeCode: UInt16) {}
    func write(string: String, completion: (() -> Void)?) {}
    func write(stringData: Data, completion: (() -> Void)?) {}
    func write(data: Data, completion: (() -> Void)?) {}
    func write(ping: Data, completion: (() -> Void)?) {}
    func write(pong: Data, completion: (() -> Void)?) {}
}

private extension ISO8601DateFormatter {
    static func date(from string: String, formatOptions: Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
        return formatter.date(from: string)
    }
}
