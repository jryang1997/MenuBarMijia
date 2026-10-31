import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import { Window } from "happy-dom";

import { installWindow } from "./dom.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { cloudFixture } from "./cloudFixture.js";
import { MiCloudClient, MiotSynthesizer } from "../src/core/miCloudClient.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing control ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function tile(id: string): string {
  return element(`[data-body-device="${id}"]`).textContent ?? "";
}

function textOf(selector: string): string {
  return element(selector).textContent ?? "";
}

function startDemo(): void {
  localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
    connectionMode: "demo",
    hasCompletedOnboarding: true,
  }));
  new MenuMijiaWindowsApp(element("#app"));
}

async function setRange(selector: string, value: string): Promise<void> {
  const slider = document.querySelector<HTMLInputElement>(selector);
  assert.ok(slider);
  slider.value = value;
  slider.dispatchEvent(new Event("change", { bubbles: true }));
  await setImmediate();
}

async function command(text: string): Promise<void> {
  const input = document.querySelector<HTMLInputElement>("#command-input");
  assert.ok(input);
  input.value = text;
  await click("#btn-send");
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) assert.fail("Timed out waiting for UI state");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function withTimeout<T>(
  promise: Promise<T>,
  message: string,
  timeoutMs = 2_000,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

beforeEach(() => {
  dom = new Window({ url: "http://localhost/" });
  installWindow(dom);
  // The suite asserts Simplified Chinese chrome; pin the OS language so `system` resolves to it.
  Object.defineProperty(dom.navigator, "languages", { value: ["zh-CN", "zh"], configurable: true });
  Object.defineProperty(dom.navigator, "language", { value: "zh-CN", configurable: true });
  document.body.innerHTML = '<div id="app"></div>';
  // Most UI tests do not exercise the daily GitHub check; mark it done today so the
  // startup request cannot change their request lists (#39). Update tests clear this.
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});

afterEach(async () => {
  await dom.happyDOM.abort();
  dom.close();
});

describe("Service endpoint submission", () => {
  it("sends the saved assistant and Home Assistant URLs and not a free origin list", async () => {
    const calls: Array<{ command: string; args: Record<string, unknown> }> = [];
    const invoke = async (command: string, args: Record<string, unknown> = {}) => {
      calls.push({ command, args });
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "HTTPS://API.DeepSeek.com:8443/v1",
      haBaseURL: "http://[::1]:8123/api",
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    assert.deepEqual(calls.filter((call) => call.command === "set_service_endpoints").map((call) => call.args), [
      { assistantUrl: "HTTPS://API.DeepSeek.com:8443/v1", haUrl: "http://[::1]:8123/api" },
    ]);
    assert.equal(calls.some((call) => call.command === "set_allowed_origins"), false);
  });

  it("does not re-prompt a declined endpoint on unrelated background saves, but retries when settings are explicitly saved", async () => {
    let endpointAttempts = 0;
    const invoke = async (command: string) => {
      if (command === "set_service_endpoints") {
        endpointAttempts += 1;
        throw new Error("未授权访问来源：https://api.deepseek.com:8443");
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://api.deepseek.com:8443/v1",
      haBaseURL: "",
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.equal(endpointAttempts, 1);

    // Unrelated settings saves (e.g. toggling interface language or background cloud refresh) must not re-prompt.
    await click("#btn-settings");
    await click('[data-interface-language="zh-Hans"]');
    await setImmediate();
    assert.equal(endpointAttempts, 1);

    // Clicking "保存设置" explicitly retries endpoint authorization.
    await click("#btn-save-settings");
    await setImmediate();
    assert.equal(endpointAttempts, 2);
  });
});

describe("Windows device control and undo", () => {
  it("keeps focus in the command input after a local command completes", async () => {
    startDemo();
    const input = element("#command-input") as HTMLInputElement;
    input.value = "客厅吸顶灯月光模式";
    input.focus();

    await click("#btn-send");
    await waitFor(() => tile("light.living_ceiling").includes("月光"));

    assert.ok(
      document.activeElement === element("#command-input"),
      "command input lost keyboard focus after a local command",
    );
  });

  it("clears a submitted command after undo instead of restoring it into the input", async () => {
    startDemo();
    await click('[data-toggle-device="light.living_ceiling"]');
    const input = element("#command-input") as HTMLInputElement;
    input.value = "撤销";
    input.focus();

    await click("#btn-send");

    assert.match(tile("light.living_ceiling"), /已开启/);
    assert.equal(input.value, "");
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
    assert.ok(
      document.activeElement === document.querySelector("#command-input"),
      "command input lost keyboard focus after submission",
    );
  });

  it("restores an originally off light without turning it on through brightness", async () => {
    startDemo();
    await click('[data-toggle-device="light.living_ceiling"]');
    assert.match(tile("light.living_ceiling"), /已关闭/);
    await click('[data-toggle-device="light.living_ceiling"]');
    assert.match(tile("light.living_ceiling"), /已开启/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /已关闭/);
    assert.match(document.body.textContent ?? "", /已撤销/);
  });

  it("restores the changed light color temperature without changing brightness", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    await setRange('[data-colortemp="light.living_ceiling"]', "5500");
    assert.match(tile("light.living_ceiling"), /5500K/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /78% · 4100K/);
  });

  it("restores a light effect through the natural command flow", async () => {
    startDemo();
    await command("客厅吸顶灯月光模式");
    assert.match(tile("light.living_ceiling"), /月光/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /日光/);
  });

  it("switches moonlight from the light drawer and restores its original mode on undo", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    const daylight = '[data-lighteffect="light.living_ceiling"][data-effect="Day"]';
    const moonlight = '[data-lighteffect="light.living_ceiling"][data-effect="Night"]';
    assert.equal(element(daylight).getAttribute("aria-pressed"), "true");
    await click(moonlight);
    assert.match(tile("light.living_ceiling"), /月光/);
    assert.match(tile("light.living_ceiling"), /78%/);
    assert.match(tile("light.living_ceiling"), /4100K/);
    assert.equal(element(moonlight).getAttribute("aria-pressed"), "true");
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /日光/);
    assert.equal(element(daylight).getAttribute("aria-pressed"), "true");
  });

  it("restores a fan preset and its initially off power state", async () => {
    startDemo();
    await click('[data-expand-device="fan.bedroom_standing"]');
    await click('[data-fanpreset="fan.bedroom_standing:Level 4"]');
    assert.match(tile("fan.bedroom_standing"), /Level 4/);
    await click("#btn-undo");
    assert.match(tile("fan.bedroom_standing"), /已关闭/);
    assert.equal(element('[data-fanpreset="fan.bedroom_standing:Level 2"]').classList.contains("is-active"), true);
  });

  it("restores fan oscillation and its initially off power state", async () => {
    startDemo();
    await click('[data-expand-device="fan.bedroom_standing"]');
    await click('[data-fanosc="fan.bedroom_standing"]');
    assert.match(tile("fan.bedroom_standing"), /摇头/);
    await click("#btn-undo");
    assert.match(tile("fan.bedroom_standing"), /已关闭/);
    assert.match(element('[data-fanosc="fan.bedroom_standing"]').textContent ?? "", /摇头 关/);
  });

  it("undoes only acknowledged attributes when another command on the same device fails", async () => {
    const cloud = cloudFixture([
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 80 } },
      { targetId: "fixture-light", operation: { kind: "colorTemperature", kelvin: 5500 } },
    ]);
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(tile("fixture-light"), /50% · 4100K/);
    await command("部分失败");
    assert.match(document.body.textContent ?? "", /1 项失败/);
    assert.match(tile("fixture-light"), /50% · 5500K/);
    cloud.values.set(2, 90);
    await click("#btn-refresh");
    assert.match(tile("fixture-light"), /90% · 5500K/);
    cloud.allowBrightness();
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /90% · 4100K/);
    assert.equal(cloud.values.get(2), 90);
    assert.equal(cloud.values.get(3), 4100);
  });

  it("reverses multiple acknowledged changes to the same attribute in execution order", async () => {
    const cloud = cloudFixture([
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 80 } },
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 60 } },
    ]);
    cloud.allowBrightness();
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await command("部分失败");
    assert.match(tile("fixture-light"), /60%/);
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /50%/);
    assert.equal(cloud.values.get(2), 50);
  });

  it("preserves final power correction when a failed undo is retried", async () => {
    const cloud = cloudFixture([]);
    cloud.values.set(1, false);
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(tile("fixture-light"), /已关闭/);
    await click('[data-expand-device="fixture-light"]');
    await setRange('[data-colortemp="fixture-light"]', "5500");
    cloud.reject(3, 4100);
    await click("#btn-undo");
    assert.match(document.body.textContent ?? "", /撤销未完成/);
    assert.match(tile("fixture-light"), /已关闭/);
    cloud.allow(3);
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /已关闭/);
    assert.equal(cloud.values.get(1), false);
    assert.equal(cloud.values.get(3), 4100);
    assert.match(document.body.textContent ?? "", /已撤销/);
  });
});

