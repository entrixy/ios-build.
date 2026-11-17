import Foundation
import Combine
import Network
import EntrixyCore

/// The production composition boundary for server HTTPS/WSS only. This router
/// must be started before any live model request. Never routes camera/webhooks.
/// Not attached to LiveAppRoot until the complete route has passed Apple checks.
@MainActor final class ServerPrivacyRouter: ObservableObject {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var address: ServerPrivacyProxy.Address?
        private var ready = false
        private var restricted = false
        func update(address: ServerPrivacyProxy.Address?,ready: Bool,restricted: Bool) {
            lock.lock(); self.address = address; self.ready = ready; self.restricted = restricted; lock.unlock()
        }
        func configure(_ configuration: URLSessionConfiguration) {
            lock.lock(); let address = address; lock.unlock()
            if #available(iOS 17.0,*),let address { address.configure(configuration) }
        }
        func authorize(_ url: URL) throws {
            lock.lock(); let permitted = ready && (!restricted || address != nil); lock.unlock()
            guard permitted, ["https","wss"].contains(url.scheme?.lowercased() ?? "") else {
                throw GuestAPI.Failure(status:0,code:"network_policy_blocked")
            }
        }
    }
    @Published private(set) var ready = false
    @Published private(set) var message: String?
    @Published private(set) var route = ServerNetworkRoute.blocked
    private let gate = Gate()
    private var proxy: ServerPrivacyProxy?
    private var address: ServerPrivacyProxy.Address?
    private var monitor: NWPathMonitor?
    private var cellularPath = false
    private var restricted = false
    private var cellularAuthorized = false
    private var starting = false
    private var generation = UUID()
    private var installed = false
    private let connector: ServerPrivacyProxy.Connect?
    init(connect: ServerPrivacyProxy.Connect? = nil) { connector = connect }
    var supportsConstrainedRouting: Bool { if #available(iOS 17.0,*) { return true }; return false }

    func start() async -> Bool {
        if ready { return true }
        guard !starting else { return false }
        starting = true; message = nil
        let attempt = UUID(); generation = attempt
        if !installed {
            let gate = gate
            ServerSessionPolicy.shared.install({ gate.configure($0) },authorize:{ try gate.authorize($0) },networkPrivacyEnforced:true)
            installed = true
        }
        defer { if generation == attempt { starting = false } }
        do {
            if #available(iOS 17.0,*) {
                let next = try ServerPrivacyProxy(decide:{ [weak self] _ in self?.effectiveRoute ?? .blocked },connect:connector)
                proxy = next
                let value = try await next.start()
                guard generation == attempt, !Task.isCancelled else { next.stop(); return false }
                address = value
            }
            ready = true
            gate.update(address:address,ready:true,restricted:restricted)
            ServerSessionPolicy.shared.resetSessions()
            let monitor = NWPathMonitor(); self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let cellular = path.status == .satisfied && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
                Task { @MainActor in
                    guard let self,self.generation == attempt else { return }
                    self.cellularPath = cellular; self.recheck()
                }
            }
            monitor.start(queue:DispatchQueue(label:"com.entrixy.server.route"))
            recheck(); return true
        } catch {
            guard generation == attempt else { return false }
            proxy?.stop(); proxy = nil; address = nil
            gate.update(address:nil,ready:false,restricted:restricted)
            route = .blocked
            message = "Не удалось подготовить защищённое подключение. Повторите попытку."
            return false
        }
    }
    func update(restricted: Bool,cellularAuthorized: Bool) {
        let changed = self.restricted != restricted || self.cellularAuthorized != cellularAuthorized
        self.restricted = restricted; self.cellularAuthorized = cellularAuthorized
        gate.update(address:address,ready:ready,restricted:restricted)
        recheck()
        if changed && installed { ServerSessionPolicy.shared.resetSessions() }
    }
    private var effectiveRoute: ServerNetworkRoute {
        guard ready else { return .blocked }
        guard restricted else { return .system }
        guard supportsConstrainedRouting else { return .blocked }
        // Public iOS TCP APIs cannot pin a tunnel to one SSID across Wi-Fi
        // roaming. When any home-network rule exists, pin all server tunnels
        // to cellular. Never infer safety from a one-time SSID observation.
        return cellularAuthorized || cellularPath ? .cellular : .blocked
    }
    private func recheck() {
        route = effectiveRoute
        proxy?.restrict(to:route)
    }
    func stop() {
        generation = UUID(); starting = false; ready = false
        monitor?.cancel(); monitor = nil
        proxy?.stop(); proxy = nil; address = nil; route = .blocked
        gate.update(address:nil,ready:false,restricted:restricted)
        if installed { ServerSessionPolicy.shared.resetSessions() }
    }
}
