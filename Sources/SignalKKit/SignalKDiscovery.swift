import Foundation

public final class SignalKDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let wsBrowser = NetServiceBrowser()
    private let httpBrowser = NetServiceBrowser()
    private let legacyBrowser = NetServiceBrowser()

    @Published public var discoveredServices: [NetService] = []

    public override init() {
        super.init()
        [wsBrowser, httpBrowser, legacyBrowser].forEach { $0.delegate = self }
    }

    public func startBrowsing() {
        // Signal K commonly advertises WebSocket as _signalk-ws._tcp and HTTP as _signalk-http._tcp.
        // Some older installs use _sk._tcp.
        wsBrowser.searchForServices(ofType: "_signalk-ws._tcp.", inDomain: "local.")
        httpBrowser.searchForServices(ofType: "_signalk-http._tcp.", inDomain: "local.")
        legacyBrowser.searchForServices(ofType: "_sk._tcp.", inDomain: "local.")
    }

    public func stopBrowsing() {
        [wsBrowser, httpBrowser, legacyBrowser].forEach { $0.stop() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        // Avoid duplicates across browsers
        if !discoveredServices.contains(where: { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }) {
            discoveredServices.append(service)
        }
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let idx = discoveredServices.firstIndex(where: { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }) {
            discoveredServices.remove(at: idx)
        }
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        // Replace the entry to trigger SwiftUI onChange observers
        DispatchQueue.main.async {
            if let idx = self.discoveredServices.firstIndex(where: { $0.name == sender.name && $0.type == sender.type && $0.domain == sender.domain }) {
                self.discoveredServices[idx] = sender
            } else {
                self.discoveredServices.append(sender)
            }
        }
    }
}
