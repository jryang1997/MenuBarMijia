import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { SmartDevice } from "../src/core/models.js";
import {
  DEFAULT_GLOBAL_SHORTCUT,
  SKINS,
  applyOrder,
  chosenSize,
  comfort,
  emptyLayoutPrefs,
  homeOptions,
  isValidGlobalShortcut,
  localizeFanMode,
  moveInOrder,
  normalizeGlobalShortcut,
  pageSections,
  parseGlobalShortcut,
  recordShortcutFromKeyEvent,
  resolvedSize,
  spans,
} from "../src/ui/panelPrefs.js";

const plug = (id: string): SmartDevice => ({
  id, name: id, roomId: "r", roomName: "客厅", model: "m", isOnline: true,
  kind: { kind: "plug", switchEntityId: `miot:${id}:2`, isOn: false, powerWatts: null, childLockEntityId: null, isChildLocked: false },
});
const climate = (id: string): SmartDevice => ({
  id, name: id, roomId: "r", roomName: "客厅", model: "m", isOnline: true,
  kind: { kind: "climate", entityId: `miot:${id}:2`, isOn: false, hvacMode: "off", availableModes: ["cool"], targetTemperature: 26, currentTemperature: null, minTemp: 16, maxTemp: 30, step: 1, fanMode: null, availableFanModes: [] },
});

describe("panel layout prefs", () => {
  it("exposes only the default classic skin", () => {
    assert.deepEqual(SKINS.map((s) => s.id), ["classic"]);
  });

  it("page-scoped size overrides the all-pages default", () => {
    const prefs = emptyLayoutPrefs();
    prefs.tileSizes = { a: "full", "客厅|a": "panel" };
    assert.equal(chosenSize(prefs, "客厅", "a"), "panel");
    assert.equal(chosenSize(prefs, "all", "a"), "full");
    assert.equal(chosenSize(prefs, "all", "b"), "auto");
  });

  it("auto resolves climate to a full row and others by grid mode", () => {
    assert.equal(resolvedSize("auto", climate("c"), true, true), "full");
    assert.equal(resolvedSize("auto", climate("c"), true, false), "half");
    assert.equal(resolvedSize("auto", plug("p"), false, true), "full");
  });

  it("moves before/after a target and keeps unknown devices in place", () => {
    const order = moveInOrder([], ["a", "b", "c", "d"], "d", "a", false);
    assert.deepEqual(order, ["d", "a", "b", "c"]);
    assert.deepEqual(moveInOrder(order, ["a", "b", "c", "d"], "d", "b", true), ["a", "b", "d", "c"]);
    assert.deepEqual(applyOrder(["c", "a"], [plug("a"), plug("b"), plug("c")]).map((d) => d.id), ["c", "a", "b"]);
  });

  it("bento alternates 4+2 and 2+2+2; full cards take the row", () => {
    const devs = ["a", "b", "c", "d", "e", "f"].map(plug);
    const map = spans(devs, (d) => (d.id === "c" ? "full" : "half"), true);
    assert.deepEqual(devs.map((d) => map.get(d.id)), [4, 2, 6, 2, 2, 2]);
  });

  it("groups come first, the rest is titled only when groups exist", () => {
    const prefs = emptyLayoutPrefs();
    const devs = [plug("a"), plug("b")];
    assert.deepEqual(pageSections(prefs, devs, true).map((s) => s.title), [null]);
    prefs.groups = [{ id: "g", name: "灯光" }];
    prefs.groupMap = { b: "g" };
    assert.deepEqual(pageSections(prefs, devs, true).map((s) => s.title), ["灯光", "更多设备"]);
    assert.deepEqual(pageSections(prefs, devs, false).map((s) => s.title), ["灯光", "其他"]);
  });

  it("home options count unique devices per home", () => {
    const homes = homeOptions([
      { id: "r1", name: "客厅", dids: ["1", "2"], homeId: "h1", homeName: "东澜府" },
      { id: "home_h1", name: "", dids: ["2", "9"], homeId: "h1", homeName: "东澜府" },
      { id: "r2", name: "卧室", dids: ["3"], homeId: "h2", homeName: "果果家" },
    ]);
    assert.deepEqual(homes, [
      { id: "h1", name: "东澜府", deviceCount: 3 },
      { id: "h2", name: "果果家", deviceCount: 1 },
    ]);
  });

  it("comfort and fan labels", () => {
    assert.equal(comfort(26.4, 55).label, "舒适");
    assert.equal(comfort(29, 50).label, "偏热");
    assert.equal(comfort(22, 30).label, "偏干");
    assert.equal(localizeFanMode("Level3"), "3 档");
    assert.equal(localizeFanMode("auto"), "自动");
  });

  it("global shortcut parser normalizes modifier order and rejects plain keys (#43)", () => {
    assert.equal(DEFAULT_GLOBAL_SHORTCUT, "Alt+M");
    assert.equal(parseGlobalShortcut("shift+ctrl+alt+keyk"), "Ctrl+Alt+Shift+K");
    assert.equal(parseGlobalShortcut("win+space"), "Super+Space");
    assert.equal(parseGlobalShortcut("f8"), "F8");
    assert.equal(isValidGlobalShortcut("Alt+M"), true);
    assert.equal(isValidGlobalShortcut("M"), false);
    assert.equal(isValidGlobalShortcut("Space"), false);
    assert.equal(isValidGlobalShortcut("Ctrl+"), false);
    assert.equal(normalizeGlobalShortcut("junk"), "Alt+M");
    assert.equal(normalizeGlobalShortcut("ctrl+alt+m"), "Ctrl+Alt+M");

    assert.deepEqual(recordShortcutFromKeyEvent({ key: "Escape" }), { kind: "cancel" });
    assert.deepEqual(recordShortcutFromKeyEvent({ key: "Control", ctrlKey: true }), { kind: "modifier-only" });
    assert.deepEqual(recordShortcutFromKeyEvent({ key: "m", code: "KeyM" }), { kind: "invalid" });
    assert.deepEqual(
      recordShortcutFromKeyEvent({ key: "k", code: "KeyK", ctrlKey: true, shiftKey: true }),
      { kind: "recorded", shortcut: "Ctrl+Shift+K" },
    );
    assert.deepEqual(recordShortcutFromKeyEvent({ key: "F9", code: "F9" }), {
      kind: "recorded",
      shortcut: "F9",
    });
    assert.deepEqual(
      recordShortcutFromKeyEvent({ key: "1", code: "Numpad1", ctrlKey: true }),
      { kind: "recorded", shortcut: "Ctrl+Numpad1" },
    );
    assert.deepEqual(
      recordShortcutFromKeyEvent({ key: "1", code: "NumpadEnd", ctrlKey: true }),
      { kind: "invalid" },
    );
    assert.deepEqual(
      recordShortcutFromKeyEvent({ key: "-", code: "NumpadSubtract", ctrlKey: true }),
      { kind: "invalid" },
    );
  });
});