describe("Silent Xiaomi cloud refresh (#81)", { concurrency: false }, () => {
  async function readyCloudApp(configure?: (cloud: ReturnType<typeof cloudFixture>) => void): Promise<{
    cloud: ReturnType<typeof cloudFixture>;
    triggerRefresh(): void;
    runTimerTick(): void;
  }> {
    const cloud = cloudFixture([]);
    configure?.(cloud);
    let timerTick: (() => void) | null = null;
    const timerWindow = window as unknown as {
      setInterval: (handler: () => void, timeout?: number) => number;
    };
    const originalSetInterval = timerWindow.setInterval;
    timerWindow.setInterval = (handler) => {
      timerTick = handler;
      return 1;
    };
    new MenuMijiaWindowsApp(element("#app"));
    timerWindow.setInterval = originalSetInterval;
    assert.ok(timerTick, "app did not install its timer loop");
    for (let i = 0; i < 3; i++) await setImmediate();
    await waitFor(
      () => !document.querySelector("#btn-refresh")?.classList.contains("is-spinning"),
    );
    assert.match(tile("fixture-light"), /50%/);
    const runTimerTick = () => (timerTick as () => void)();
    let refreshOffset = 0;
    return {
      cloud,
      runTimerTick,
      triggerRefresh: () => {
        refreshOffset += 7_000;
        const realNow = Date.now;
        Date.now = () => realNow() + refreshOffset;
        try {
          runTimerTick();
        } finally {
          Date.now = realNow;
        }
      },
    };
  }

  it("keeps device and room positions when cloud polling permutes the same records", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push({ ...light, did: "second-light", name: "第二盏灯" });
      fixture.deviceRecords.push(
        fixture.sensorRecord("sensor-bedroom", "主卧温湿度计"),
        fixture.sensorRecord("sensor-balcony", "阳台温湿度计"),
      );
      fixture.roomRecords.push(
        { id: "living", name: "客厅", dids: ["fixture-light"] },
        { id: "study", name: "书房", dids: ["second-light"] },
      );
    });
    const ids = () => Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId);
    const rooms = () => Array.from(document.querySelectorAll<HTMLElement>("[data-room]"), (node) => node.dataset.room);
    const initialIds = ids();
    const initialRooms = rooms();
    const envLabels = () => Array.from(document.querySelectorAll(".cc-env-label"), (node) => node.textContent);
    const initialEnvLabels = envLabels();
    assert.deepEqual(initialEnvLabels, ["主卧", "阳台"]);
    const popover = element(".cc-popover");
    for (let i = 0; i < 4; i++) {
      cloud.deviceRecords.reverse();
      cloud.roomRecords.reverse();
      cloud.values.set(2, 51 + i);
      cloud.sensorValues.set(1, 24 + i);
      const held = cloud.holdNextRead();
      triggerRefresh();
      await withTimeout(held.started, "Polling did not request properties");
      held.release();
      await withTimeout(held.finished, "Polling did not finish");
      await setImmediate();
      assert.deepEqual(ids(), initialIds, "cloud response order moved device tiles");
      assert.deepEqual(rooms(), initialRooms, "cloud response order moved room tabs");
      assert.deepEqual(envLabels(), initialEnvLabels, "cloud response order moved environment chips");
      assert.match(tile("fixture-light"), new RegExp(`${51 + i}%`));
      assert.match(textOf(".cc-env-strip"), new RegExp(`${24 + i}\\.0`));
      assert.ok(element(".cc-popover") === popover, "order-only refresh rebuilt the panel");
    }
  });

  it("appends new devices, removes missing devices and retains a partial custom order", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push(
        { ...light, did: "second-light" }, { ...light, did: "third-light" },
      );
      const stored = localStorage.getItem("menumijia.windows.settings.v2");
      assert.ok(stored);
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        ...JSON.parse(stored), layout: { order: ["third-light"] },
      }));
    });
    const light = cloud.deviceRecords[0];
    assert.ok(light);
    cloud.deviceRecords.splice(0, cloud.deviceRecords.length,
      { ...light, did: "new-light" }, { ...light, did: "third-light" }, light,
    );
    const held = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(held.started, "Polling did not request properties");
    held.release();
    await withTimeout(held.finished, "Polling did not finish");
    await setImmediate();
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId),
      ["third-light", "fixture-light", "new-light"],
    );
    const stored = localStorage.getItem("menumijia.windows.settings.v2");
    assert.ok(stored);
    const cached: unknown = JSON.parse(stored);
    assert.ok(cached && typeof cached === "object" && "cachedXiaomiDevices" in cached && Array.isArray(cached.cachedXiaomiDevices));
    assert.deepEqual(cached.cachedXiaomiDevices.map((device) => device.id), ["fixture-light", "third-light", "new-light"]);
  });

  it("retains the cached device positions on the first refresh after restart", async () => {
    await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push({ ...light, did: "second-light" });
      const records = MiCloudClient.parseDeviceList({ list: [...fixture.deviceRecords].reverse() });
      const cached = MiotSynthesizer.synthesize(records, [], {}, new Map());
      const stored = localStorage.getItem("menumijia.windows.settings.v2");
      assert.ok(stored);
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        ...JSON.parse(stored), cachedXiaomiDevices: cached.devices,
      }));
    });
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId),
      ["second-light", "fixture-light"],
    );
  });

  it("keeps the current DOM when polling returns the same snapshot", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const input = element("#command-input") as HTMLInputElement;
    const popover = element(".cc-popover");
    input.value = "未发送的草稿";
    input.focus();
    const heldRead = cloud.holdNextRead();

    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the no-op gate");
    heldRead.release();
    await withTimeout(heldRead.finished, "Cloud response did not finish");
    await setImmediate();

    assert.equal(element(".cc-popover"), popover);
    assert.equal(element("#command-input"), input);
    assert.equal(document.activeElement, input);
    assert.equal(input.value, "未发送的草稿");
  });

  it("patches a real state change without disturbing the command draft", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const input = element("#command-input") as HTMLInputElement;
    const inputNode = input;
    input.value = "未发送的草稿";
    input.focus();
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("90%"));
    assert.match(tile("fixture-light"), /90%/);
    assert.ok(element("#command-input") === inputNode, "command input was replaced");
    assert.ok(document.activeElement === inputNode, "command focus moved");
    assert.equal(input.value, "未发送的草稿");
  });

  it("discards a stale cloud snapshot after a newer command has completed", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const heldRead = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the stale response gate");
    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => cloud.writes.filter((write) => write.piid === 1).length === 1);
    assert.match(tile("fixture-light"), /已关闭/);

    heldRead.release();
    await withTimeout(heldRead.finished, "Stale cloud response did not finish");
    await setImmediate();
    assert.match(tile("fixture-light"), /已关闭/);

    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => cloud.writes.filter((write) => write.piid === 1).length === 2);
    assert.match(tile("fixture-light"), /已开启/);
    assert.deepEqual(
      cloud.writes.filter((write) => write.piid === 1).map((write) => write.value),
      [false, true],
    );
  });

  it("patches dynamic values without replacing the focused device control", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const toggle = element('[data-toggle-device="fixture-light"]');
    const tileNode = element('[data-tile-id="fixture-light"]');
    toggle.focus();
    const heldRead = cloud.holdNextRead();
    cloud.values.set(2, 90);
    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the focused-control gate");
    heldRead.release();
    await withTimeout(heldRead.finished, "Cloud response did not finish");
    await waitFor(() => tile("fixture-light").includes("90%"));

    assert.match(tile("fixture-light"), /90%/);
    assert.ok(element('[data-toggle-device="fixture-light"]') === toggle, "device control was replaced");
    assert.ok(element('[data-tile-id="fixture-light"]') === tileNode, "device tile was replaced");
    assert.ok(document.activeElement === toggle, "keyboard focus moved");
  });

  it("keeps keyboard focus on an id-less device control across a structural refresh", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    element('[data-toggle-device="fixture-light"]').focus();
    cloud.values.set(1, false);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(
      document.activeElement === element('[data-toggle-device="fixture-light"]'),
      "device control lost keyboard focus",
    );
  });

  it("does not let an open detail drawer block structural updates forever", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer did not open");
    cloud.values.set(1, false);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer closed after refresh");
  });

  it("updates and restores focus when a detail slider is focused", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    const slider = element('[data-brightness="fixture-light"]');
    slider.focus();
    cloud.values.set(1, false);
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer closed after refresh");
    const restored = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    assert.ok(document.activeElement === restored, "focused detail slider was not restored");
    assert.equal(restored.value, "90");
  });

  it("updates a focused range value when polling patches in place", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    const slider = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    slider.focus();
    slider.value = "60";
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("90%"));

    const patched = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    assert.ok(patched === slider, "focused slider was replaced by the value-only patch");
    assert.equal(patched.value, "90");
    assert.ok(document.activeElement === patched, "focused slider lost focus");
  });

  it("waits to patch the panel while a pointer interaction is in progress", async () => {
    const { cloud, triggerRefresh, runTimerTick } = await readyCloudApp();
    const toggle = element('[data-toggle-device="fixture-light"]');
    toggle.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    cloud.values.set(2, 90);
    const reads = cloud.completedReads();

    triggerRefresh();
    await waitFor(() => cloud.completedReads() > reads);
    assert.match(tile("fixture-light"), /50%/);

    window.dispatchEvent(new Event("pointerup", { bubbles: true }));
    runTimerTick();
    await waitFor(() => tile("fixture-light").includes("90%"));
  });
});

