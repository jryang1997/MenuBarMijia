import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  type AppLanguage,
  catalogEntry,
  catalogKeys,
  isTranslated,
  languageFromTag,
  resolveLanguage,
  setLanguage,
  speechLocale,
  speechLocaleFor,
  t,
} from "../src/core/i18n.js";
import {
  applyTemperatureUnit,
  displayStep,
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  resolveTemperatureUnit,
  stepCelsius,
  temperatureSymbol,
  toCelsius,
  toDisplayTemperature,
} from "../src/core/temperature.js";

function withLanguage<T>(language: AppLanguage, body: () => T): T {
  const previous = speechLocaleFor(language);
  void previous;
  setLanguage(language);
  try {
    return body();
  } finally {
    setLanguage("zh-Hans");
  }
}

describe("text catalog (#52)", () => {
  it("every t() key used by the UI exists in the catalog", () => {
    const sources = [
      "src/ui/app.ts",
      "src/ui/panelPrefs.ts",
      "src/core/models.ts",
    ].map((path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8"));
    const used = new Set<string>();
    for (const source of sources) {
      for (const match of source.matchAll(/\bt\(\s*"((?:[^"\\]|\\.)*)"/g)) {
        used.add(JSON.parse(`"${match[1]}"`) as string);
      }
    }
    assert.ok(used.size > 100, `expected many call sites, saw ${used.size}`);
    const missing = [...used].filter((key) => catalogEntry(key) === undefined);
    assert.deepEqual(missing, [], `catalog is missing: ${missing.join(" | ")}`);
  });

  it("every catalog entry carries a non-empty English translation", () => {
    for (const key of catalogKeys()) {
      const entry = catalogEntry(key);
      assert.ok(entry, `missing entry ${key}`);
      assert.equal(entry[0], key, `Simplified column must echo the key: ${key}`);
      assert.ok(entry[1].trim().length > 0, `empty English text for ${key}`);
    }
  });

  it("translates Chinese text to English and back", () => {
    withLanguage("zh-Hans", () => {
      assert.equal(t("已关闭"), "已关闭");
      assert.equal(t("打开设置"), "打开设置");
    });
    withLanguage("en", () => {
      assert.equal(t("已关闭"), "Off");
      assert.equal(t("打开设置"), "Open settings");
      assert.equal(t("更多设备"), "More devices");
      assert.ok(isTranslated("制冷"));
    });
  });

  it("fills named placeholders and keeps unknown ones visible", () => {
    withLanguage("en", () => {
      assert.equal(t("已同步 {count} 台真实米家设备", { count: 3 }), "Synced 3 devices");
      assert.equal(
        t("米家账号 {user} · {count} 台设备", { user: "10****00", count: 5 }),
        "Mi account 10****00 · 5 devices",
      );
      // A placeholder the caller forgot stays visible instead of printing "undefined".
      assert.equal(t("全关·{room}"), "All off · {room}");
    });
    withLanguage("zh-Hans", () => {
      assert.equal(t("全关·{room}", { room: "客厅" }), "全关·客厅");
    });
  });

  it("returns the Chinese text for an unknown key instead of an empty label", () => {
    withLanguage("en", () => {
      assert.equal(t("这条文案不在表里"), "这条文案不在表里");
    });
  });

  it("falls back to Chinese for Chinese regions and to English for everything else", () => {
    assert.equal(languageFromTag("zh-CN"), "zh-Hans");
    assert.equal(languageFromTag("zh-Hant-HK"), "zh-Hans");
    assert.equal(languageFromTag("zh"), "zh-Hans");
    assert.equal(languageFromTag("en-GB"), "en");
    assert.equal(languageFromTag("fr-FR"), "en");
    assert.equal(resolveLanguage("en", ["zh-CN"]), "en");
    assert.equal(resolveLanguage("zh-Hans", ["en-US"]), "zh-Hans");
    assert.equal(resolveLanguage("system", ["en-US", "zh-Hans"]), "en");
    assert.equal(resolveLanguage("system", ["zh-Hans-CN"]), "zh-Hans");
    // No OS languages at all: the app's own default, not an empty string.
    assert.equal(resolveLanguage("system", []), "zh-Hans");
  });

  it("speech recognition follows the UI language", () => {
    withLanguage("en", () => {
      assert.equal(speechLocale(), "en-US");
    });
    withLanguage("zh-Hans", () => {
      assert.equal(speechLocale(), "zh-CN");
    });
  });
});

describe("temperature units (#52)", () => {
  it("resolves Fahrenheit from the region subtag only", () => {
    assert.equal(resolveTemperatureUnit("en-US"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("en_US"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("zh-Hans-CN"), "celsius");
    assert.equal(resolveTemperatureUnit("zh-Hant-TW"), "celsius");
    assert.equal(resolveTemperatureUnit("de-DE"), "celsius");
    assert.equal(resolveTemperatureUnit("en"), "celsius");
    assert.equal(resolveTemperatureUnit("en-US@calendar=gregorian"), "fahrenheit");
    assert.equal(resolveTemperatureUnit("en-US", "celsius"), "celsius");
    assert.equal(resolveTemperatureUnit("de-DE", "fahrenheit"), "fahrenheit");
  });

  it("formats display units while the stored value stays Celsius", () => {
    applyTemperatureUnit("en-US", "celsius");
    assert.equal(getTemperatureUnit(), "celsius");
    assert.equal(formatTemperature(24), "24°C");
    assert.equal(formatTemperature(25.5), "25.5°C");
    assert.equal(formatTemperatureValue(24.5), "24.5");
    assert.equal(formatTemperatureValue(26.5, undefined, 1), "26.5");
    assert.equal(temperatureSymbol(), "°C");

    applyTemperatureUnit("en-US", "system");
    assert.equal(getTemperatureUnit(), "fahrenheit");
    assert.equal(formatTemperature(0), "32°F");
    assert.equal(formatTemperature(24), "75°F");
    assert.equal(formatTemperature(22, undefined, 1), "71.6°F");
    assert.equal(temperatureSymbol(), "°F");
    assert.ok(Math.abs(toCelsius(toDisplayTemperature(21.5)) - 21.5) < 1e-9);
    applyTemperatureUnit("en-US", "celsius");
  });

  it("uses one whole °F per thermostat tap but keeps Celsius in the command", () => {
    applyTemperatureUnit("en-US", "celsius");
    assert.equal(stepCelsius(0.5), 0.5);
    assert.equal(displayStep(0.5), 0.5);

    applyTemperatureUnit("en-US", "fahrenheit");
    assert.ok(Math.abs(stepCelsius(0.5) - 5 / 9) < 1e-9);
    assert.equal(displayStep(0.5), 1);
    const next = 24 + stepCelsius(0.5);
    assert.ok(Math.abs(toDisplayTemperature(next) - toDisplayTemperature(24) - 1) < 1e-9);
    applyTemperatureUnit("zh-Hans-CN", "celsius");
  });
});
