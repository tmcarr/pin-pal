import Foundation

public enum APIError: Error {
    case notAuthorized
}

extension HumaneCenterService {
    actor Service {
        private var accessToken: String? {
            didSet {
                UserDefaults.standard.setValue(accessToken, forKey: Constant.ACCESS_TOKEN)
            }
        }
        private var lastSessionUpdate: Date?
        private let decoder: JSONDecoder
        private let encoder = JSONEncoder()
        private let session: URLSession
        private let userDefaults: UserDefaults

        public init(
            userDefaults: UserDefaults = .standard
        ) {
            self.session = .shared
            self.userDefaults = userDefaults
            let decoder = JSONDecoder()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSX"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            decoder.dateDecodingStrategy = .formatted(dateFormatter)
            self.decoder = decoder
        }
        
        private func get<D: Decodable>(url: URL) async throws -> D {
            try await refreshIfNeeded()
            return try await decoder.decode(D.self, from: data(for: makeRequest(url: url)))
        }
        
        private func post<D: Decodable>(url: URL, body: (any Encodable)? = nil) async throws -> D {
            try await refreshIfNeeded()
            var request = try makeRequest(url: url)
            request.httpMethod = "POST"
            if let body {
                request.httpBody = try encoder.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "content-type")
            }
            return try await decoder.decode(D.self, from: data(for: request))
        }
        
        private func post(url: URL, body: (any Encodable)? = nil) async throws {
            try await refreshIfNeeded()
            var request = try makeRequest(url: url)
            request.httpMethod = "POST"
            if let body {
                request.httpBody = try encoder.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "content-type")
            }
            let _ = try await data(for: request)
        }
        
        private func delete<D: Decodable>(url: URL) async throws -> D {
            try await refreshIfNeeded()
            var req = try makeRequest(url: url)
            req.httpMethod = "DELETE"
            return try await decoder.decode(D.self, from: data(for: req))
        }
        
        private func unauthenticatedRequest<D: Decodable>(url: URL) async throws -> D {
            try await decoder.decode(D.self, from: data(for: makeRequest(url: url, skipsAuth: true)))
        }
        
        private func data(for request: URLRequest) async throws -> Data {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...304).contains(response.statusCode) else {
                throw APIError.notAuthorized
            }
            return data
        }
        
        private func makeRequest(url: URL, skipsAuth: Bool = false) throws -> URLRequest {
            var req = URLRequest(url: url)
            if !skipsAuth {
                guard let accessToken else {
                    throw APIError.notAuthorized
                }
                req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            }
            return req
        }
        
        public func refreshIfNeeded() async throws {
            let accessToken = try await session().accessToken
            self.accessToken = accessToken
            self.lastSessionUpdate = .now
        }
        
        func session() async throws -> Session {
            try await unauthenticatedRequest(url: sessionUrl)
        }
        
        public func captures(page: Int = 0, size: Int = 10, sort: String = "userCreatedAt,DESC", onlyContainingFavorited: Bool = false) async throws -> PageableMemoryContentEnvelope {
            try await get(url: captureUrl.appending(path: "captures").appending(queryItems: [
                .init(name: "page", value: String(page)),
                .init(name: "size", value: String(size)),
                .init(name: "sort", value: sort),
                .init(name: "onlyContainingFavorited", value: onlyContainingFavorited ? "true" : "false")
            ]))
        }
        
        public func events(domain: EventDomain, page: Int = 0, size: Int = 10, sort: String = "eventCreationTime,ASC") async throws -> PageableEventContentEnvelope {
            try await get(url: eventsUrl.appending(path: "mydata").appending(queryItems: [
                .init(name: "domain", value: domain.rawValue),
                .init(name: "page", value: String(page)),
                .init(name: "size", value: String(size)),
                .init(name: "sort", value: sort)
            ]))
        }

        public func favorite(memory: ContentEnvelope) async throws {
            try await post(url: memoryUrl.appending(path: memory.uuid.uuidString).appending(path: "favorite"))
        }
        
        public func unfavorite(memory: ContentEnvelope) async throws {
            try await post(url: memoryUrl.appending(path: memory.uuid.uuidString).appending(path: "unfavorite"))
        }
        
        public func notes(page: Int = 0, size: Int = 10) async throws -> PageableMemoryContentEnvelope {
            try await get(url: captureUrl.appending(path: "notes").appending(queryItems: [
                .init(name: "page", value: String(page)),
                .init(name: "size", value: String(size))
            ]))
        }
        
        public func create(note: Note) async throws -> ContentEnvelope {
            try await post(url: noteUrl.appending(path: "create"), body: note)
        }
        
        public func update(id: String, with note: Note) async throws -> ContentEnvelope {
            try await post(url: noteUrl.appending(path: id), body: note)
        }
        
        public func subscription() async throws -> Subscription {
            try await get(url: subscriptionV3Url)
        }
        
        public func featureFlag(name: String) async throws -> FeatureFlagEnvelope {
            try await get(url: featureFlagsUrl.appending(path: name))
        }
        
        public func retrieveDetailedDeviceInfo() async throws -> DetailedDeviceInfo {
            let d = try await URLSession.shared.data(from: URL(string: "https://humane.center/account/devices")!).0
            let string = String(data: d, encoding: .utf8)!

            return DetailedDeviceInfo(
                id: extractValue(from: string, forKey: "deviceID") ?? "UNKNOWN",
                iccid: extractValue(from: string, forKey: "iccid") ?? "UNKNOWN",
                serialNumber: extractValue(from: string, forKey: "deviceSerialNumber") ?? "UNKNOWN",
                sku: extractValue(from: string, forKey: "sku") ?? "UNKNOWN",
                color: extractValue(from: string, forKey: "deviceColor") ?? "UNKNOWN"
            )
        }
        
        public func delete(memory: ContentEnvelope) async throws -> String {
            try await delete(url: memoryUrl.appending(path: memory.uuid.uuidString))
        }
    }
    
    public static func live() -> Self {
        let service = Service()
        return Self(
            session: { try await service.session() },
            notes: { try await service.notes(page: $0, size: $1) },
            captures: { try await service.captures(page: $0, size: $1) },
            events: { try await service.events(domain: $0, size: $1) },
            featureFlag: { try await service.featureFlag(name: $0) },
            subscription: { try await service.subscription() },
            detailedDeviceInformation: { try await service.retrieveDetailedDeviceInfo() },
            create: { try await service.create(note: $0) },
            update: { try await service.update(id: $0, with: $1) },
            favorite: { try await service.favorite(memory: $0) },
            unfavorite: { try await service.unfavorite(memory: $0) },
            delete: { try await service.delete(memory: $0) }
        )
    }
}

