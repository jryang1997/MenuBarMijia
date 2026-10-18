import Foundation
import Testing
@testable import MijiaCore

struct LGWebOSTests {
    @Test("LGWebOSProtocol builds valid SSAP registration and Wake-on-LAN packets")
    func protocolPacketsAndParsing() throws {
        let regJSON = LGWebOSProtocol.registrationPacket(id: "register_0", clientKey: "test-client-key-123")
        let regObj = try #require(JSONSerialization.jsonObject(with: Data(regJSON.utf8)) as? [String: Any])
        #expect(regObj["type"] as? String == "register")
        #expect(regObj["id"] as? String == "register_0")
        let payload = try #require(regObj["payload"] as? [String: Any])
        #expect(payload["client-key"] as? String == "test-client-key-123")
        #expect(payload["pairingType"] as? String == "PROMPT")

        let promptOutcome = LGWebOSProtocol.parseRegistrationOutcome(
            #"{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}"#
        )
        #expect(promptOutcome == .promptPending)

        let registeredOutcome = LGWebOSProtocol.parseRegistrationOutcome(
            #"{"type":"registered","id":"register_0","payload":{"client-key":"lg-c2-secret-key"}}"#
        )
        #expect(registeredOutcome == .registered(clientKey: "lg-c2-secret-key"))

        let wol = try #require(LGWebOSProtocol.wakeOnLanMagicPacket(macAddress: "4c:ba:d7:c3:e9:9a"))
        #expect(wol.count == 102)
        #expect(Array(wol.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(Array(wol[6..<12]) == [0x4C, 0xBA, 0xD7, 0xC3, 0xE9, 0x9A])
        #expect(LGWebOSProtocol.wakeOnLanMagicPacket(macAddress: "invalid") == nil)

        let upnpXML = """
        <root><device>
        <friendlyName>[LG] webOS TV OLED42C2PCA</friendlyName>
        <modelName>OLED42C2PCA</modelName>
        <UDN>uuid:fe42fad6-8f3a-0211-c3b5-363fad426a96</UDN>
        </device></root>
        """
        let discovered = LGWebOSProtocol.parseUPnPDescription(xml: upnpXML, host: "10.10.1.171")
        #expect(discovered.friendlyName == "LG C2 电视")
        #expect(discovered.modelName == "OLED42C2PCA")
        #expect(discovered.uuid == "fe42fad6-8f3a-0211-c3b5-363fad426a96")
    }

    @Test("HomeStore TV controls and voice assistant commands work with LG C2 TV")
    @MainActor
    func storeTVControlsAndAssistant() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "standby",
                volumePercent: 18,
                isMuted: false,
                isScreenOff: false,
                currentSource: "HDMI 1",
                availableSources: ["HDMI 1", "HDMI 2", "YouTube", "Netflix"]
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.lg.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        // 1. Voice command "打开电视"
        let onPlan = try #require(await store.runAssistantCommand("打开电视"))
        #expect(onPlan.source == .local)
        #expect(onPlan.reply == "已打开LG C2 电视")
        #expect(store.devices.first?.isActiveOn == true)

        // 2. Mute, OLED Screen Off, and HDMI Source Switch
        store.toggleTVMute(LGWebOSProtocol.deviceId)
        store.toggleTVScreenOff(LGWebOSProtocol.deviceId)
        store.selectTVSource(LGWebOSProtocol.deviceId, source: "HDMI 2")
        try await Task.sleep(for: .milliseconds(40))

        let executed = await mock.executedCommands
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true)))
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.muteEntityId, isOn: true)))
        #expect(executed.contains(.setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: true)))
        #expect(executed.contains(.mediaSelectSource(entityId: LGWebOSProtocol.mediaEntityId, source: "HDMI 2")))
    }
}
