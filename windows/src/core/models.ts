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
  readonly pm25Density?: number | null;
  readonly airQuality?: string | null;
  readonly temperature?: number | null;
  readonly humidity?: number | null;
  readonly filterLifePercent?: number | null;
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

export interface CameraSpec {
  readonly kind: "camera";
  readonly entityId: string;
  isOn: boolean;
  nightShot: string | null;
  readonly availableNightShots: readonly string[];
  readonly motionDetectionEntityId: string | null;
  isMotionDetectionOn: boolean | null;
  readonly streamEntityId: string | null;
  /** HA-only still frame URL; always absent on the MIoT backend (model parity with macOS). */
  readonly snapshotPath?: string | null;
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
  | CameraSpec
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
  | { readonly kind: "setFanPercentage"; readonly entityId: string; readonly percent: number }
  | { readonly kind: "setFanPresetMode"; readonly entityId: string; readonly presetMode: string }
  | { readonly kind: "setFanOscillating"; readonly entityId: string; readonly oscillating: boolean }
  | { readonly kind: "setSwitch"; readonly entityId: string; readonly isOn: boolean }
  | { readonly kind: "setSelectOption"; readonly entityId: string; readonly option: string }
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
  return (
    device.kind.kind !== "plug" &&
    device.kind.kind !== "vacuum" &&
    device.kind.kind !== "camera"
  );
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
    case "camera":
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

export function localizeNightShot(mode: string): string {
  switch (mode.trim().toLowerCase()) {
    case "off":
    case "close":
      return t("夜视关");
    case "on":
    case "open":
      return t("夜视开");
    case "auto":
    case "automatic":
      return t("自动夜视");
    case "auto full color":
    case "smart full color":
    case "auto smart full color":
      return t("智能全彩");
    case "on full color":
    case "full color":
      return t("全彩夜视");
    default:
      return mode;
  }
}

export function localizeFanPreset(mode: string): string {
  switch (mode.trim().toLowerCase()) {
    case "auto":
    case "automatic":
      return t("自动");
    case "sleep":
      return t("睡眠");
    case "favorite":
    case "favourite":
      return t("最爱");
    case "manual":
    case "none":
      return t("手动");
    case "silent":
      return t("静音");
    default:
      return mode;
  }
}

export function localizeAirQuality(raw: string | null | undefined, pm25?: number | null): string | null {
  if (raw && raw.trim() !== "") {
    switch (raw.trim().toLowerCase()) {
      case "excellent":
      case "空气优":
      case "优":
        return t("优");
      case "good":
      case "空气良":
      case "良":
        return t("良");
      case "moderate":
      case "轻度污染":
        return t("轻度污染");
      case "poor":
      case "中度污染":
        return t("中度污染");
      case "heavy pollution":
      case "heavy":
      case "重度污染":
        return t("重度污染");
      case "hazardous":
      case "严重污染":
        return t("严重污染");
      default:
        return raw;
    }
  }
  if (pm25 === undefined || pm25 === null) return null;
  if (pm25 <= 35) return t("优");
  if (pm25 <= 75) return t("良");
  if (pm25 <= 115) return t("轻度污染");
  if (pm25 <= 150) return t("中度污染");
  if (pm25 <= 250) return t("重度污染");
  return t("严重污染");
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
      const envParts: string[] = [];
      if (k.pm25Density !== undefined && k.pm25Density !== null) {
        const aq = localizeAirQuality(k.airQuality, k.pm25Density);
        envParts.push(aq ? `PM2.5 ${k.pm25Density} ${aq}` : `PM2.5 ${k.pm25Density}`);
      } else if (k.airQuality) {
        const aq = localizeAirQuality(k.airQuality, null);
        if (aq) envParts.push(aq);
      }
      if (k.temperature !== undefined && k.temperature !== null && k.humidity !== undefined && k.humidity !== null) {
        envParts.push(`${formatTemperature(k.temperature, undefined, 0)} ${Math.round(k.humidity)}%`);
      } else if (k.temperature !== undefined && k.temperature !== null) {
        envParts.push(formatTemperature(k.temperature, undefined, 1));
      } else if (k.humidity !== undefined && k.humidity !== null) {
        envParts.push(`${Math.round(k.humidity)}%`);
      }
      if (!k.isOn) {
        return envParts.length > 0 ? [t("已关闭"), ...envParts].join(" · ") : t("已关闭");
      }
      const parts: string[] = [t("运行中")];
      if (k.presetMode) parts.push(localizeFanPreset(k.presetMode));
      if (k.percentage !== null) parts.push(`${k.percentage}%`);
      if (k.isOscillating) parts.push(t("摇头"));
      parts.push(...envParts);
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
    case "camera": {
      if (!k.isOn) return t("休眠中 · 点击唤醒");
      const parts: string[] = [t("监控中")];
      if (k.nightShot) parts.push(localizeNightShot(k.nightShot));
      if (k.isMotionDetectionOn) parts.push(t("侦测开"));
      parts.push(t("点击看画面"));
      return parts.join(" · ");
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
