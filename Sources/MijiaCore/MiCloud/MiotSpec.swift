import Foundation
import os

// MARK: - MIoT Spec Model (miot-spec.org instance JSON)

/// Segment 3 of a MIoT URN (`urn:miot-spec-v2:property:brightness:0000000D:...` → `brightness`).
func miotShortName(_ urn: String) -> String {
    let parts = urn.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count > 3 ? String(parts[3]) : urn
}

public struct MiotValueListItem: Codable, Equatable, Sendable {
    public var value: Int
    public var description: String

    public init(value: Int, description: String) {
        self.value = value
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .value) {
            value = i
        } else {
            value = Int(try c.decode(Double.self, forKey: .value))
        }
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }
}

public struct MiotProperty: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?
    public var format: String
    public var access: [String]
    public var valueRange: [Double]?
    public var valueList: [MiotValueListItem]?
    public var unit: String?

    enum CodingKeys: String, CodingKey {
        case iid, type, description, format, access, unit
        case valueRange = "value-range"
        case valueList = "value-list"
    }

    public init(
        iid: Int, type: String, description: String? = nil, format: String, access: [String],
        valueRange: [Double]? = nil, valueList: [MiotValueListItem]? = nil, unit: String? = nil
    ) {
        self.iid = iid
        self.type = type
        self.description = description
        self.format = format
        self.access = access
        self.valueRange = valueRange
        self.valueList = valueList
        self.unit = unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try? c.decode(String.self, forKey: .description)
        format = (try? c.decode(String.self, forKey: .format)) ?? "string"
        access = (try? c.decode([String].self, forKey: .access)) ?? []
        valueRange = try? c.decode([Double].self, forKey: .valueRange)
        valueList = try? c.decode([MiotValueListItem].self, forKey: .valueList)
        unit = try? c.decode(String.self, forKey: .unit)
    }

    public var shortName: String { miotShortName(type) }
    public var isReadable: Bool { access.contains("read") }
    public var isWritable: Bool { access.contains("write") }
    public var rangeMin: Double? { valueRange.flatMap { $0.count >= 2 ? $0[0] : nil } }
    public var rangeMax: Double? { valueRange.flatMap { $0.count >= 2 ? $0[1] : nil } }
    public var rangeStep: Double? { valueRange.flatMap { $0.count >= 3 ? $0[2] : nil } }
    public var isIntegerFormat: Bool { format.hasPrefix("int") || format.hasPrefix("uint") }

    public func description(forValue v: Int) -> String? {
        valueList?.first { $0.value == v }?.description
    }
}

public struct MiotAction: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?

    public init(iid: Int, type: String, description: String? = nil) {
        self.iid = iid
        self.type = type
        self.description = description
    }

    public var shortName: String { miotShortName(type) }
}

public struct MiotService: Codable, Equatable, Sendable {
    public var iid: Int
    public var type: String
    public var description: String?
    public var properties: [MiotProperty]
    public var actions: [MiotAction]

    enum CodingKeys: String, CodingKey { case iid, type, description, properties, actions }

    public init(iid: Int, type: String, description: String? = nil, properties: [MiotProperty] = [], actions: [MiotAction] = []) {
        self.iid = iid
        self.type = type
        self.description = description
        self.properties = properties
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = try c.decode(Int.self, forKey: .iid)
        type = try c.decode(String.self, forKey: .type)
        description = try? c.decode(String.self, forKey: .description)
        properties = (try? c.decode([MiotProperty].self, forKey: .properties)) ?? []
        actions = (try? c.decode([MiotAction].self, forKey: .actions)) ?? []
    }

    public var shortName: String { miotShortName(type) }

    public func property(named name: String) -> MiotProperty? {
        properties.first { $0.shortName == name }
    }

    public func action(named name: String) -> MiotAction? {
        actions.first { $0.shortName == name }
    }
}

public struct MiotDeviceSpec: Codable, Equatable, Sendable {
    public var type: String
    public var description: String?
    public var services: [MiotService]

    public init(type: String, description: String? = nil, services: [MiotService]) {
        self.type = type
        self.description = description
        self.services = services
    }