describe("Credentials move out of localStorage (#28)", () => {
  it("migrates old plaintext credentials into the credential manager and strips the copy", async () => {
    const store = new Map<string, string>();
    const invoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T | null> => {
      const name = String(args["name"] ?? "");
      if (cmd === "secure_store_set") {
        store.set(name, String(args["value"] ?? ""));
        return null;
      }
      if (cmd === "secure_store_get") return (store.get(name) ?? null) as T | null;
      if (cmd === "secure_store_delete") {
        store.delete(name);
        return null;
      }
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      openRouterApiKey: "sk-live",
      haToken: "ha-token",
      miSession: {
        userId: "1000000000",
        cUserId: "abc",
        ssecurity: "ssecurity-value",
        serviceToken: "service-token-value",
        passToken: "account-level-pass-token",
        region: "cn",
      },
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal("miSession" in saved, false);
    assert.equal("haToken" in saved, false);
    assert.equal("openRouterApiKey" in saved, false);
    assert.deepEqual([...store.keys()].sort(), ["assistant_api_key", "ha_token", "mi_session"]);
    assert.equal(store.get("mi_session")?.includes("passToken"), false);
    assert.equal(store.get("mi_session")?.includes("account-level-pass-token"), false);

    // A later launch reads only the credential manager, so the upgrade needs no new QR login.
    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    await click("#btn-settings");
    assert.match(document.body.textContent ?? "", /已登录 10\*\*\*\*00/);
  });
});

describe("AI key stays with the server it was saved for (#19)", () => {
  function keyField(): HTMLInputElement {
    return element("#settings-api-key") as HTMLInputElement;
  }

  it("does not carry the saved key to another provider, and restores it when switching back", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      openRouterApiKey: "sk-or-saved",
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-settings");
    assert.equal(keyField().value, "sk-or-saved");

    await click('[data-ai-preset="deepseek"]');
    assert.equal(keyField().value, "");

    await click('[data-ai-preset="openrouter_jev"]');
    assert.equal(keyField().value, "sk-or-saved");

    const base = element("#settings-base-url") as HTMLInputElement;
    base.value = "https://openrouter.ai.evil.com/api/v1";
    base.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(keyField().value, "");
  });

  it("never sends a key that was saved for a different server", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://my-proxy.example.com/v1",
      openRouterApiKey: "sk-saved-for-openrouter",
      assistantKeyEndpoint: "openrouter.ai",
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    assert.match(document.body.textContent ?? "", /未命中本地规则。请在设置中填写 AI 服务的 API Key/);
  });
});

