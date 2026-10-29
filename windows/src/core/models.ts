import { t } from "./i18n.js";
import { formatTemperature } from "./temperature.js";

export type HomeBackend = "xiaomiCloud" | "homeAssistant";

export type ConnectionStatus =
  | { readonly kind: "connected" }
  | { readonly kind: "connecting" }
  | { readonly kind: "disconnected"; readonly reason: string };

export interface LightSpec {
  readonly kind: "light";
  readonly entityId: string;
  isOn: boolean;
  brightnessPercent: number | null;
  colorTempKelvin: number | null;
  readonly minKelvin: number;
  readonly maxKelvin: number;
  currentEffect: string | null;
  readonly availableEffects: readonly string[];
}

export interface ClimateSpec {
  readonly kind: "climate";
  readonly entityId: string;
  isOn: boolean;
  hvacMode: string;
  readonly availableModes: readonly string[];
  targetTemperature: number;
  readonly currentTemperature: number | null;
  readonly minTemp: number;
  readonly maxTemp: number;
  readonly step: number;
  fanMode: string | null;
  readonly availableFanModes: readonly string[];
}

export interface FanSpec {
  readonly kind: "fan";
  readonly entityId: string;
  isOn: boolean;
  percentage: number | null;
  presetMode: string | null;
  readonly availablePresetModes: readonly string[];
  isOscillating: boolean | null;
}

export interface PlugSpec {
  readonly kind: "plug";
  readonly switchEntityId: string;
  isOn: boolean;
  readonly powerWatts: number | null;
  readonly energyKwh?: number | null;
  readonly childLockEntityId: string | null;
  isChildLocked: boolean;
}

export interface VacuumSpec {
  readonly kind: "vacuum";
  readonly entityId: string;
  status: string;
  readonly battery: number | null;
  readonly modeEntityId: string | null;
  currentMode: string | null;
  readonly availableModes: readonly string[];
}

export interface SensorSpec {
  readonly kind: "sensor";
  readonly temperature: number | null;
  readonly humidity: number | null;
  readonly battery: number | null;
}

export type DeviceKind =
  | LightSpec
  | ClimateSpec
  | FanSpec
  | PlugSpec
  | VacuumSpec
  | SensorSpec;

export interface SmartDevice {
  readonly id: string;
  readonly name: string;
  readonly roomId: string;
  readonly roomName: string;
  readonly model: string;
  readonly isOnline: boolean;
  kind: DeviceKind;
}

export interface RoomCategory {
  readonly id: string;
  readonly name: string;
  readonly deviceCount: number;
}

export interface EnvironmentReading {
  readonly id: string;
  readonly label: string;
  readonly roomName: string;
  readonly temperature: number | null;
  readonly humidity: number | null;
  readonly battery: number | null;
}

export interface HomeScene {
  readonly id: string;
  readonly name: string;
  readonly entityId: string;
}

export interface SynthesizedHome {
  readonly devices: SmartDevice[];
  readonly rooms: RoomCategory[];
  readonly environmentReadings: EnvironmentReading[];
  readonly scenes: HomeScene[];
}

export type VacuumAction = "start" | "pause" | "returnToBase";

export type DeviceCommand =
  | { readonly kind: "setLightPower"; readonly entityId: string; readonly isOn: boolean }
  | { readonly kind: "setLightBrightness"; readonly entityId: string; readonly percent: number }
  | { readonly kind: "setLightColorTemp"; readonly entityId: string; readonly kelvin: number }
  | { readonly kind: "setLightEffect"; readonly entityId: string; readonly effect: string }
  | { readonly kind: "setClimatePower"; readonly entityId: string; readonly isOn: boolean; readonly resumeMode: string }
  | { readonly kind: "setClimateMode"; readonly entityId: string; readonly hvacMode: string }
  | { readonly kind: "setClimateTemperature"; readonly entityId: string; readonly temperature: number }
  | { readonly kind: "setClimateFanMode"; readonly entityId: string; readonly fanMode: string }
  | { readonly kind: "setFanPower"; readonly entityId: string; readonly isOn: boolean }
  | { readonly kind: "setFanPresetMode"; readonly entityId: string; readonly presetMode: string }
  | { readonly kind: "setFanOscillating"; readonly entityId: string; readonly oscillating: boolean }
  | { readonly kind: "setSwitch"; readonly entityId: string; readonly isOn: boolean }
  | { readonly kind: "vacuumAction"; readonly entityId: string; readonly action: VacuumAction }
  | { readonly kind: "activateScene"; readonly entityId: string };

export type IntentOperation =
  | { readonly kind: "power"; readonly isOn: boolean }
  | { readonly kind: "brightness"; readonly percent: number }
  | { readonly kind: "brightnessStep"; readonly delta: number }
  | { readonly kind: "colorTemperature"; readonly kelvin: number }
  | { readonly kind: "lightEffect"; readonly effect: string }
  | { readonly kind: "hvacMode"; readonly mode: string }
  | { readonly kind: "targetTemperature"; readonly celsius: number }
  | { readonly kind: "temperatureStep"; readonly delta: number }
  | { readonly kind: "fanSpeed"; readonly speed: string }
  | { readonly kind: "oscillation"; readonly enabled: boolean }
  | { readonly kind: "activateScene" };

export interface DeviceIntent {
  readonly targetId: string;
  readonly operation: IntentOperation;
}

export interface AssistantSuggestion {
  readonly id: string;
  readonly title: string;
  readonly confidencePercent: number | null;
  readonly intents: readonly DeviceIntent[];
}

export interface IntentPlan {
  readonly intents: readonly DeviceIntent[];
  readonly reply: string;
  readonly source: "local" | "model";
  readonly suggestions: readonly AssistantSuggestion[];
}