    public var shortName: String { miotShortName(type) }

    public func service(iid: Int) -> MiotService? {
        services.first { $0.iid == iid }
    }

    public func services(named name: String) -> [MiotService] {
        services.filter { $0.shortName == name }
    }
}

// MARK: - Spec Source & Disk-Cached Store

public protocol MiotSpecSource: Sendable {
    /// `specType` is the URN the cloud device list sometimes includes; when absent the model is looked up.
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec?
}

public actor MiotSpecStore: MiotSpecSource {
    private let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "MiotSpec")
    private let transport: any MiHTTPTransport
    private let cacheDirectory: URL
    private let indexMaxAge: TimeInterval
    private var typeByModel: [String: String]?
    private var indexTask: Task<[String: String], any Error>?
    private var specByType: [String: MiotDeviceSpec] = [:]

    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarMijia", isDirectory: true)
    }

    public init(
        transport: any MiHTTPTransport = URLSessionMiTransport(timeout: 60),
        cacheDirectory: URL = MiotSpecStore.defaultCacheDirectory,
        indexMaxAge: TimeInterval = 7 * 24 * 3600
    ) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.indexMaxAge = indexMaxAge
    }

    public func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        let type: String
        if let specType, !specType.isEmpty {
            type = specType
        } else if let found = try await typeIndex()[model] {
            type = found
        } else {
            return nil
        }
        return try await instance(type: type)
    }

    private func typeIndex() async throws -> [String: String] {
        if let typeByModel { return typeByModel }
        // Actor reentrancy: concurrent spec lookups would otherwise each download the 2 MB index.
        if let indexTask { return try await indexTask.value }
        let task = Task { try await self.loadTypeIndex() }
        indexTask = task
        do {
            let index = try await task.value
            typeByModel = index
            return index
        } catch {
            indexTask = nil
            throw error
        }
    }

    private func loadTypeIndex() async throws -> [String: String] {
        let file = cacheDirectory.appendingPathComponent("miot-instances.json")
        var data: Data?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < indexMaxAge {
            data = try? Data(contentsOf: file)
        }
        if data == nil {
            let url = URL(string: "https://miot-spec.org/miot-spec-v2/instances?status=released")!
            let (fetched, http) = try await transport.send(URLRequest(url: url))
            guard http.statusCode == 200 else { throw MiCloudError.http(http.statusCode) }
            data = fetched
            writeCache(fetched, to: file)
        }
        let index = Self.parseInstanceIndex(data ?? Data())
        logger.info("MIoT instance index loaded: \(index.count, privacy: .public) models")
        return index
    }

    /// Highest released version per model.
    public static func parseInstanceIndex(_ data: Data) -> [String: String] {
        struct Entry: Decodable { let model: String; let version: Int; let type: String }
        struct Root: Decodable { let instances: [Entry] }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [:] }
        var best: [String: Entry] = [:]
        for e in root.instances where (best[e.model]?.version ?? Int.min) < e.version {
            best[e.model] = e
        }
        return best.mapValues(\.type)
    }

    private func instance(type: String) async throws -> MiotDeviceSpec? {
        if let cached = specByType[type] { return cached }
        let safeName = type.replacingOccurrences(of: ":", with: "_") + ".json"
        let file = cacheDirectory.appendingPathComponent("instances", isDirectory: true).appendingPathComponent(safeName)
        if let data = try? Data(contentsOf: file), let spec = try? JSONDecoder().decode(MiotDeviceSpec.self, from: data) {
            specByType[type] = spec
            return spec
        }
        var comps = URLComponents(string: "https://miot-spec.org/miot-spec-v2/instance")!
        comps.queryItems = [URLQueryItem(name: "type", value: type)]
        let (data, http) = try await transport.send(URLRequest(url: comps.url!))
        guard http.statusCode == 200 else { throw MiCloudError.http(http.statusCode) }
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: data)
        writeCache(data, to: file)
        specByType[type] = spec
        return spec
    }

    private func writeCache(_ data: Data, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            logger.error("Spec cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
