/**
 * Display units for temperatures (#52). Values stored, sent and stepped in the core stay Celsius;
 * conversion happens only where a number is rendered or parsed back from the user.
 */

export type TemperatureUnit = "celsius" | "fahrenheit";

export type TemperatureUnitPreference = "system" | TemperatureUnit;

/** Regions whose everyday temperatures are Fahrenheit; everything else is Celsius. */
const FAHRENHEIT_REGIONS: Readonly<Record<string, true>> = {
  US: true, PR: true, GU: true, VI: true, AS: true, MP: true, LR: true,
  MM: true, BS: true, BZ: true, KY: true, PW: true, FM: true, MH: true,
};

const CELSIUS_SYMBOL = "°C";
const FAHRENHEIT_SYMBOL = "°F";

/** Resolves the display unit from a BCP-47 tag such as `en-US`, `zh-Hant-TW` or `my_MM`. */
export function resolveTemperatureUnit(localeIdentifier: string, preference: TemperatureUnitPreference = "system"): TemperatureUnit {
  if (preference !== "system") return preference;
  const withoutKeywords = localeIdentifier.split("@")[0] ?? localeIdentifier;
  const subtags = withoutKeywords.split(/[-_]/).slice(1);
  for (const subtag of subtags) {
    const code = subtag.toUpperCase();
    // Skip script (4 letters) and variant subtags; the first 2-letter subtag is the region.
    if (code.length !== 2 || !/^[A-Z]{2}$/.test(code)) continue;
    return FAHRENHEIT_REGIONS[code] ? "fahrenheit" : "celsius";
  }
  return "celsius";
}

let currentUnit: TemperatureUnit = "celsius";

export function getTemperatureUnit(): TemperatureUnit {
  return currentUnit;
}

export function setTemperatureUnit(unit: TemperatureUnit): void {
  currentUnit = unit;
}

/** Resolves and applies the unit from the saved preference plus the OS locale. */
export function applyTemperatureUnit(localeIdentifier: string, preference: TemperatureUnitPreference): TemperatureUnit {
  const unit = resolveTemperatureUnit(localeIdentifier, preference);
  currentUnit = unit;
  return unit;
}

export function temperatureSymbol(unit: TemperatureUnit = currentUnit): string {
  return unit === "fahrenheit" ? FAHRENHEIT_SYMBOL : CELSIUS_SYMBOL;
}

/** Celsius (the stored unit) to the number the user should see. */
export function toDisplayTemperature(celsius: number, unit: TemperatureUnit = currentUnit): number {
  return unit === "fahrenheit" ? (celsius * 9) / 5 + 32 : celsius;
}

/** A number typed or spoken in display units back to the Celsius core. */
export function toCelsius(displayValue: number, unit: TemperatureUnit = currentUnit): number {
  return unit === "fahrenheit" ? ((displayValue - 32) * 5) / 9 : displayValue;
}

function resolveFractionDigits(celsius: number, unit: TemperatureUnit, fractionDigits?: number): number {
  if (fractionDigits !== undefined) {
    return Math.max(0, Math.trunc(fractionDigits));
  }
  if (unit === "celsius" && Math.abs(celsius - Math.round(celsius)) >= 0.05) {
    return 1;
  }
  return 0;
}

/** Digits only, for places that draw the degree mark separately. */
export function formatTemperatureValue(celsius: number, unit: TemperatureUnit = currentUnit, fractionDigits?: number): string {
  const digits = resolveFractionDigits(celsius, unit, fractionDigits);
  return toDisplayTemperature(celsius, unit).toFixed(digits);
}

/** Digits plus unit symbol, e.g. `24°C`, `25.5°C`, or `75°F`. */
export function formatTemperature(celsius: number, unit: TemperatureUnit = currentUnit, fractionDigits?: number): string {
  return `${formatTemperatureValue(celsius, unit, fractionDigits)}${temperatureSymbol(unit)}`;
}

/** One ± tap on a thermostat: the provider step in Celsius, or exactly one whole °F. */
export function stepCelsius(providerStep: number, unit: TemperatureUnit = currentUnit): number {
  return unit === "fahrenheit" ? 5 / 9 : providerStep;
}

/** How far one tap moves the visible number: 1 in Fahrenheit, the provider step in Celsius. */
export function displayStep(providerStep: number, unit: TemperatureUnit = currentUnit): number {
  return unit === "fahrenheit" ? 1 : providerStep;
}

/** A user-entered value in display units, converted for rounding to the thermostat's own step. */
export function celsiusFromDisplay(value: number, unit: TemperatureUnit = currentUnit): number {
  return toCelsius(value, unit);
}