export interface ScheduledCommand {
  readonly id: string;
  readonly command: string;
  readonly delaySeconds: number;
  readonly fireTimestampMs: number;
  readonly reply: string;
}

/** Plugs often power a router, fridge or NAS, and 全关 should not send a cleaning vacuum home (#23). */
export function joinsAllOffByDefault(device: SmartDevice): boolean {
  return device.kind.kind !== "plug" && device.kind.kind !== "vacuum";
}

export function joinsAllOff(device: SmartDevice, overrides: Readonly<Record<string, boolean>>): boolean {
  return overrides[device.id] ?? joinsAllOffByDefault(device);
}

/** What 全关 turns off: the devices on screen that are on and take part in 全关. */
export function allOffTargets(
  visible: readonly SmartDevice[],
  overrides: Readonly<Record<string, boolean>>
): SmartDevice[] {
  return visible.filter((d) => isDeviceActiveOn(d) && joinsAllOff(d, overrides));
}

/** A timer that comes due more than this late (the PC slept, the app was frozen) waits for the user (#22). */
export const LATE_TIMER_GRACE_MS = 60_000;

/** Splits timers into ones to run now, ones that were missed, and ones still counting down. */
export function partitionDueTimers(
  items: readonly ScheduledCommand[],
  nowMs: number,
  graceMs = LATE_TIMER_GRACE_MS
): { run: ScheduledCommand[]; missed: ScheduledCommand[]; remaining: ScheduledCommand[] } {
  const run: ScheduledCommand[] = [];
  const missed: ScheduledCommand[] = [];
  const remaining: ScheduledCommand[] = [];
  for (const item of items) {
    if (item.fireTimestampMs > nowMs) remaining.push(item);
    else if (nowMs - item.fireTimestampMs > graceMs) missed.push(item);
    else run.push(item);
  }
  return { run, missed, remaining };
}

/** Xiaomi cloud refresh while the panel is open (#26). Matches macOS PollingPolicy.panelOpenInterval. */
export const CLOUD_REFRESH_VISIBLE_MS = 6_000;
export const CLOUD_REFRESH_HIDDEN_MS = 60_000;

/** True when the last cloud refresh is older than the interval for the panel's visibility. */
export function cloudRefreshDue(nowMs: number, lastRefreshMs: number | null, panelVisible: boolean): boolean {
  if (lastRefreshMs === null) return true;
  return nowMs - lastRefreshMs >= (panelVisible ? CLOUD_REFRESH_VISIBLE_MS : CLOUD_REFRESH_HIDDEN_MS);
}

export function isDeviceActiveOn(device: SmartDevice): boolean {
  switch (device.kind.kind) {
    case "light":
    case "climate":
    case "fan":
    case "plug":
      return device.kind.isOn;
    case "vacuum":
      return device.kind.status === "cleaning";
    case "sensor":
      return false;
    default: {
      const _exhaustive: never = device.kind;
      return _exhaustive;
    }
  }
}

export function deviceStatusSummary(device: SmartDevice): string {
  if (!device.isOnline) return t("离线");
  const k = device.kind;
  switch (k.kind) {
    case "light": {
      if (!k.isOn) return t("已关闭");
      const parts: string[] = [t("已开启")];
      if (k.currentEffect) {
        const effect = k.currentEffect.toLowerCase();
        parts.push(
          effect === "night" ? t("月光") : effect === "day" ? t("日光") : k.currentEffect
        );
      }
      if (k.brightnessPercent !== null) parts.push(`${k.brightnessPercent}%`);
      if (k.colorTempKelvin !== null) parts.push(`${k.colorTempKelvin}K`);
      return parts.join(" · ");
    }
    case "climate": {
      const modeMap: Record<string, string> = {
        cool: t("制冷"),
        heat: t("制热"),
        dry: t("除湿"),
        fan_only: t("送风"),
        auto: t("自动"),
        off: t("已关闭"),
      };
      if (!k.isOn || k.hvacMode === "off") {
        return k.currentTemperature !== null
          ? t("已关闭 · 室温 {temp}", { temp: formatTemperature(k.currentTemperature) })
          : t("已关闭");
      }
      const modeLabel = modeMap[k.hvacMode] ?? k.hvacMode;
      const roomPart = k.currentTemperature !== null
        ? ` · ${t("室温 {temp}", { temp: formatTemperature(k.currentTemperature) })}`
        : "";
      return `${modeLabel} ${formatTemperature(k.targetTemperature)}${roomPart}`;
    }
    case "fan": {
      if (!k.isOn) return t("已关闭");
      const parts: string[] = [t("运行中")];
      if (k.presetMode) parts.push(k.presetMode);
      if (k.isOscillating) parts.push(t("摇头"));
      return parts.join(" · ");
    }
    case "plug": {
      if (!k.isOn) return t("已断电");
      return k.powerWatts !== null ? t("供电中 · {watts}W", { watts: k.powerWatts.toFixed(1) }) : t("供电中");
    }
    case "vacuum": {
      const map: Record<string, string> = {
        cleaning: t("清扫中"),
        paused: t("已暂停"),
        returning: t("回充中"),
        docked: t("充电座待命"),
        idle: t("待命"),
      };
      const base = map[k.status] ?? k.status;
      return k.battery !== null ? `${base} · ${k.battery}%` : base;
    }
    case "sensor": {
      const parts: string[] = [];
      if (k.temperature !== null) parts.push(formatTemperature(k.temperature, undefined, 1));
      if (k.humidity !== null) parts.push(`${Math.round(k.humidity)}%`);
      return parts.length > 0 ? parts.join(" · ") : t("在线");
    }
    default: {
      const _exhaustive: never = k;
      return _exhaustive;
    }
  }
}
