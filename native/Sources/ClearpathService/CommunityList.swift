import ClearpathCore
import Foundation

public struct CommunityListStatus: Codable, Equatable, Sendable {
    public let lastSuccess: Date
    public let sourceVersion: String

    func isDue(at now: Date) -> Bool {
        now < lastSuccess || now.timeIntervalSince(lastSuccess) >= 7 * 24 * 60 * 60
    }
}

struct CommunityListSource {
    static let hagezi = Self(
        url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt")!,
        minimumDomainCount: 25_000
    )
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumDomainCount = 200_000
    static let mixedSites: Set<String> = [
        "reddit.com", "redd.it", "redditmedia.com", "redditstatic.com",
        "x.com", "twitter.com", "t.co", "twimg.com", "tumblr.com",
    ]

    let url: URL
    let minimumDomainCount: Int

    static func validVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]{4}\.[0-9]{4}\.[0-9]{4}\.[0-9]{2}$"#, options: .regularExpression) != nil
    }

    func parse(_ data: Data) throws -> (version: String, domains: Set<String>) {
        let invalid = ServiceError.refused("The community list is incomplete, malformed or outside its size limits.")
        guard let text = String(data: data, encoding: .utf8) else { throw invalid }
        let lines = text.split(whereSeparator: \.isNewline)
        let header = lines.prefix { $0.hasPrefix("#") }
        let versions = header.filter { $0.hasPrefix("# Version: ") }
        let counts = header.filter { $0.hasPrefix("# Number of entries: ") }
        guard versions.count == 1, counts.count == 1,
              let count = Int(counts[0].dropFirst("# Number of entries: ".count)),
              (minimumDomainCount...Self.maximumDomainCount).contains(count) else { throw invalid }
        let version = String(versions[0].dropFirst("# Version: ".count))
        guard Self.validVersion(version) else { throw invalid }

        let rows = lines.dropFirst(header.count)
        guard rows.count == count else { throw invalid }
        var domains = Set<String>(minimumCapacity: count)
        for row in rows {
            guard row.utf8.count <= 254, let domain = try? Policy.domain(String(row)),
                  domains.insert(domain).inserted else { throw invalid }
        }
        return (version, domains)
    }

    func acceptedDomains(_ domains: Set<String>, previous: Policy) -> Set<String> {
        // Omit any source rule that would cover a configured SafeSearch name or target.
        var protectedRules: Set<String> = []
        for host in Array(previous.safeSearch.keys) + Array(previous.safeSearch.values) {
            var suffix = host[...]
            while let dot = suffix.firstIndex(of: ".") {
                protectedRules.insert(String(suffix))
                suffix = suffix[suffix.index(after: dot)...]
            }
        }
        return domains.filter { !protectedRules.contains($0) && !Policy.matches($0, rules: Self.mixedSites) }
    }

    func fetch() throws -> (version: String, domains: Set<String>) {
        try parse(CommunityListDownload.fetch(url))
    }

    func checkedDomains(_ domains: Set<String>, previous: Policy) throws -> Set<String> {
        let adult = acceptedDomains(domains, previous: previous)
        guard adult.count >= minimumDomainCount else {
            throw ServiceError.refused("Too few community domains remain after exclusions.")
        }
        return adult
    }
}

extension ServiceManager {
    func communityListPlist() throws -> Data {
        let plist: [String: Any] = [
            "Label": ServicePaths.communityListLabel,
            "ProgramArguments": [paths.controlTool.path, "refresh-community-list"],
            "RunAtLoad": true,
            "StartCalendarInterval": ["Minute": 0],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public func refreshCommunityList() throws {
        try refreshCommunityList(from: .hagezi, now: Date.init)
    }

    func refreshCommunityList(from source: CommunityListSource, now: () -> Date) throws {
        guard system.isRoot else { throw ServiceError.refused("The installed community list updater must run as root.") }
        guard let installation = try readRecord() else {
            throw ServiceError.refused("The Clearpath filter service is not installed.")
        }
        guard try readCommunityListStatus()?.isDue(at: now()) != false else { return }
        // Do the slow work before taking the policy writer's lock.
        let staged = try source.fetch()

        try withServiceLock {
            guard try readRecord() == installation else {
                throw ServiceError.refused("The Clearpath installation changed during the refresh.")
            }
            let checkedAt = now()
            let status = try readCommunityListStatus()
            guard status?.isDue(at: checkedAt) != false else { return }
            let policy = try installedPolicy()
            let adult = try source.checkedDomains(staged.domains, previous: policy)
            if let status {
                guard staged.version >= status.sourceVersion,
                      staged.version != status.sourceVersion || adult == policy.adult else {
                    throw ServiceError.refused("The community source returned an older or conflicting version.")
                }
            }
            if adult != policy.adult {
                if policy.adult.count >= source.minimumDomainCount {
                    let limit = policy.adult.count / 4
                    guard adult.subtracting(policy.adult).count <= limit,
                          policy.adult.subtracting(adult).count <= limit else {
                        throw ServiceError.refused("The community list changed too much since the installed version.")
                    }
                }
                try updateInstalledPolicy(policy) { $0["adult"] = adult.sorted() }
            }
            // A retry after an interrupted status write verifies the active list and leaves
            // an identical policy untouched. The timestamp advances only after promotion.
            let updated = CommunityListStatus(lastSuccess: checkedAt, sourceVersion: staged.version)
            try writeFile(try Self.encoder.encode(updated), to: paths.communityListStatus, mode: 0o644)
        }
    }

    func readCommunityListStatus() throws -> CommunityListStatus? {
        let file = paths.communityListStatus
        guard FileManager.default.fileExists(atPath: file.path) || isSymlink(file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard !isSymlink(file), let data = try? readRegularFile(file, what: "community list status"),
              let status = try? decoder.decode(CommunityListStatus.self, from: data),
              CommunityListSource.validVersion(status.sourceVersion) else {
            throw ServiceError.refused("The community list status is unreadable.")
        }
        return status
    }
}

/// Streams into a bounded buffer using one anonymous request to the configured origin.
private final class CommunityListDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    private var accepted = false
    private var succeeded = false

    static func fetch(_ url: URL) throws -> Data {
        let download = CommunityListDownload()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Clearpath", "Accept": "text/plain"]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        guard download.finished.wait(timeout: .now() + 31) == .success, download.succeeded else {
            throw ServiceError.failed("Could not download the community list from its configured source.")
        }
        return download.data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        completionHandler(method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        accepted = (response as? HTTPURLResponse)?.statusCode == 200 && response.mimeType == "text/plain" &&
            response.expectedContentLength <= Int64(CommunityListSource.maximumBytes)
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard accepted, chunk.count <= CommunityListSource.maximumBytes - data.count else {
            accepted = false
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        succeeded = accepted && error == nil
        finished.signal()
    }
}