describe("First cloud AI request asks once (#20)", () => {
  function fakeModel(): string[] {
    const urls: string[] = [];
    const content = JSON.stringify({ actions: [], reply: "已经很合适了" });
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name !== "native_http") return undefined;
      urls.push(String(args.url));
      return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content } }] }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://api.deepseek.com/v1",
      assistantModel: "deepseek-chat",
      openRouterApiKey: "sk-deepseek",
      assistantKeyEndpoint: "api.deepseek.com",
    }));
    return urls;
  }

  it("sends nothing until allowed, then remembers the service", async () => {
    const urls = fakeModel();
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    assert.match(document.body.textContent ?? "", /要交给云端 AI（api\.deepseek\.com）处理吗/);
    assert.equal(urls.length, 0);

    await click("#btn-cloud-allow");
    await setImmediate();
    assert.deepEqual(urls, ["https://api.deepseek.com/v1/chat/completions"]);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { cloudConsentEndpoints?: string[] };
    assert.deepEqual(saved.cloudConsentEndpoints, ["api.deepseek.com"]);

    await command("帮我想想今晚怎么安排灯光氛围");
    assert.equal(urls.length, 2);
    assert.equal(document.querySelector("#btn-cloud-allow"), null);
  });

  it("declining sends nothing", async () => {
    const urls = fakeModel();
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    await click("#btn-cloud-decline");
    assert.match(document.body.textContent ?? "", /没有发送/);
    assert.equal(urls.length, 0);
  });
});

