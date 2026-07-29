import XCTest
import Combine
import Starscream
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
