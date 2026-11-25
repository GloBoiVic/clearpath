import Foundation

struct PairingConfiguration: Decodable {
    let origin: String
    let ownerKey: String

    func client(allowFixtureHTTP: Bool = false) throws -> PairingClient {
        guard let parts = URLComponents(string: origin), let url = parts.url,
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (allowFixtureHTTP && parts.scheme == "http" && host == "127.0.0.1"),
              ownerKey.utf8.count == 43,
              ownerKey.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                                        (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ServiceError.refused("The pairing service configuration is invalid.")
        }
        return PairingClient(origin: url, ownerKey: ownerKey)
    }
}

struct PairingClient {
    let origin: URL
    private let ownerKey: String

    fileprivate init(origin: URL, ownerKey: String) {
        self.origin = origin
        self.ownerKey = ownerKey
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func authorizedRequest(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(ownerKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func sendCheckIn() async throws {
        struct CheckIn: Decodable {
            let revision: UUID
        }

        let endpoint = origin.appendingPathComponent("check-in")
        var request = authorizedRequest(to: endpoint)
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1024,
              let checkIn = try? JSONDecoder().decode(CheckIn.self, from: data) else {
            throw ServiceError.failed("The pairing service did not prepare the check-in.")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["revision": checkIn.revision.uuidString.lowercased()])
        let (_, confirmation) = try await Self.session.data(for: request)
        guard (confirmation as? HTTPURLResponse)?.statusCode == 204 else {
            throw ServiceError.failed("The pairing service did not confirm the check-in.")
        }
    }

    /// Check in on daemon startup and hourly. The continuous clock includes sleep;
    /// an overdue wait resumes when the Mac wakes.
    static func sendCheckIns(every interval: Duration = .seconds(3600),
                            client: () throws -> PairingClient) async {
        while !Task.isCancelled {
            // No configured service or a failed request leaves no local status or log.
            try? await client().sendCheckIn()
            try? await Task.sleep(for: interval, clock: .continuous)
        }
    }
}

extension ServiceManager {
    func pairingClient() throws -> PairingClient {
        let fd = open(paths.partnerConfig.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw ServiceError.refused("Site removal requests need a configured pairing service.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= 4096 else {
            throw ServiceError.refused("The pairing service configuration is invalid.")
        }
        return try decodePairingConfiguration(handle.read(upToCount: 4097) ?? Data()).client()
    }

    func decodePairingConfiguration(_ data: Data) throws -> PairingConfiguration {
        guard data.count <= 4096, let config = try? JSONDecoder().decode(PairingConfiguration.self, from: data) else {
            throw ServiceError.refused("The pairing service configuration is invalid.")
        }
        return config
    }
}