describe("AI suggestions wait for a tap (#21)", () => {
  it("shows a chip for an unsure guess and runs it only when tapped", async () => {
    const answers = {
      target: { choice: "d3", confidence: 0.9 },
      op: { choice: "power_off", confidence: 0.55 },
      temp: { choice: "none", confidence: 0.99 },
    };
    const invoke = async (name: string) => {
      if (name !== "native_http") return undefined;
      return { status: 200, headers: {}, body: JSON.stringify({ answers }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      assistantModel: "~typesafe/jev-latest",
      openRouterApiKey: "sk-or-test",
      assistantKeyEndpoint: "openrouter.ai",
      cloudConsentEndpoints: ["openrouter.ai"],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    const before = tile("light.study_desk");
    await command("帮我想想今晚怎么安排灯光氛围");
    await setImmediate();
    assert.match(document.body.textContent ?? "", /没把握直接执行，点下面的建议再执行/);
    assert.equal(tile("light.study_desk"), before);

    const chip = element("[data-suggestion-id]");
    assert.match(chip.textContent ?? "", /关闭书房台灯 · 55%/);
    chip.click();
    await setImmediate();
    await setImmediate();
    assert.equal(document.querySelector("[data-suggestion-id]"), null);
    assert.match(tile("light.study_desk"), /已关闭/);
  });
});

describe("Timers the PC slept through (#22)", () => {
  it("holds an overdue timer until 立即执行 is tapped", async () => {
    startDemo();
    const before = tile("light.study_desk");
    await command("10分钟后关闭书房台灯");
    assert.match(document.body.textContent ?? "", /已设定 10 分钟后执行「关闭书房台灯」/);
    const realNow = Date.now;
    Date.now = () => realNow() + 3 * 3600 * 1000;
    try {
      await new Promise((resolve) => setTimeout(resolve, 1_200));
      assert.match(document.body.textContent ?? "", /已错过定时：关闭书房台灯/);
      assert.equal(tile("light.study_desk"), before);
      await click("[data-run-missed]");
      await setImmediate();
      assert.match(tile("light.study_desk"), /已关闭/);
      assert.equal(document.querySelector("[data-run-missed]"), null);
    } finally {
      Date.now = realNow;
    }
  });
});

describe("全关 (#23)", () => {
  it("needs a hold in the classic skin and leaves the plug on", async () => {
    startDemo();
    const button = element("#btn-all-off");
    assert.match(button.textContent ?? "", /全关 \(3\)/);
    button.click();
    await setImmediate();
    assert.match(tile("light.living_ceiling"), /已开启/);

    button.dispatchEvent(new Event("pointerdown"));
    await new Promise((resolve) => setTimeout(resolve, 700));
    await setImmediate();
    assert.doesNotMatch(tile("light.living_ceiling"), /已开启/);
    assert.match(tile("plug.entry_socket"), /供电中/);
  });
});

describe("Xiaomi cloud region switch (#37)", () => {
  it("names the current region in the empty state and saves a newly selected region", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miCloudRegion: "de",
      cachedXiaomiDevices: [],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    assert.match(document.body.textContent ?? "", /当前地区（de）没有设备，可尝试切换地区/);

    await click("#btn-empty-settings");
    const select = document.querySelector<HTMLSelectElement>("select[data-mi-region]");
    assert.ok(select, "settings must offer the region dropdown");
    assert.deepEqual(
      Array.from(select!.options).map((option) => option.value),
      ["cn", "de", "i2", "ru", "sg", "us"],
    );
    assert.equal(select!.value, "de");

    select!.value = "us";
    select!.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { miCloudRegion?: string };
    assert.equal(saved.miCloudRegion, "us");
  });
});

describe("Update notice (#39)", () => {
  it("shows a newer release in settings and hands it to the tray", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const releaseBody = JSON.stringify({
      tag_name: "v9.9.9",
      html_url: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v9.9.9",
    });
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      calls.push({ name, args });
      if (name === "native_http" && String(args["url"]).startsWith("https://api.github.com/")) {
        return { status: 200, headers: {}, body: releaseBody };
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    const trayCall = calls.find((call) => call.name === "set_update_available");
    assert.deepEqual(trayCall?.args, { version: "9.9.9" });
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.update.v1") ?? "{}") as {
      release?: { version?: string };
    };
    assert.equal(saved.release?.version, "9.9.9");

    await click("#btn-settings");
    assert.match(document.body.textContent ?? "", /有新版本 v9\.9\.9，点击查看/);
    await click("#btn-open-update");
    const openCall = calls.find((call) => call.name === "open_release_page");
    assert.deepEqual(openCall?.args, {
      url: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v9.9.9",
    });
  });

  it("makes no request when automatic checks are switched off", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    const urls: string[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "native_http") urls.push(String(args["url"]));
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    assert.deepEqual(urls, []);
  });
});

