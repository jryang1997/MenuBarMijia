import Foundation
import Testing
@testable import MijiaCore

struct HADeviceDiscoveryTests {
    @Test("A thermometer's auxiliary switch does not replace its environment readings")
    func thermometerWithAuxiliarySwitch() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "thermometer", name: "Room thermometer", model: "generic.sensor")],
            entities: [
                HAEntityEntry(entity_id: "sensor.room_temperature", device_id: "thermometer"),
                HAEntityEntry(entity_id: "sensor.room_humidity", device_id: "thermometer"),
                HAEntityEntry(entity_id: "switch.status_led", device_id: "thermometer")
            ],
            states: [
                "sensor.room_temperature": HAEntityState(entityId: "sensor.room_temperature", state: "24", attributes: ["device_class": .string("temperature")]),
                "sensor.room_humidity": HAEntityState(entityId: "sensor.room_humidity", state: "55", attributes: ["device_class": .string("humidity")]),
                "switch.status_led": HAEntityState(entityId: "switch.status_led", state: "on")
            ]
        )
        let device = try #require(home.devices.first)
        #expect(device.id == "thermometer")
        if case .sensor(let sensor) = device.kind {
            #expect(sensor.temperature == 24)
            #expect(sensor.humidity == 55)
        } else {
            Issue.record("Thermometer was classified as a controllable outlet")
        }
        #expect(home.environmentReadings.first?.temperature == 24)
        #expect(home.environmentReadings.first?.humidity == 55)
    }

    @Test("User-renamed outlets are not excluded by auxiliary name substrings", arguments: ["switch.commuter_charger", "switch.indicator_lamp", "switch.child_locksmith"])
    func renamedOutlet(entityId: String) throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "outlet", name: "Outlet", model: "cuco.plug.v3")],
            entities: [HAEntityEntry(entity_id: entityId, device_id: "outlet")],
            states: [entityId: HAEntityState(entityId: entityId, state: "on", attributes: ["device_class": .string("outlet")])]
        )
        let device = try #require(home.devices.first)
        if case .plug(let plug) = device.kind {
            #expect(plug.switchEntityId == entityId)
            #expect(plug.isOn)
        } else {
            Issue.record("User-renamed outlet was not synthesized as an outlet")
        }
    }

    @Test("Explicit outlet metadata selects the load switch over status lights and board temperature")
    func outletWithAuxiliaryTelemetry() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "outlet", name: "Outlet", model: "TS011F")],
            entities: [
                HAEntityEntry(entity_id: "switch.status_led", device_id: "outlet"),
                HAEntityEntry(entity_id: "switch.load", device_id: "outlet"),
                HAEntityEntry(entity_id: "sensor.board_temperature", device_id: "outlet")
            ],
            states: [
                "switch.status_led": HAEntityState(entityId: "switch.status_led", state: "on"),
                "switch.load": HAEntityState(entityId: "switch.load", state: "off", attributes: ["device_class": .string("outlet")]),
                "sensor.board_temperature": HAEntityState(entityId: "sensor.board_temperature", state: "35", attributes: ["device_class": .string("temperature")])
            ]
        )
        let device = try #require(home.devices.first)
        if case .plug(let plug) = device.kind {
            #expect(plug.switchEntityId == "switch.load")
            #expect(!plug.isOn)
        } else {
            Issue.record("Explicit outlet metadata was ignored")
        }
    }

    @Test("Home Assistant Wake on LAN button entities synthesize as standalone momentary action devices (#100)")
    func wakeOnLanButtonSynthesizedAsMomentaryDevice() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "study", name: "书房")],
            devices: [
                HADeviceEntry(id: "wol_pc", area_id: "study", name: "书房台式机", model: "Wake on LAN"),
                HADeviceEntry(id: "router", area_id: "study", name: "路由器", model: "OpenWrt")
            ],
            entities: [
                HAEntityEntry(entity_id: "button.wake_on_lan_aa_bb_cc_dd_ee_ff", device_id: "wol_pc"),
                HAEntityEntry(entity_id: "button.router_reboot", device_id: "router", entity_category: "config"),
                HAEntityEntry(entity_id: "button.router_restart", device_id: "router")
            ],
            states: [
                // HA stateless button entities report "unknown" before their first press since startup
                "button.wake_on_lan_aa_bb_cc_dd_ee_ff": HAEntityState(
                    entityId: "button.wake_on_lan_aa_bb_cc_dd_ee_ff",
                    state: "unknown",
                    attributes: ["friendly_name": .string("书房台式机")]
                ),
                "button.router_reboot": HAEntityState(
                    entityId: "button.router_reboot",
                    state: "unknown",
                    attributes: ["device_class": .string("restart")]
                ),
                "button.router_restart": HAEntityState(
                    entityId: "button.router_restart",
                    state: "unknown"
                ),
                // Orphan YAML-configured Wake on LAN button without a device registry entry
                "button.wake_on_lan_nas": HAEntityState(
                    entityId: "button.wake_on_lan_nas",
                    state: "2026-10-31T10:00:00+00:00",
                    attributes: ["friendly_name": .string("唤醒 NAS")]
                )
            ]
        )

        #expect(home.devices.count == 2)
        let firstMatch = home.devices.first(where: { $0.id == "wol_pc" })
        let pc = try #require(firstMatch)
        #expect(pc.name == "书房台式机")
        #expect(pc.roomName == "书房")
        #expect(pc.isOnline)
        #expect(pc.sfSymbolName == "desktopcomputer")
        #expect(pc.statusSubtitle == "点击触发" || pc.statusSubtitle == "Tap to trigger")
        if case .plug(let spec) = pc.kind {
            #expect(spec.switchEntityId == "button.wake_on_lan_aa_bb_cc_dd_ee_ff")
            #expect(!spec.isOn)
        } else {
            Issue.record("Expected Wake on LAN button device to synthesize as .plug")
        }

        let secondMatch = home.devices.first(where: { $0.id == "button.wake_on_lan_nas" })
        let nas = try #require(secondMatch)
        #expect(nas.name == "唤醒 NAS")
        #expect(nas.isOnline)

        let mappedPress = HAWebSocketProvider.mapCommandToService(.pressButton(entityId: "button.wake_on_lan_aa_bb_cc_dd_ee_ff"))
        #expect(mappedPress.domain == "button")
        #expect(mappedPress.service == "press")
    }
}
