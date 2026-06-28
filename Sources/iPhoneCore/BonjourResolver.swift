import Foundation

#if os(iOS)

/// Resolves a Bonjour service name (`_agentctl._tcp`) to a `URL` using `NetService`.
/// Used by the iPhone to discover the Mac's current LAN IP without hardcoding an address.
public final class BonjourResolver: NSObject, @unchecked Sendable {
    private static let serviceType = "_agentctl._tcp"
    private static let domain = "local."
    private static let resolveTimeoutSeconds: TimeInterval = 8

    /// Resolves the named Bonjour service and returns an `https://host:port` URL.
    /// Throws `BonjourResolverError` if the service cannot be found within the timeout.
    public static func resolve(serviceName: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = BonjourResolver(serviceName: serviceName, continuation: continuation)
            resolver.start()
            // Store resolver in associated object so it isn't deallocated before it fires.
            resolverStorage.set(resolver)
        }
    }

    // MARK: - Private

    private let service: NetService
    private let continuation: CheckedContinuation<URL, Error>
    private var hasResumed = false

    // Thread-safe storage to keep the resolver alive during async resolution.
    private static let resolverStorage = ResolverStorage()

    private init(serviceName: String, continuation: CheckedContinuation<URL, Error>) {
        self.service = NetService(domain: Self.domain, type: Self.serviceType, name: serviceName)
        self.continuation = continuation
        super.init()
        self.service.delegate = self
    }

    private func start() {
        // NetService requires a run loop; schedule on main.
        DispatchQueue.main.async { [self] in
            self.service.resolve(withTimeout: Self.resolveTimeoutSeconds)
        }
    }

    private func resume(with result: Result<URL, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        Self.resolverStorage.clear()
        continuation.resume(with: result)
    }
}

extension BonjourResolver: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName, sender.port > 0 else {
            resume(with: .failure(BonjourResolverError.noAddress))
            return
        }
        // NetService hostnames end with a trailing dot; strip it.
        let cleanHost = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        let url = URL(string: "https://\(cleanHost):\(sender.port)")!
        resume(with: .success(url))
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resume(with: .failure(BonjourResolverError.resolutionFailed(errorDict)))
    }
}

public enum BonjourResolverError: Error {
    case noAddress
    case resolutionFailed([String: NSNumber])
}

// A non-Sendable storage wrapper — only accessed from the private static, which is fine.
private final class ResolverStorage: @unchecked Sendable {
    private var resolver: BonjourResolver?
    private let lock = NSLock()

    func set(_ r: BonjourResolver) {
        lock.lock(); defer { lock.unlock() }
        resolver = r
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        resolver = nil
    }
}
#endif