describe("Interface language and temperature units (#52)", () => {
  function seed(extra: Record<string, unknown>): void {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...extra,
    }));
  }

  it("renders the English catalog when English is selected, and remembers it", async () => {
    seed({ interfaceLanguage: "en" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    const text = document.body.textContent ?? "";
    assert.match(text, /All off/, "the hold-to-confirm control is translated");
    assert.match(text, /Switch home|My Mi Home|Living room/, "home and room labels are translated");
    assert.doesNotMatch(text, /全关/, "no Simplified Chinese chrome leaks into English mode");
    assert.match(element('[data-body-device="light.living_ceiling"]').textContent ?? "", /Living room ceiling light/i);

    // Selecting Chinese switches back without a reload and persists the choice.
    await click("#btn-settings");
    const chinese = document.querySelector<HTMLElement>('[data-interface-language="zh-Hans"]');
    assert.ok(chinese, "language picker is present in settings");
    await click('[data-interface-language="zh-Hans"]');
    assert.match(document.body.textContent ?? "", /全关/);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal(saved["interfaceLanguage"], "zh-Hans");
  });

  it("follows the OS language when the preference is system", async () => {
    Object.defineProperty(window.navigator, "languages", { value: ["en-US", "en"], configurable: true });
    Object.defineProperty(window.navigator, "language", { value: "en-US", configurable: true });
    seed({ interfaceLanguage: "system" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(document.body.textContent ?? "", /All off/);
  });

  it("shows °F when the unit is Fahrenheit, and one tap moves exactly one °F", async () => {
    seed({ interfaceLanguage: "zh-Hans", temperatureUnit: "fahrenheit" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    // Demo AC runs at 25 °C = 77 °F; the sensor reads 25.5 °C = 77.9 °F.
    assert.match(textOf(".cc-climate"), /77°F/);
    assert.match(textOf(".cc-sensor"), /77\.9°F/);

    await click('[data-acstep="climate.living_ac:1"]');
    assert.match(textOf(".cc-climate"), /78°F/);
  });

  it("keeps Celsius when the unit is Celsius", async () => {
    seed({ interfaceLanguage: "zh-Hans", temperatureUnit: "celsius" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(textOf(".cc-climate"), /25°C/);
    assert.match(textOf(".cc-sensor"), /25\.5°C/);
  });
});

describe("Customizable global shortcut (#43)", () => {
  it("registers Alt+M by default, records a custom shortcut, persists it, and unregisters when disabled", async () => {
    const hotkeyCalls: Array<{ enabled: boolean; shortcut: string }> = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "set_global_shortcut") {
        hotkeyCalls.push({ enabled: Boolean(args["enabled"]), shortcut: String(args["shortcut"]) });
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Alt+M" });

    await click("#btn-settings");
    assert.equal(textOf("#btn-record-hotkey"), "Alt+M");

    // Arm the recorder; a plain letter without modifiers shows the hint and keeps listening.
    await click("#btn-record-hotkey");
    assert.equal(textOf("#btn-record-hotkey"), "按下组合…");
    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "m", code: "KeyM", bubbles: true }));
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "按下组合…");
    assert.ok(document.querySelector("#hotkey-record-hint"));

    // Press Ctrl+Alt+K -> records, persists, and calls set_global_shortcut.
    window.dispatchEvent(
      new window.KeyboardEvent("keydown", {
        key: "k",
        code: "KeyK",
        ctrlKey: true,
        altKey: true,
        bubbles: true,
      }),
    );
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "Ctrl+Alt+K");
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Ctrl+Alt+K" });
    const savedAfterRecord = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal(savedAfterRecord["globalHotkey"], "Ctrl+Alt+K");

    // Reset button restores Alt+M.
    await click("#btn-reset-hotkey");
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "Alt+M");
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Alt+M" });

    // Unchecking the toggle immediately unregisters the global shortcut (Coding Standard #3).
    const enableBox = element("#settings-enable-hotkey") as HTMLInputElement;
    enableBox.checked = false;
    enableBox.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: false, shortcut: "Alt+M" });
    assert.equal(document.querySelector("#btn-record-hotkey"), null);
  });

  it("surfaces a conflict notice when registration fails and clears it on retry", async () => {
    let shouldFail = true;
    const invoke = async (name: string): Promise<unknown> => {
      if (name === "set_global_shortcut" && shouldFail) {
        throw new Error("HotKey already registered");
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await click("#btn-settings");

    const conflictRow = document.querySelector("#hotkey-conflict-row");
    assert.ok(conflictRow, "conflict warning is shown in Settings");
    assert.match(conflictRow.textContent ?? "", /已被其他应用占用/);

    shouldFail = false;
    await click("#btn-retry-hotkey");
    await setImmediate();
    assert.equal(document.querySelector("#hotkey-conflict-row"), null);
  });
});

