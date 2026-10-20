import assert from "node:assert/strict";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import type { HttpResponse, MiotDeviceSpec } from "../src/core/miCloudClient.js";
import type { DeviceIntent } from "../src/core/models.js";

const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
const model = "yeelink.light.ceiling22";
const spec: MiotDeviceSpec = {
  type: "urn:miot-spec-v2:device:light:0000A001:review-test:1",
  services: [{
    iid: 2,
    type: "urn:miot-spec-v2:service:light:00007802:review-test:1",
    properties: [
      { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:review-test:1", format: "bool", access: ["read", "write"] },
      { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:review-test:1", format: "uint8", access: ["read", "write"], valueRange: [1, 100, 1] },
      { iid: 3, type: "urn:miot-spec-v2:property:color-temperature:0000000F:review-test:1", format: "uint32", access: ["read", "write"], valueRange: [2700, 6500, 100] },
    ],
    actions: [],
  }],
};

export function cloudFixture(intents: readonly DeviceIntent[]) {
  const values = new Map<number, unknown>([[1, true], [2, 50], [3, 4100]]);
  const writes: Array<{ piid: number; value: unknown; accepted: boolean }> = [];
  const rejectedValues = new Map<number, unknown>([[2, 80]]);
  const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<HttpResponse | undefined> => {
    if (name !== "native_http") return;
    assert.equal(typeof args.url, "string");
    const url = String(args.url);
    if (url.includes("/instance?")) return { status: 200, headers: {}, body: JSON.stringify(spec) };
    if (url.includes("/instances?")) return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model, type: spec.type }] }) };
    let result: unknown = {};
    if (url.includes("device_list")) {
      result = { list: [{ did: "fixture-light", name: "测试灯", model, isOnline: true, spec_type: spec.type }] };
    } else if (url.includes("miotspec/prop/")) {
      assert.equal(typeof args.body, "string");
      const fields = new URLSearchParams(String(args.body));
      const nonce = fields.get("_nonce");
      const encrypted = fields.get("data");
      assert.ok(nonce && encrypted);
      const payload: unknown = JSON.parse(MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce)));
      assert.ok(payload !== null && typeof payload === "object" && "params" in payload && Array.isArray(payload.params));
      result = payload.params.map((entry: unknown) => {
        assert.ok(entry !== null && typeof entry === "object" && "piid" in entry && typeof entry.piid === "number");
        const piid = entry.piid;
        if (url.includes("/set")) {
          assert.ok("value" in entry);
          const accepted = !rejectedValues.has(piid) || rejectedValues.get(piid) !== entry.value;
          writes.push({ piid, value: entry.value, accepted });
          if (accepted) values.set(piid, entry.value);
          return { did: "fixture-light", siid: 2, piid, code: accepted ? 0 : -704042011 };
        }
        return { did: "fixture-light", siid: 2, piid, code: 0, value: values.get(piid) };
      });
    }
    return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
  };
  Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
  localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
    connectionMode: "xiaomiCloud",
    hasCompletedOnboarding: true,
    habitLearningEnabled: false,
    miSession: { userId: "fixture-user", cUserId: "", ssecurity: security, serviceToken: "fixture-token", passToken: "", region: "cn" },
    cachedModelTypes: { [model]: spec.type },
    learnedShortcuts: [{ phrase: "部分失败", reply: "执行测试操作", intents, learnedAt: "2026-01-01T00:00:00Z" }],
  }));
  return {
    values,
    writes,
    allowBrightness: () => { rejectedValues.delete(2); },
    reject: (piid: number, value: unknown) => { rejectedValues.set(piid, value); },
    allow: (piid: number) => { rejectedValues.delete(piid); },
  };
}