@Observable public class HumaneCenterService {
    public static let shared = HumaneCenterService.live
    
    private static let rootUrl = URL(string: "https://webapi.prod.humane.cloud/")!
    private static let captureUrl = rootUrl.appending(path: "capture")
    private static let memoryUrl = rootUrl.appending(path: "capture").appending(path: "memory")
    private static let noteUrl = rootUrl.appending(path: "capture").appending(path: "note")
    private static let aiBusUrl = rootUrl.appending(path: "ai-bus")
    private static let deviceAssignmentUrl = rootUrl.appending(path: "device-assignments")
    private static let eventsUrl = rootUrl.appending(path: "notable-events")
    private static let subscriptionUrl = rootUrl.appending(path: "subscription")
    private static let subscriptionV3Url = rootUrl.appending(path: "subscription/v3/subscription")
    private static let addonsUrl = rootUrl.appending(path: "subscription/addons")
    private static let featureFlagsUrl = rootUrl.appending(path: "feature-flags/v0/feature-flag/flags")

    static let sessionUrl = URL(string: "https://humane.center/api/auth/session")!
    
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private let userDefaults: UserDefaults
    private let sessionTimeout: TimeInterval = 60 * 5 // 5 min
    
    private var accessToken: String? {
        UserDefaults.standard.string(forKey: Constant.ACCESS_TOKEN)
    }
    
    private var lastSessionUpdate: Date?
    
    public var session: () async throws -> Session
    public var notes: (Int, Int) async throws -> PageableMemoryContentEnvelope
    public var captures: (Int, Int) async throws -> PageableMemoryContentEnvelope
    public var events: (EventDomain, Int) async throws -> PageableEventContentEnvelope
    public var featureFlag: (String) async throws -> FeatureFlagEnvelope
    public var subscription: () async throws -> Subscription
    public var detailedDeviceInformation: () async throws -> DetailedDeviceInfo
    public var create: (Note) async throws -> ContentEnvelope
    public var update: (String, Note) async throws -> ContentEnvelope
    public var favorite: (ContentEnvelope) async throws -> Void
    public var unfavorite: (ContentEnvelope) async throws -> Void
    public var delete: (ContentEnvelope) async throws -> Void

    required public init(
        accessToken: String? = nil,
        userDefaults: UserDefaults = .standard,
        session: @escaping () async throws -> Session,
        notes: @escaping (Int, Int) async throws -> PageableMemoryContentEnvelope,
        captures: @escaping (Int, Int) async throws -> PageableMemoryContentEnvelope,
        events: @escaping (EventDomain, Int) async throws -> PageableEventContentEnvelope,
        featureFlag: @escaping (String) async throws -> FeatureFlagEnvelope,
        subscription: @escaping () async throws -> Subscription,
        detailedDeviceInformation: @escaping () async throws -> DetailedDeviceInfo,
        create: @escaping (Note) async throws -> ContentEnvelope,
        update: @escaping (String, Note) async throws -> ContentEnvelope,
        favorite: @escaping (ContentEnvelope) async throws -> Void,
        unfavorite: @escaping (ContentEnvelope) async throws -> Void,
        delete: @escaping (ContentEnvelope) async throws -> Void
    ) {
        self.userDefaults = userDefaults
        let decoder = JSONDecoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSX"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        self.decoder = decoder
        self.session = session
        self.notes = notes
        self.captures = captures
        self.events = events
        self.featureFlag = featureFlag
        self.subscription = subscription
        self.detailedDeviceInformation = detailedDeviceInformation
        self.create = create
        self.update = update
        self.favorite = favorite
        self.unfavorite = unfavorite
        self.delete = delete
    }
    