describe("Smart camera support and live view (#97)", () => {
  it("clicking a camera card opens the live stream window and supports night-shot, hot-hide reopen, timed teardown, motion detection, and undo", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    assert.match(tile("camera.living_cam"), /监控中 · 自动夜视 · 侦测开 · 点击看画面/);

    // Clicking the camera card body opens the enlarged live camera view modal.
    await click('[data-body-device="camera.living_cam"]');
    assert.ok(document.querySelector(".cc-camera-live-sheet"), "live camera modal should open on click");
    assert.match(document.body.textContent ?? "", /实时看护小窗预览/);

    // Switch night vision mode inside the live modal and verify undo restores Auto.
    await click('[data-cameranight="camera.living_cam:On"]');
    assert.match(tile("camera.living_cam"), /夜视开/);

    // 「关闭画面」only hides the modal and keeps the session hot; reopening the card
    // brings it straight back (the camera needs a long cooldown before a used P2P
    // session can be re-negotiated, so full teardown waits for the keep-alive window).
    await click("#btn-close-camera-live");
    const backdropAfterClose = element(".cc-camera-live-sheet").closest(".cc-sheet-backdrop") as HTMLElement;
    assert.equal(backdropAfterClose.style.display, "none");
    await click('[data-body-device="camera.living_cam"]');
    const backdropAfterReopen = element(".cc-camera-live-sheet").closest(".cc-sheet-backdrop") as HTMLElement;
    assert.equal(backdropAfterReopen.style.display, "");
    assert.match(document.body.textContent ?? "", /实时看护小窗预览/);

    // When the keep-alive window expires with nobody watching, the modal is removed
    // entirely (on the real backend that teardown also stops the bridge and asks the
    // camera to release its P2P session; here we pin the window short and watch the DOM).
    app.cameraKeepAliveMs = 30;
    await click("#btn-close-camera-live");
    await waitFor(() => document.querySelector(".cc-camera-live-sheet") === null);

    await click("#btn-undo");
    assert.match(tile("camera.living_cam"), /自动夜视/);

    // Expand the camera drawer and toggle motion detection, then undo.
    await click('[data-expand-device="camera.living_cam"]');
    await click('[data-cameramotion="camera.living_cam"]');
    assert.doesNotMatch(tile("camera.living_cam"), /侦测开/);
    await click("#btn-undo");
    assert.match(tile("camera.living_cam"), /侦测开/);
  });

  it("persists custom camera stream URLs across restarts and wakes sleeping cameras straight into the stream", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    await click("#btn-toggle-camera-url");
    const input = element("#camera-stream-url-input") as HTMLInputElement;
    input.value = "http://127.0.0.1:1984/api/stream.mjpeg?src=living_custom";
    await click("#btn-save-camera-url");
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "http://127.0.0.1:1984/api/stream.mjpeg?src=living_custom",
    );

    // Re-instantiate the app to verify the saved stream URL survived in localStorage.
    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "http://127.0.0.1:1984/api/stream.mjpeg?src=living_custom",
    );

    // Put the camera to sleep, then wake it from inside the modal and verify the stream resumes immediately.
    await click('.cc-camera-live-sheet .cc-segmented-pills [data-toggle-device="camera.living_cam"]');
    assert.match(document.body.textContent ?? "", /摄像机处于物理休眠状态/);
    await click('.cc-camera-stage.is-sleeping [data-toggle-device="camera.living_cam"]');
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "http://127.0.0.1:1984/api/stream.mjpeg?src=living_custom",
    );
  });
});

