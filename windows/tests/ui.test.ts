import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import { Window } from "happy-dom";

import { installWindow } from "./dom.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import { cloudFixture } from "./cloudFixture.js";

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

beforeEach(() => {
  dom = new Window({ url: "http://localhost/" });
  installWindow(dom);
  document.body.innerHTML = '<div id="app"></div>';
});

afterEach(async () => {
  await dom.happyDOM.abort();
  dom.close();
});

describe("Windows device control and undo", () => {
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