    public func isLoggedIn() -> Bool {
        self.accessToken != nil // TODO: also check cookies
    }
}

func extractValue(from text: String, forKey key: String) -> String? {
    let pattern = #"\\"\#(key)\\"[:]\\"([^"]+)\\""#
    
    let regex = try? NSRegularExpression(pattern: pattern, options: [])
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    
    if let match = regex?.firstMatch(in: text, options: [], range: nsRange) {
        if let valueRange = Range(match.range(at: 1), in: text) {
            return String(text[valueRange])
        }
    }
    
    return nil
}

// Note: Commented out because they aren't currently used, but will be used and are thus a useful reference
//
//extension HumaneCenterService {
//    
//    func capturesList(for uuids: [UUID]) async throws -> Bool {
//        try await get(url: Self.captureUrl.appending(path: "captures").appending(path: "list").appending(queryItems: [
//            .init(name: "uuid", value: uuids.map(\.uuidString).joined(separator: ","))
//        ]))
//    }
//    
//    func memory(id: String) async throws -> Bool {
//        try await get(url: Self.memoryUrl.appending(path: id, directoryHint: .notDirectory))
//    }
//    
//    func delete(memoryId: UUID) async throws -> String {
//        try await delete(url: Self.memoryUrl.appending(path: memoryId.uuidString))
//    }
//    
//    func search(query: String, page: Int = 0, size: Int = 10, sort: String = "createdAt,DESC") async throws -> Bool {
//        try await get(url: Self.captureUrl.appending(path: "search").appending(queryItems: [
//            .init(name: "query", value: query),
//            .init(name: "page", value: String(page)),
//            .init(name: "size", value: String(size)),
//            .init(name: "sort", value: sort)
//        ]))
//    }
//    
//    func search(query: String, domain: Domain) async throws -> String {
//        try await get(url: Self.aiBusUrl.appending(path: "search").appending(queryItems: [
//            .init(name: "query", value: query),
//            .init(name: "domain", value: domain.rawValue)
//        ]))
//    }
//    
//    func deviceIdentifiers() async throws -> [String] {
//        try await get(url: Self.deviceAssignmentUrl.appending(path: "devices"))
//    }
//    

//
//    
//    func memoryOriginals(for id: String) async throws -> ResponseContainer {
//        try await get(url: Self.memoryUrl.appending(path: id).appending(path: "originals"))
//    }
//        
//    func index(memory id: String) async throws -> ResponseContainer {
//        try await post(url: Self.memoryUrl.appending(path: id).appending(path: "index"))
//    }
//    
//    func tag(memory id: String) async throws -> ResponseContainer {
//        try await post(url: Self.memoryUrl.appending(path: id).appending(path: "tag"))
//    }
//    
//    func remove(tag id: String, from memory: String) async throws -> ResponseContainer {
//        try await delete(url: Self.memoryUrl.appending(path: id).appending(path: "tag"))
//    }
//    
//    // TODO: wtf does this even mean
//    func save(search: String) async throws -> Bool {
//        try await get(url: Self.captureUrl.appending(path: "search").appending(path: "save"))
//    }
//        
//    func memories() async throws -> MemoriesResponse {
//        try await get(url: Self.captureUrl.appending(path: "memories"))
//    }
//    
//    
//    func deleteAllNotes() async throws -> Bool {
//        try await delete(url: Self.noteUrl)
//    }
//    
//    // TODO: result is wrong
//    func delete(event id: String) async throws -> Bool {
//        try await delete(url: Self.eventsUrl.appending(path: "event").appending(path: id, directoryHint: .notDirectory))
//    }
//
//    func eventsOverview() async throws -> EventOverview {
//        try await get(url: Self.eventsUrl.appending(path: "mydata").appending(path: "overview"))
//    }
//    
//    func memoryDerivatives(for id: String) async throws -> ResponseContainer {
//        try await get(url: Self.memoryUrl.appending(path: id).appending(path: "derivatives"))
//    }
//    
//    
//    // TODO: use correct method
//    func pauseSubscription() async throws -> Bool {
//        try await get(url: Self.subscriptionV3Url)
//    }
//    
//    // TODO: use correct method
//    func unpauseSubscription() async throws -> Bool {
//        try await get(url: Self.subscriptionV3Url)
//    }
//    
//    // has a postable version
//    func addons() async throws -> [Addon] {
//        try await get(url: Self.addonsUrl)
//    }
//    
//    func delete(addon: Addon) async throws -> Bool {
//        try await delete(url: Self.addonsUrl.appending(path: addon.spid))
//    }
//    
//    func availableAddons() async throws -> [Addon] {
//        try await get(url: Self.addonsUrl.appending(path: "types"))
//    }
//    
//    func lostStatus(deviceId: String) async throws -> LostDeviceResponse {
//        try await get(url: Self.subscriptionUrl.appending(path: "deviceAuthorization").appending(path: "lostDevice").appending(queryItems: [
//            .init(name: "deviceId", value: deviceId)
//        ]))
//    }
//}