describe("Air purifier support (#98)", () => {
  it("displays PM2.5, air quality, temperature/humidity, filter life, and supports mode & fan speed slider with undo", async () => {
    const rma3Spec = {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-rma3:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:zhimi-rma3:1", format: "bool", access: ["read", "write"] },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:mode:00000008:zhimi-rma3:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Auto" },
                { value: 1, description: "Sleep" },
                { value: 2, description: "Favorite" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:zhimi-rma3:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
            { iid: 4, type: "urn:miot-spec-v2:property:pm2.5-density:00000034:zhimi-rma3:1", format: "uint16", access: ["read"], valueRange: [0, 1000, 1] },
            { iid: 7, type: "urn:miot-spec-v2:property:temperature:00000020:zhimi-rma3:1", format: "float", access: ["read"], valueRange: [-30, 100, 1] },
            {
              iid: 8,
              type: "urn:miot-spec-v2:property:air-quality:0000001C:zhimi-rma3:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 0, description: "Excellent" },
                { value: 1, description: "Good" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:filter:0000780B:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:filter-life-level:0000001E:zhimi-rma3:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
          ],
          actions: [],
        },
        {
          iid: 11,
          type: "urn:miot-spec-v2:service:air-purifier-favorite:000078B2:zhimi-rma3:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:fan-level:00000016:zhimi-rma3:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: Array.from({ length: 15 }, (_, i) => ({ value: i, description: `Level${i}` })),
            },
          ],
          actions: [],
        },
      ],
    };

    const state = new Map<string, unknown>([
      ["2.1", true],
      ["2.4", 0],
      ["11.1", 7],
      ["3.4", 18],
      ["3.8", 0],
      ["3.7", 24.5],
      ["3.1", 52],
      ["4.1", 86],
    ]);

    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) {
        return { status: 200, headers: {}, body: JSON.stringify(rma3Spec) };
      }
      if (url.includes("/instances?")) {
        return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model: "zhimi.airp.rma3", type: rma3Spec.type }] }) };
      }
      let result: unknown = {};
      if (url.includes("device_list")) {
        result = {
          list: [{ did: "airp-rma3", name: "书房空气净化器", model: "zhimi.airp.rma3", isOnline: true, spec_type: rma3Spec.type }],
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "书房", dids: ["airp-rma3"] }] }] };
      } else if (url.includes("miotspec/prop/")) {
        const fields = new URLSearchParams(String(args["body"] ?? ""));
        const nonce = fields.get("_nonce") ?? "";
        const encrypted = fields.get("data") ?? "";
        const payload = JSON.parse(
          MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce))
        ) as { params?: Array<{ did: string; siid: number; piid: number; value?: unknown }> };
        result = (payload.params ?? []).map((p) => {
          if (url.includes("/set")) {
            state.set(`${p.siid}.${p.piid}`, p.value);
            return { did: p.did, siid: p.siid, piid: p.piid, code: 0 };
          }
          return { did: p.did, siid: p.siid, piid: p.piid, code: 0, value: state.get(`${p.siid}.${p.piid}`) };
        });
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: { userId: "10001", cUserId: "", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
        cachedModelTypes: { "zhimi.airp.rma3": rma3Spec.type },
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => Boolean(document.querySelector('[data-body-device="airp-rma3"]')));
    assert.match(tile("airp-rma3"), /运行中 · 自动 · 50% · PM2\.5 18 优 · 25°C 52%/);

    await click('[data-expand-device="airp-rma3"]');
    const drawerText = document.body.textContent ?? "";
    assert.match(drawerText, /空气质量 PM2\.5 18 \(优\)/);
    assert.match(drawerText, /温湿度 24\.5°C · 52%/);
    assert.match(drawerText, /滤芯余量 86%/);

    await setRange('[data-fanpercent="airp-rma3"]', "100");
    await waitFor(() => state.get("11.1") === 14);
    assert.equal(state.get("2.4"), 2);
    assert.match(tile("airp-rma3"), /最爱 · 100%/);

    await click("#btn-undo");
    await waitFor(() => state.get("11.1") === 7);
    assert.equal(state.get("2.4"), 0);
    assert.match(tile("airp-rma3"), /自动 · 50%/);
  });
});
