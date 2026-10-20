import Foundation
import Testing
@testable import MijiaCore

struct HAHomeSnapshotTests {
    private static let states: JSONValue = .array([
        .object(["entity_id": .string("light.visible"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Desk light")])]),
        .object(["entity_id": .string("light.hidden"), "state": .string("on"), "attributes": .object([:])])
    ])
    private static let entities: JSONValue = .array([
        .object(["entity_id": .string("light.visible"), "area_id": .string("office")]),
        .object(["entity_id": .string("light.hidden"), "hidden_by": .string("user")])
    ])

    private static func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    @Test("Initial states never publish hidden devices before their registry arrives")
    func waitsForInitialRegistries() throws {
        var projection = HAHomeSnapshot()
        let statesOnly = try projection.receive(Self.reply(4, Self.states))
        #expect(statesOnly?.devices == nil)
        let withAreas = try projection.receive(Self.reply(1, .array([.object(["area_id": .string("office"), "name": .string("Office")])])))
        #expect(withAreas?.devices == nil)
        let withoutEntities = try projection.receive(Self.reply(2, .array([])))
        #expect(withoutEntities?.devices == nil)
        let completed = try projection.receive(Self.reply(3, Self.entities))
        let home = try #require(completed)
        #expect(home.devices.map(\.id) == ["light.visible"])
        #expect(home.devices.first?.roomName == "Office")
    }

    static var responseOrders: [[Int]] {
        var result: [[Int]] = []
        for a in 1...4 {
            for b in 1...4 where b != a {
                for c in 1...4 where c != a && c != b {
                    for d in 1...4 where d != a && d != b && d != c {
                        result.append([a, b, c, d])
                    }
                }
            }
        }
        return result
    }

    private static func initialReply(_ id: Int) -> [String: JSONValue] {
        switch id {
        case 1: reply(id, .array([.object(["area_id": .string("office"), "name": .string("Office")])]))
        case 2: reply(id, .array([]))
        case 3: reply(id, entities)
        default: reply(id, states)
        }
    }

    @Test("Every initial reply order waits for authoritative metadata", arguments: responseOrders)
    func initialReplyOrder(_ order: [Int]) throws {
        var projection = HAHomeSnapshot()
        for (offset, id) in order.enumerated() {
            let result = try projection.receive(Self.initialReply(id))
            if offset < 3 {
                #expect(result?.devices == nil)
            } else {
                let home = try #require(result)
                #expect(home.devices.map(\.id) == ["light.visible"])
                #expect(home.devices.first?.roomName == "Office")
            }
        }
        let refreshed = try projection.receive(Self.reply(1001, .array([
            .object(["entity_id": .string("light.visible"), "state": .string("off"), "attributes": .object([:])])
        ])))
        let home = try #require(refreshed)
        if case .light(let light) = home.devices.first?.kind {
            #expect(!light.isOn)
        } else {
            Issue.record("Refresh lost the visible light")
        }
    }

    @Test("A rejected registry is an error rather than a successful empty registry")
    func rejectedRegistry() throws {
        var projection = HAHomeSnapshot()
        _ = try projection.receive(Self.initialReply(1))
        _ = try projection.receive(Self.initialReply(2))
        _ = try projection.receive(Self.initialReply(4))
        do {
            _ = try projection.receive(["type": .string("result"), "id": .number(3), "success": .bool(false), "error": .object(["code": .string("unauthorized")])])
            Issue.record("Rejected entity registry was accepted")
        } catch HAHomeSnapshot.ReadError.rejected {
        }
        let recovered = try projection.receive(Self.initialReply(3))
        #expect(recovered?.devices.map(\.id) == ["light.visible"])
    }

    @Test("Malformed registries cannot complete initialization", arguments: [JSONValue.null, .object([:]), .array([.object([:])])])
    func malformedRegistry(_ payload: JSONValue) throws {
        var projection = HAHomeSnapshot()
        _ = try projection.receive(Self.initialReply(1))
        _ = try projection.receive(Self.initialReply(2))
        _ = try projection.receive(Self.initialReply(4))
        do {
            _ = try projection.receive(Self.reply(3, payload))
            Issue.record("Malformed registry completed initialization")
        } catch HAHomeSnapshot.ReadError.invalidResponse {
        }
        let recovered = try projection.receive(Self.initialReply(3))
        #expect(recovered?.devices.map(\.id) == ["light.visible"])
    }
}
