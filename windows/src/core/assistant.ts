import type { HttpTransport } from "./miCloudClient.js";
import type {
  AssistantSuggestion,
  DeviceCommand,
  DeviceIntent,
  EnvironmentReading,
  HomeScene,
  IntentOperation,
  IntentPlan,
  SmartDevice,
} from "./models.js";
import { isDeviceActiveOn } from "./models.js";

// MARK: - Spoken Delay & Undo Phrases

export interface ParsedDelay {
  readonly seconds: number;
  readonly remainder: string;
}

const CN_DIGITS: Readonly<Record<string, number>> = {
  一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10,
  十五: 15, 二十: 20, 三十: 30, 四十五: 45,
};

function parseCnOrArabicNumber(s: string): number | null {
  const n = Number(s);
  if (Number.isFinite(n) && n > 0) return n;
  return CN_DIGITS[s] ?? null;
}

const EN_CANCEL_PHRASES = [
  "cancel timer", "cancel timers", "cancel all timers",
  "clear timer", "clear timers", "clear all timers",
  "stop timer", "stop timers", "stop all timers",
];

function buildDelay(val: number | null, unitMultiplier: number, remainder: string): ParsedDelay | null {
  const rem = remainder.trim();
  if (val === null || !Number.isFinite(val) || val <= 0 || !rem) return null;
  const seconds = Math.round(val * unitMultiplier);
  if (seconds <= 0 || seconds > 86400) return null;
  return { seconds, remainder: rem };
}

function englishUnitMultiplier(unitRaw: string): number {
  const u = unitRaw.toLowerCase();
  return u.startsWith("h") ? 3600 : u.startsWith("m") ? 60 : 1;
}

function chineseUnitMultiplier(unitRaw: string): number {
  return unitRaw.startsWith("小") || unitRaw.startsWith("钟") ? 3600 : unitRaw.startsWith("分") ? 60 : 1;
}

export const DelayPhrase = {
  isCancel(utterance: string): boolean {
    const lower = utterance.toLowerCase().trim();
    if (EN_CANCEL_PHRASES.some((p) => lower.includes(p))) return true;
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    return clean === "取消定时" || clean === "取消倒计时" || clean === "取消所有定时" || clean === "清除定时";
  },

  extract(utterance: string): ParsedDelay | null {
    const trimmed = utterance.trim();
    const enLead = /^(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b[,\s]*(.+)$/i.exec(trimmed);
    if (enLead) {
      return buildDelay(Number(enLead[1]), englishUnitMultiplier(enLead[2] ?? ""), enLead[3] ?? "");
    }
    const enTrail = /^(.+?)[,\s]+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\s*$/i.exec(trimmed);
    if (enTrail) {
      return buildDelay(Number(enTrail[2]), englishUnitMultiplier(enTrail[3] ?? ""), enTrail[1] ?? "");
    }
    if (/^半小时(?:以)?后(.+)$/.test(trimmed)) {
      const m = /^半小时(?:以)?后(.+)$/.exec(trimmed);
      return buildDelay(1800, 1, m?.[1] ?? "");
    }
    const regex = /^(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)\s*(秒钟?|分钟?|小时|钟头)(?:以)?后?[，,\s]*(.+)$/;
    const front = regex.exec(trimmed);
    if (front) {
      return buildDelay(parseCnOrArabicNumber(front[1] ?? ""), chineseUnitMultiplier(front[2] ?? ""), front[3] ?? "");
    }
    const backRegex = /^(.+?)[，,\s]*(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)\s*(秒钟?|分钟?|小时|钟头)(?:以)?后$/;
    const back = backRegex.exec(trimmed);
    if (back) {
      return buildDelay(parseCnOrArabicNumber(back[2] ?? ""), chineseUnitMultiplier(back[3] ?? ""), back[1] ?? "");
    }
    return null;
  },

  formatDelay(seconds: number): string {
    if (seconds % 3600 === 0) return `${seconds / 3600} 小时`;
    if (seconds % 60 === 0) return `${seconds / 60} 分钟`;
    return `${seconds} 秒`;
  },
};

const EN_UNDO_SET = new Set(["undo", "revert", "undo that", "revert that", "cancel that"]);

export const UndoPhrase = {
  isUndo(utterance: string): boolean {
    const lower = utterance.toLowerCase().replace(/^[，。！？,.!?\s]+|[，。！？,.!?\s]+$/g, "");
    if (EN_UNDO_SET.has(lower)) return true;
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    return ["撤销", "撤回", "刚才那个撤销", "撤销刚才的操作", "恢复刚才的状态"].includes(clean);
  },
};

// MARK: - Intent Validation & Normalization

export const IntentValidator = {
  normalize(op: IntentOperation, device: SmartDevice): IntentOperation | null {
    const k = device.kind;
    switch (op.kind) {
      case "power": {
        if (
          k.kind === "light" ||
          k.kind === "climate" ||
          k.kind === "fan" ||
          k.kind === "plug" ||
          k.kind === "vacuum" ||
          k.kind === "camera"
        ) {
          return op;
        }
        return null;
      }
      case "brightness": {
        if (k.kind !== "light") return null;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(op.percent))) };
      }
      case "brightnessStep": {
        if (k.kind !== "light") return null;
        const base = k.isOn ? (k.brightnessPercent ?? 50) : 0;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(base + op.delta))) };
      }
      case "colorTemperature": {
        if (k.kind !== "light") return null;
        return {
          kind: "colorTemperature",
          kelvin: Math.max(k.minKelvin, Math.min(k.maxKelvin, Math.round(op.kelvin))),
        };
      }
      case "lightEffect": {
        if (k.kind !== "light") return null;
        const matched = k.availableEffects.find((e) => e.toLowerCase() === op.effect.toLowerCase());
        return matched ? { kind: "lightEffect", effect: matched } : null;
      }
      case "hvacMode": {
        if (k.kind === "climate") {
          const matched = k.availableModes.find((m) => m.toLowerCase() === op.mode.toLowerCase());
          return matched ? { kind: "hvacMode", mode: matched } : null;
        }
        // 「自动模式」 parses as hvacMode(auto); on a fan that means its Auto preset (#98).
        if (k.kind === "fan" && op.mode.toLowerCase() === "auto") {
          const m = k.availablePresetModes.find((p) => /auto|自动|smart|natural/i.test(p));
          return m ? { kind: "fanSpeed", speed: m } : null;
        }
        return null;
      }
      case "targetTemperature": {
        if (k.kind !== "climate") return null;
        const clamped = Math.max(k.minTemp, Math.min(k.maxTemp, op.celsius));
        return { kind: "targetTemperature", celsius: clamped };
      }
      case "temperatureStep": {
        if (k.kind !== "climate") return null;
        const next = Math.max(k.minTemp, Math.min(k.maxTemp, k.targetTemperature + op.delta));
        return { kind: "targetTemperature", celsius: next };
      }
      case "fanSpeed": {
        const list =
          k.kind === "fan"
            ? k.availablePresetModes
            : k.kind === "climate"
              ? k.availableFanModes
              : null;
        if (!list || list.length === 0) return null;
        const exact = list.find((m) => m.toLowerCase() === op.speed.toLowerCase());
        if (exact) return { kind: "fanSpeed", speed: exact };
        const s = op.speed.toLowerCase();
        if (s === "auto" || s === "自动") {
          const autoMatch = list.find((m) => /auto|自动|smart|natural/i.test(m));
          return autoMatch ? { kind: "fanSpeed", speed: autoMatch } : null;
        }
        if (s === "sleep" || s === "睡眠" || s === "silent" || s === "静音") {
          const sleepMatch = list.find((m) => /sleep|睡眠|silent|静音/i.test(m));
          return sleepMatch ? { kind: "fanSpeed", speed: sleepMatch } : null;
        }
        if (s === "favorite" || s === "favourite" || s === "最爱" || s === "manual" || s === "手动") {
          const favMatch = list.find((m) => /favorite|favourite|最爱|manual|手动/i.test(m));
          return favMatch ? { kind: "fanSpeed", speed: favMatch } : null;
        }
        const ranked = list.filter((m) => !/auto|自动|sleep|睡眠|silent|静音|favorite|favourite|最爱/i.test(m));
        const pool = ranked.length > 0 ? ranked : list;
        if (s === "low" || s === "低" || s === "1") {
          const first = pool[0];
          return first ? { kind: "fanSpeed", speed: first } : null;
        }
        if (s === "medium" || s === "中" || s === "2") {
          const mid = pool[Math.floor((pool.length - 1) / 2)];
          return mid ? { kind: "fanSpeed", speed: mid } : null;
        }
        if (s === "high" || s === "高" || s === "3") {
          const last = pool[pool.length - 1];
          return last ? { kind: "fanSpeed", speed: last } : null;
        }
        return null;
      }
      case "oscillation": {
        if (k.kind !== "fan") return null;
        return op;
      }
      case "activateScene":
        return null;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },

  sanitize(
    raw: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): DeviceIntent[] {
    const devMap = new Map(devices.map((d) => [d.id, d]));
    const sceneSet = new Set(scenes.map((s) => s.id));
    const out: DeviceIntent[] = [];
    for (const intent of raw) {
      if (intent.operation.kind === "activateScene") {
        if (sceneSet.has(intent.targetId)) out.push(intent);
        continue;
      }
      const dev = devMap.get(intent.targetId);
      if (!dev) continue;
      const norm = this.normalize(intent.operation, dev);
      if (norm) {
        out.push({ targetId: dev.id, operation: norm });
      }
    }
    return out;
  },

  commandsForIntent(intent: DeviceIntent, device: SmartDevice): DeviceCommand[] {
    const k = device.kind;
    const op = intent.operation;
    switch (op.kind) {
      case "power": {
        if (k.kind === "light") return [{ kind: "setLightPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "climate")
          return [{ kind: "setClimatePower", entityId: k.entityId, isOn: op.isOn, resumeMode: "cool" }];
        if (k.kind === "fan") return [{ kind: "setFanPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "plug") return [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: op.isOn }];
        if (k.kind === "camera") return [{ kind: "setSwitch", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "vacuum")
          return [{ kind: "vacuumAction", entityId: k.entityId, action: op.isOn ? "start" : "returnToBase" }];
        return [];
      }
      case "brightness":
        return k.kind === "light" ? [{ kind: "setLightBrightness", entityId: k.entityId, percent: op.percent }] : [];
      case "colorTemperature":
        return k.kind === "light" ? [{ kind: "setLightColorTemp", entityId: k.entityId, kelvin: op.kelvin }] : [];
      case "lightEffect":
        return k.kind === "light" ? [{ kind: "setLightEffect", entityId: k.entityId, effect: op.effect }] : [];
      case "hvacMode":
        return k.kind === "climate" ? [{ kind: "setClimateMode", entityId: k.entityId, hvacMode: op.mode }] : [];
      case "targetTemperature":
        return k.kind === "climate"
          ? [{ kind: "setClimateTemperature", entityId: k.entityId, temperature: op.celsius }]
          : [];
      case "fanSpeed":
        if (k.kind === "fan") return [{ kind: "setFanPresetMode", entityId: k.entityId, presetMode: op.speed }];
        if (k.kind === "climate") return [{ kind: "setClimateFanMode", entityId: k.entityId, fanMode: op.speed }];
        return [];
      case "oscillation":
        return k.kind === "fan" ? [{ kind: "setFanOscillating", entityId: k.entityId, oscillating: op.enabled }] : [];
      case "brightnessStep":
      case "temperatureStep":
      case "activateScene":
        return [];
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

export const IntentReply = {
  fanSpeedLabel(speed: string): string {
    const m = /^level\s*([0-9]+)$/i.exec(speed.trim());
    if (m?.[1]) return `${m[1]} 档`;
    const map: Record<string, string> = {
      low: "低档",
      medium: "中档",
      high: "高档",
      auto: "自动",
      sleep: "睡眠",
      silent: "静音",
      favorite: "最爱",
      favourite: "最爱",
      manual: "手动",
    };
    return map[speed.toLowerCase()] ?? speed;
  },

  describe(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): string {
    if (intents.length === 0) return "未找到可执行的设备操作";
    const devMap = new Map(devices.map((d) => [d.id, d.name]));
    const sceneMap = new Map(scenes.map((s) => [s.id, s.name]));

    const firstOp = intents[0]?.operation;
    if (
      firstOp &&
      intents.every((i) => JSON.stringify(i.operation) === JSON.stringify(firstOp))
    ) {
      const names = intents
        .map((i) => devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId)
        .join("、");
      return this.describeOp(firstOp, names);
    }

    const parts = intents.map((i) => {
      const name = devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId;
      return this.describeOp(i.operation, name).replace(/^已/, "");
    });
    return `已${parts.join("，")}`;
  },

  describeOp(op: IntentOperation, targetNames: string): string {
    switch (op.kind) {
      case "power":
        return `已${op.isOn ? "打开" : "关闭"}${targetNames}`;
      case "brightness":
        return `已${targetNames}亮度调至 ${op.percent}%`;
      case "colorTemperature":
        return `已${targetNames}色温调至 ${op.kelvin}K`;
      case "lightEffect": {
        const label =
          op.effect.toLowerCase() === "night"
            ? "月光模式"
            : op.effect.toLowerCase() === "day"
              ? "日光模式"
              : op.effect;
        return `已${targetNames}切换为${label}`;
      }
      case "hvacMode": {
        const map: Record<string, string> = {
          cool: "制冷",
          heat: "制热",
          dry: "除湿",
          fan_only: "送风",
          auto: "自动",
          off: "关闭",
        };
        return `已${targetNames}设为${map[op.mode] ?? op.mode}模式`;
      }
      case "targetTemperature":
        return `已${targetNames}设为 ${op.celsius}°C`;
      case "fanSpeed":
        return `已${targetNames}风速调为 ${this.fanSpeedLabel(op.speed)}`;
      case "oscillation":
        return `已${targetNames}${op.enabled ? "开启摇头" : "停止摇头"}`;
      case "activateScene":
        return `已执行${targetNames}`;
      case "brightnessStep":
      case "temperatureStep":
        return `已调节${targetNames}`;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

// MARK: - 0ms Local Intent Parser

type IntentCategory = "light" | "climate" | "heater" | "fan" | "airPurifier" | "plug" | "vacuum" | "tv" | "camera" | "other";

const CONSUMED_MARKER = "\u001f";

function isAirPurifierDevice(dev: SmartDevice): boolean {
  if (dev.kind.kind !== "fan") return false;
  const m = dev.model.toLowerCase();
  return (
    m.includes("airp") ||
    m.includes("purifier") ||
    dev.name.includes("净化") ||
    dev.name.includes("空净") ||
    dev.kind.pm25Density != null ||
    dev.kind.airQuality != null ||
    dev.kind.filterLifePercent != null
  );
}

function deviceCategory(dev: SmartDevice): IntentCategory {
  if (dev.kind.kind === "light") return "light";
  if (dev.kind.kind === "climate") {
    return dev.model.includes("heater") || dev.name.includes("暖") ? "heater" : "climate";
  }
  if (dev.kind.kind === "fan") return isAirPurifierDevice(dev) ? "airPurifier" : "fan";
  if (dev.kind.kind === "plug") return "plug";
  if (dev.kind.kind === "vacuum") return "vacuum";
  if (dev.kind.kind === "camera") return "camera";
  return "other";
}

function isAssistantControllable(cat: IntentCategory): boolean {
  return cat !== "other";
}

function isRelativeOp(op: IntentOperation): boolean {
  return op.kind === "brightnessStep" || op.kind === "temperatureStep";
}

function impliedCategories(ops: readonly IntentOperation[]): Set<IntentCategory> | null {
  for (const op of ops) {
    switch (op.kind) {
      case "brightness":
      case "brightnessStep":
      case "colorTemperature":
      case "lightEffect":
        return new Set(["light"]);
      case "hvacMode":
      case "targetTemperature":
      case "temperatureStep":
        return new Set(["climate", "heater"]);
      case "fanSpeed":
        return new Set(["fan", "airPurifier", "climate"]);
      case "oscillation":
        return new Set(["fan"]);
      case "power":
      case "activateScene":
        continue;
    }
  }
  return null;
}

function dispatchRank(op: IntentOperation): number {
  switch (op.kind) {
    case "power": return 0;
    case "hvacMode": return 1;
    case "targetTemperature":
    case "temperatureStep": return 2;
    case "lightEffect": return 3;
    case "brightness":
    case "brightnessStep": return 4;
    case "colorTemperature": return 5;
    case "activateScene": return 6;
    case "fanSpeed": return 7;
    case "oscillation": return 8;
  }
}

function reconcileOps(ops: readonly IntentOperation[]): IntentOperation[] | null {
  if (ops.length === 0) return null;
  const byRank = new Map<number, IntentOperation>();
  for (const op of ops) {
    const rank = dispatchRank(op);
    const existing = byRank.get(rank);
    if (existing && JSON.stringify(existing) !== JSON.stringify(op)) return null;
    byRank.set(rank, op);
  }
  const p = byRank.get(0);
  if (p?.kind === "power" && !p.isOn && byRank.size > 1) return null;
  if (p?.kind === "power" && p.isOn && (byRank.has(1) || byRank.has(3) || byRank.has(4) || byRank.has(5))) {
    byRank.delete(0);
  }
  return Array.from(byRank.keys())
    .sort((a, b) => a - b)
    .map((k) => byRank.get(k)!);
}

function buildPlanFromCandidates(
  candidates: readonly SmartDevice[],
  mustAcceptIds: ReadonlySet<string>,
  ops: readonly IntentOperation[],
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentPlan | null {
  const intents: DeviceIntent[] = [];
  for (const dev of candidates) {
    const normOps = ops
      .map((o) => IntentValidator.normalize(o, dev))
      .filter((o): o is IntentOperation => o !== null);
    if (normOps.length !== ops.length) {
      if (mustAcceptIds.has(dev.id)) return null;
      continue;
    }
    for (const no of normOps) {
      intents.push({ targetId: dev.id, operation: no });
    }
  }
  if (intents.length === 0) return null;
  return {
    intents,
    reply: IntentReply.describe(intents, devices, scenes),
    source: "local",
    suggestions: [],
  };
}

const EN_ROOM_ALIASES: Readonly<Record<string, readonly string[]>> = {
  "master bedroom": ["主卧", "卧室", "master bedroom", "master"],
  "second bedroom": ["次卧", "小卧室", "second bedroom", "guest"],
  "guest room": ["次卧", "小卧室", "guest room"],
  "living room": ["客厅", "living room", "living"],
  "dining room": ["餐厅", "dining room", "dining"],
  "study room": ["书房", "study"],
  study: ["书房", "study"],
  bedroom: ["卧室", "主卧", "bedroom"],
  kitchen: ["厨房", "kitchen"],
  balcony: ["阳台", "balcony"],
  bathroom: ["卫生间", "浴室", "bathroom", "bath"],
  entryway: ["玄关", "entryway", "entry"],
};

const EN_SCOPE_WORDS = [
  "whole home", "entire home", "whole house", "everywhere", "everything", "all", "every",
];

const EN_CATEGORY_WORDS: ReadonlyArray<readonly [string, IntentCategory]> = [
  ["air conditioner", "climate"], ["air conditioning", "climate"],
  ["ceiling lights", "light"], ["ceiling light", "light"],
  ["bedside lamp", "light"], ["desk lamp", "light"], ["table lamp", "light"],
  ["screen bar", "light"], ["light strip", "light"],
  ["robot vacuum", "vacuum"], ["smart plug", "plug"], ["space heater", "heater"],
  ["standing fan", "fan"], ["air purifiers", "airPurifier"], ["air purifier", "airPurifier"],
  ["purifiers", "airPurifier"], ["purifier", "airPurifier"],
  ["lights", "light"], ["light", "light"], ["lamps", "light"], ["lamp", "light"],
  ["climate", "climate"], ["ac", "climate"],
  ["heater", "heater"],
  ["fans", "fan"], ["fan", "fan"],
  ["plugs", "plug"], ["plug", "plug"], ["socket", "plug"], ["outlet", "plug"],
  ["vacuum", "vacuum"],
  ["television", "tv"], ["tv", "tv"],
  ["cameras", "camera"], ["camera", "camera"],
];

const EN_FILLERS = [
  "please", "can", "could", "would", "you", "help", "me",
  "the", "my", "a", "an", "in", "at", "to", "by", "for", "into", "of",
  "set", "change", "switch", "adjust", "make", "it", "bit", "little",
  "mode", "room", "temperature", "temp", "brightness", "level", "speed",
].sort((a, b) => b.length - a.length);

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function consumeEnglishPhrase(phrase: string, state: { rest: string }): boolean {
  if (!phrase) return false;
  const escaped = escapeRegex(phrase);
  const isAscii = /^[\x00-\x7f]+$/.test(phrase);
  const pattern = isAscii ? `(?<![a-z0-9])${escaped}(?![a-z0-9])` : escaped;
  const regex = new RegExp(pattern, "g");
  if (!regex.test(state.rest)) return false;
  state.rest = state.rest.replace(new RegExp(pattern, "g"), ` ${CONSUMED_MARKER} `);
  return true;
}

function extractEnglishNumericOps(state: { rest: string }): IntentOperation[] {
  const ops: IntentOperation[] = [];
  const stepRegex = /(?<![a-z])(increase|raise|up|decrease|lower|down)(?:\s+by)?\s+(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)(?![a-z])/g;
  let stepMatched = false;
  for (const m of state.rest.matchAll(stepRegex)) {
    const dir = m[1] ?? "";
    const amount = Number(m[2]);
    if (Number.isFinite(amount)) {
      const sign = dir === "increase" || dir === "raise" || dir === "up" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      stepMatched = true;
    }
  }
  if (stepMatched) {
    state.rest = state.rest.replace(stepRegex, ` ${CONSUMED_MARKER} `);
  }

  const trailingStepRegex = /(?<![a-z0-9])(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)\s+(warmer|hotter|higher|cooler|colder|lower)(?![a-z])/g;
  let trailingStepMatched = false;
  for (const m of state.rest.matchAll(trailingStepRegex)) {
    const amount = Number(m[1]);
    const dir = m[2] ?? "";
    if (Number.isFinite(amount)) {
      const sign = dir === "warmer" || dir === "hotter" || dir === "higher" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      trailingStepMatched = true;
    }
  }
  if (trailingStepMatched) {
    state.rest = state.rest.replace(trailingStepRegex, ` ${CONSUMED_MARKER} `);
  }

  const numericPatterns: ReadonlyArray<readonly [RegExp, (val: number) => IntentOperation]> = [
    [/(?<![a-z0-9])(\d{4})\s*k(?![a-z0-9])/g, (v) => ({ kind: "colorTemperature", kelvin: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,3})\s*(?:%|percent)(?![a-z0-9])/g, (v) => ({ kind: "brightness", percent: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,2}(?:\.\d)?)\s*(?:degrees?\s*celsius|degrees?|deg|℃|°c|°)(?![a-z0-9])/g, (v) => ({ kind: "targetTemperature", celsius: v })],
  ];
  for (const [regex, make] of numericPatterns) {
    let matched = false;
    for (const m of state.rest.matchAll(regex)) {
      const val = Number(m[1]);
      if (Number.isFinite(val)) {
        ops.push(make(val));
        matched = true;
      }
    }
    if (matched) {
      state.rest = state.rest.replace(regex, ` ${CONSUMED_MARKER} `);
    }
  }
  return ops;
}

export const LocalIntentParser = {
  parse(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan | null {
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    if (!clean) return null;

    if (!/[\u4e00-\u9fff]/.test(utterance) && /[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes);
    }

    for (const scene of scenes) {
      if (clean === scene.name || clean === `执行${scene.name}` || clean === `打开${scene.name}` || clean === `开启${scene.name}`) {
        const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
        return {
          intents,
          reply: IntentReply.describe(intents, devices, scenes),
          source: "local",
          suggestions: [],
        };
      }
    }

    let ops: IntentOperation[] = [];
    if (clean.includes("月光模式") || clean.includes("夜灯模式") || clean.includes("月光")) {
      ops.push({ kind: "lightEffect", effect: "Night" });
    } else if (clean.includes("日光模式") || clean.includes("日光")) {
      ops.push({ kind: "lightEffect", effect: "Day" });
    }

    const ctMatch = /(\d{4})[kK]/.exec(clean);
    if (ctMatch?.[1]) {
      ops.push({ kind: "colorTemperature", kelvin: Number(ctMatch[1]) });
    } else if (clean.includes("暖光") || clean.includes("暖色") || clean.includes("黄光")) {
      ops.push({ kind: "colorTemperature", kelvin: 2700 });
    } else if (clean.includes("自然光")) {
      ops.push({ kind: "colorTemperature", kelvin: 4000 });
    } else if (clean.includes("白光") || clean.includes("冷光")) {
      ops.push({ kind: "colorTemperature", kelvin: 6500 });
    }

    if (clean.includes("再暗一点") || clean.includes("暗一点") || clean.includes("调暗一点")) {
      ops.push({ kind: "brightnessStep", delta: -20 });
    } else if (clean.includes("再亮一点") || clean.includes("亮一点") || clean.includes("调亮一点")) {
      ops.push({ kind: "brightnessStep", delta: 20 });
    } else {
      const briMatch = /(?:亮度)?(?:调到|设为)?([0-9]{1,3})%/.exec(clean);
      if (briMatch?.[1]) {
        ops.push({ kind: "brightness", percent: Number(briMatch[1]) });
      } else if (clean.includes("调暗")) {
        ops.push({ kind: "brightness", percent: 20 });
      } else if (clean.includes("调亮") || clean.includes("最亮")) {
        ops.push({ kind: "brightness", percent: 100 });
      }
    }

    if (clean.includes("调高两度") || clean.includes("升高两度")) {
      ops.push({ kind: "temperatureStep", delta: 2 });
    } else if (clean.includes("调低两度") || clean.includes("降低两度")) {
      ops.push({ kind: "temperatureStep", delta: -2 });
    } else if (clean.includes("温度高一点") || clean.includes("调高一点") || clean.includes("热一点")) {
      ops.push({ kind: "temperatureStep", delta: 1 });
    } else if (clean.includes("温度低一点") || clean.includes("调低一点") || clean.includes("凉快一点")) {
      ops.push({ kind: "temperatureStep", delta: -1 });
    } else {
      const tempMatch = /(?:调到|设为)?([1-3][0-9])(?:度|°C|℃)/i.exec(clean);
      if (tempMatch?.[1]) {
        ops.push({ kind: "targetTemperature", celsius: Number(tempMatch[1]) });
      }
    }

    if (clean.includes("制冷")) ops.push({ kind: "hvacMode", mode: "cool" });
    else if (clean.includes("制热")) ops.push({ kind: "hvacMode", mode: "heat" });
    else if (clean.includes("除湿")) ops.push({ kind: "hvacMode", mode: "dry" });
    else if (clean.includes("送风")) ops.push({ kind: "hvacMode", mode: "fan_only" });

    if (clean.includes("停止摇头") || clean.includes("关闭摇头") || clean.includes("不摇头")) {
      ops.push({ kind: "oscillation", enabled: false });
    } else if (clean.includes("摇头") || clean.includes("摆风")) {
      ops.push({ kind: "oscillation", enabled: true });
    }

    if (clean.includes("高档") || clean.includes("三档") || clean.includes("风速调高") || clean.includes("最大风")) {
      ops.push({ kind: "fanSpeed", speed: "high" });
    } else if (clean.includes("中档") || clean.includes("二档")) {
      ops.push({ kind: "fanSpeed", speed: "medium" });
    } else if (clean.includes("低档") || clean.includes("一档") || clean.includes("风速调低") || clean.includes("最小风")) {
      ops.push({ kind: "fanSpeed", speed: "low" });
    } else if (clean.includes("自动模式")) {
      ops.push({ kind: "fanSpeed", speed: "auto" });
    } else if (clean.includes("自动风") || clean.includes("自动档")) {
      ops.push({ kind: "fanSpeed", speed: "auto" });
    } else if (clean.includes("睡眠模式") || clean.includes("睡眠档") || clean.includes("静音模式") || clean.includes("静音档")) {
      ops.push({ kind: "fanSpeed", speed: "sleep" });
    } else if (clean.includes("最爱模式") || clean.includes("最爱档") || clean.includes("最爱")) {
      ops.push({ kind: "fanSpeed", speed: "favorite" });
    }

    const hasOpen = clean.includes("打开") || clean.includes("开启") || clean.startsWith("开");
    const hasClose = clean.includes("关闭") || clean.includes("关掉") || clean.startsWith("关");
    if (hasOpen && hasClose) return null;
    if (ops.length === 0) {
      if (hasOpen) ops = [{ kind: "power", isOn: true }];
      else if (hasClose) ops = [{ kind: "power", isOn: false }];
      else if (/[a-zA-Z]/.test(utterance)) return this.parseEnglish(utterance, devices, scenes);
      else return null;
    }

    const explicitDevs = devices.filter((d) => clean.includes(d.name));
    const hasAllScope = clean.includes("所有") || clean.includes("全部") || clean.includes("全屋");
    const onlyActive = ops.every(isRelativeOp);

    let candidates: SmartDevice[] = [];
    if (explicitDevs.length > 0) {
      candidates = explicitDevs;
    } else {
      const roomNames = Array.from(new Set(devices.map((d) => d.roomName)));
      const matchedRooms = roomNames.filter(
        (r) => clean.includes(r) || (r === "主卧" && clean.includes("卧室"))
      );
      const implied = impliedCategories(ops);
      const wanted = new Set<IntentCategory>();
      if (clean.includes("灯")) wanted.add("light");
      if (clean.includes("空调")) wanted.add("climate");
      if (clean.includes("净化器") || clean.includes("空净")) wanted.add("airPurifier");
      else if (clean.includes("风扇")) wanted.add("fan");
      if (clean.includes("摄像") || clean.includes("监控")) wanted.add("camera");
      const effectiveWanted = wanted.size > 0 ? wanted : implied;

      candidates = devices.filter((d) => {
        const cat = deviceCategory(d);
        if (!d.isOnline || !isAssistantControllable(cat)) return false;
        if (onlyActive && !isDeviceActiveOn(d)) return false;
        if (matchedRooms.length > 0 && !matchedRooms.includes(d.roomName)) return false;
        if (effectiveWanted && !effectiveWanted.has(cat)) return false;
        return effectiveWanted !== null || hasAllScope || matchedRooms.length > 0;
      });

      if (!onlyActive && !hasAllScope && matchedRooms.length === 0 && candidates.length !== 1) {
        if (/[a-zA-Z]/.test(utterance)) return this.parseEnglish(utterance, devices, scenes);
        return null;
      }
    }

    const plan = buildPlanFromCandidates(
      candidates,
      new Set(explicitDevs.map((d) => d.id)),
      ops,
      devices,
      scenes
    );
    if (!plan && /[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes);
    }
    return plan;
  },

  parseEnglish(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan | null {
    const lower = utterance
      .toLowerCase()
      .replace(/[,!?;:'"“”‘’。，！？、]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (!lower) return null;

    for (const scene of scenes) {
      if (!scene.name) continue;
      const sName = scene.name.toLowerCase();
      if (
        lower === `activate ${sName}` ||
        lower === `run ${sName}` ||
        lower === `start ${sName}` ||
        lower === `${sName} scene`
      ) {
        const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
        return {
          intents,
          reply: IntentReply.describe(intents, devices, scenes),
          source: "local",
          suggestions: [],
        };
      }
    }

    const state = { rest: ` ${lower} ` };
    const rawOps: IntentOperation[] = extractEnglishNumericOps(state);

    const explicitIds: string[] = [];
    const sortedDevices = [...devices].sort((a, b) => b.name.length - a.name.length);
    for (const dev of sortedDevices) {
      if (!dev.name) continue;
      if (consumeEnglishPhrase(dev.name.toLowerCase(), state)) {
        if (!explicitIds.includes(dev.id)) explicitIds.push(dev.id);
      }
    }

    const roomKeySet = new Set<string>(Object.keys(EN_ROOM_ALIASES));
    for (const d of devices) {
      if (d.roomName) roomKeySet.add(d.roomName.toLowerCase());
    }
    const allRoomKeys = Array.from(roomKeySet).sort((a, b) => b.length - a.length);
    const matchedRoomKeys: string[] = [];
    for (const roomKey of allRoomKeys) {
      if (consumeEnglishPhrase(roomKey, state)) {
        matchedRoomKeys.push(roomKey);
      }
    }

    let hasScope = false;
    for (const scopeWord of EN_SCOPE_WORDS) {
      if (consumeEnglishPhrase(scopeWord, state)) {
        hasScope = true;
      }
    }

    const oscPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["stop oscillating", false], ["stop oscillation", false], ["stop swing", false],
      ["oscillation off", false], ["swing off", false],
      ["start oscillating", true], ["oscillation on", true], ["swing on", true],
      ["oscillate", true], ["oscillation", true], ["swing", true],
    ];
    for (const [p, val] of oscPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "oscillation", enabled: val });
    }

    const fanPhrases: ReadonlyArray<readonly [string, string]> = [
      ["fan speed high", "high"], ["high fan speed", "high"], ["high speed", "high"], ["max speed", "high"],
      ["fan speed medium", "medium"], ["medium fan speed", "medium"], ["medium speed", "medium"],
      ["fan speed low", "low"], ["low fan speed", "low"], ["low speed", "low"], ["min speed", "low"],
      ["fan speed auto", "auto"], ["auto fan speed", "auto"], ["auto speed", "auto"],
      ["sleep mode", "sleep"], ["favorite mode", "favorite"],
    ];
    for (const [p, val] of fanPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "fanSpeed", speed: val });
    }

    const briStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit darker", -20], ["a little darker", -20], ["a bit dimmer", -20], ["a little dimmer", -20],
      ["dimmer", -20], ["darker", -20],
      ["a bit brighter", 20], ["a little brighter", 20], ["brighter", 20],
    ];
    for (const [p, val] of briStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightnessStep", delta: val });
    }

    const tempStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit warmer", 1], ["a little warmer", 1], ["warmer", 1], ["hotter", 1],
      ["a bit cooler", -1], ["a little cooler", -1], ["cooler", -1], ["colder", -1],
    ];
    for (const [p, val] of tempStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "temperatureStep", delta: val });
    }

    const effectPhrases: ReadonlyArray<readonly [string, string]> = [
      ["moonlight mode", "Night"], ["moonlight", "Night"],
      ["night light mode", "Night"], ["night light", "Night"], ["night mode", "Night"],
      ["daylight mode", "Day"], ["daylight", "Day"], ["day mode", "Day"],
    ];
    for (const [p, val] of effectPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "lightEffect", effect: val });
    }

    const briPhrases: ReadonlyArray<readonly [string, number]> = [
      ["minimum brightness", 10], ["dimmest", 10], ["dim", 20],
      ["maximum brightness", 100], ["max brightness", 100], ["full brightness", 100], ["brightest", 100],
    ];
    for (const [p, val] of briPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightness", percent: val });
    }

    const ctPhrases: ReadonlyArray<readonly [string, number]> = [
      ["warm light", 2700], ["warm white", 2700], ["yellow light", 2700],
      ["natural light", 4000], ["neutral white", 4000],
      ["white light", 6500], ["cool white", 6500], ["cold light", 6500],
    ];
    for (const [p, val] of ctPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "colorTemperature", kelvin: val });
    }

    const hvacPhrases: ReadonlyArray<readonly [string, string]> = [
      ["cooling mode", "cool"], ["cool mode", "cool"], ["cooling", "cool"], ["cool", "cool"],
      ["heating mode", "heat"], ["heat mode", "heat"], ["heating", "heat"], ["heat", "heat"],
      ["dry mode", "dry"], ["dehumidify", "dry"],
      ["fan only mode", "fan_only"], ["fan only", "fan_only"], ["fan mode", "fan_only"],
      ["auto mode", "auto"],
    ];
    for (const [p, val] of hvacPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "hvacMode", mode: val });
    }

    const powerPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["turn on", true], ["switch on", true], ["power on", true], ["enable", true], ["open", true],
      ["turn off", false], ["switch off", false], ["power off", false], ["shut off", false], ["disable", false], ["close", false],
      ["off", false], ["on", true],
    ];
    for (const [p, val] of powerPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "power", isOn: val });
    }

    const categories = new Set<IntentCategory>();
    for (const [phrase, cat] of EN_CATEGORY_WORDS) {
      if (consumeEnglishPhrase(phrase, state)) {
        categories.add(cat);
      }
    }

    for (const filler of EN_FILLERS) {
      consumeEnglishPhrase(filler, state);
    }

    if (state.rest.replaceAll(CONSUMED_MARKER, "").trim().length > 0) {
      return null;
    }

    const ops = reconcileOps(rawOps);
    if (!ops) return null;

    const roomDeviceIds = new Set<string>();
    for (const key of matchedRoomKeys) {
      const aliases = EN_ROOM_ALIASES[key] ?? [key];
      for (const dev of devices) {
        const rLower = dev.roomName.toLowerCase();
        if (aliases.some((a) => rLower === a.toLowerCase() || rLower.includes(a.toLowerCase()))) {
          roomDeviceIds.add(dev.id);
        }
      }
    }

    const isTurningOff = ops.length === 1 && ops[0]?.kind === "power" && !ops[0].isOn;
    const mustAcceptIds = new Set<string>(explicitIds);
    let candidates: SmartDevice[] = [];

    if (explicitIds.length > 0) {
      const devById = new Map(devices.map((d) => [d.id, d]));
      candidates = explicitIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined);
    } else {
      const implied = impliedCategories(ops);
      const wanted = categories.size > 0 ? categories : implied;
      if (wanted === null && !isTurningOff) return null;
      if (!hasScope && matchedRoomKeys.length === 0 && wanted === null) return null;

      const onlyActive = ops.every(isRelativeOp);
      candidates = devices.filter((dev) => {
        const cat = deviceCategory(dev);
        if (!dev.isOnline || !isAssistantControllable(cat)) return false;
        if (onlyActive && !isDeviceActiveOn(dev)) return false;
        if (matchedRoomKeys.length > 0 && !roomDeviceIds.has(dev.id)) return false;
        if (wanted && !wanted.has(cat)) return false;
        return true;
      });
      if (!onlyActive && !hasScope && matchedRoomKeys.length === 0 && candidates.length !== 1) {
        return null;
      }
    }

    return buildPlanFromCandidates(candidates, mustAcceptIds, ops, devices, scenes);
  },
};

// MARK: - When AI actions may run by themselves (#21)

function readProbability(raw: unknown): number | null {
  let value: number | null = null;
  if (typeof raw === "number") {
    value = raw;
  } else if (typeof raw === "string" && raw.trim() !== "") {
    const text = raw.trim();
    value = text.endsWith("%") ? Number(text.slice(0, -1).trim()) / 100 : Number(text);
  }
  if (value === null || !Number.isFinite(value)) return null;
  if (value > 1) value /= 100;
  return Math.min(Math.max(value, 0), 1);
}

/** Mirrors MijiaCore.ModelActionPolicy: guesses below 80% and risky actions wait for a tap. */
export const ModelActionPolicy = {
  AUTO_RUN_THRESHOLD: 0.8,
  SUGGESTION_FLOOR: 0.2,

  /** probabilities[choice], else confidence, else 0 — a missing number means "not sure". */
  probabilityOf(answer: Record<string, unknown> | undefined, choice: string): number {
    if (!answer) return 0;
    const probs = answer["probabilities"];
    if (probs && typeof probs === "object") {
      const value = readProbability((probs as Record<string, unknown>)[choice]);
      if (value !== null) return value;
    }
    return readProbability(answer["confidence"]) ?? 0;
  },

  /** Heater on, any plug switch, or a vacuum start needs a tap even when the model is sure. */
  needsConfirmation(intent: DeviceIntent, devices: readonly SmartDevice[]): boolean {
    const dev = devices.find((d) => d.id === intent.targetId);
    if (!dev) return false;
    const op = intent.operation;
    switch (deviceCategory(dev)) {
      case "heater":
        if (op.kind === "power") return op.isOn;
        if (op.kind === "hvacMode") return op.mode !== "off";
        return true;
      case "plug":
      case "camera":
        return op.kind === "power";
      case "vacuum":
        return op.kind === "power" && op.isOn;
      default:
        return false;
    }
  },

  partition(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[]
  ): { run: DeviceIntent[]; confirm: DeviceIntent[] } {
    const run: DeviceIntent[] = [];
    const confirm: DeviceIntent[] = [];
    for (const intent of intents) {
      (this.needsConfirmation(intent, devices) ? confirm : run).push(intent);
    }
    return { run, confirm };
  },

  /** One chip per device, or one chip for the whole group when `grouped`. */
  chips(
    intents: readonly DeviceIntent[],
    probability: number | null,
    idPrefix: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    grouped = false
  ): AssistantSuggestion[] {
    if (intents.length === 0) return [];
    const percent = probability !== null && probability > 0 ? Math.max(20, Math.min(99, Math.round(probability * 100))) : null;
    const title = (group: readonly DeviceIntent[]) => IntentReply.describe(group, devices, scenes).replace(/^已/, "");
    if (grouped) {
      return [{ id: idPrefix, title: title(intents), confidencePercent: percent, intents: [...intents] }];
    }
    const byTarget = new Map<string, DeviceIntent[]>();
    for (const intent of intents) {
      byTarget.set(intent.targetId, [...(byTarget.get(intent.targetId) ?? []), intent]);
    }
    return [...byTarget.entries()].map(([targetId, group]) => ({
      id: `${idPrefix}:${targetId}`,
      title: title(group),
      confidencePercent: percent,
      intents: group,
    }));
  },

  confirmationReply(ranReply: string | null): string {
    if (!ranReply) return "没把握直接执行，点下面的建议再执行";
    return `${ranReply}；下面的建议要点一下才执行`;
  },
};

// MARK: - Jev /v1/systemone & /v1/chat/completions Resolver

export interface AssistantProviderPresetInfo {
  readonly id: string;
  readonly title: string;
  readonly shortTitle: string;
  readonly defaultBaseURL: string;
  readonly defaultModel: string;
  readonly keyPlaceholder: string;
}

export const ASSISTANT_PROVIDER_PRESETS: ReadonlyArray<AssistantProviderPresetInfo> = [
  {
    id: "openrouter_jev",
    title: "OpenRouter · Jev (默认)",
    shortTitle: "OpenRouter",
    defaultBaseURL: "https://openrouter.ai/api/v1",
    defaultModel: "~typesafe/jev-latest",
    keyPlaceholder: "sk-or-v1-...",
  },
  {
    id: "native_jev",
    title: "TypeSafe · 原生 Jev",
    shortTitle: "原生 Jev",
    defaultBaseURL: "https://api.typesafe.ai/v1",
    defaultModel: "jev-latest",
    keyPlaceholder: "粘贴 TypeSafe 原生 Jev API Key",
  },
  {
    id: "deepseek",
    title: "DeepSeek 官方",
    shortTitle: "DeepSeek",
    defaultBaseURL: "https://api.deepseek.com/v1",
    defaultModel: "deepseek-chat",
    keyPlaceholder: "粘贴 DeepSeek API Key (sk-...)",
  },
  {
    id: "siliconflow",
    title: "硅基流动 SiliconFlow",
    shortTitle: "硅基流动",
    defaultBaseURL: "https://api.siliconflow.cn/v1",
    defaultModel: "deepseek-ai/DeepSeek-V3",
    keyPlaceholder: "粘贴硅基流动 API Key (sk-...)",
  },
  {
    id: "dashscope",
    title: "通义千问 / 阿里云百炼",
    shortTitle: "通义千问",
    defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    defaultModel: "qwen-plus",
    keyPlaceholder: "粘贴百炼 DashScope API Key (sk-...)",
  },
  {
    id: "zhipu_glm",
    title: "智谱 GLM (BigModel)",
    shortTitle: "智谱 GLM",
    defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
    defaultModel: "glm-4-flash",
    keyPlaceholder: "粘贴智谱开放平台 API Key",
  },
  {
    id: "moonshot_kimi",
    title: "Moonshot Kimi (月之暗面)",
    shortTitle: "Kimi",
    defaultBaseURL: "https://api.moonshot.cn/v1",
    defaultModel: "kimi-k2-0711-preview",
    keyPlaceholder: "粘贴 Moonshot Kimi API Key (sk-...)",
  },
  {
    id: "openai",
    title: "OpenAI",
    shortTitle: "OpenAI",
    defaultBaseURL: "https://api.openai.com/v1",
    defaultModel: "gpt-4o-mini",
    keyPlaceholder: "粘贴 OpenAI API Key (sk-...)",
  },
  {
    id: "gemini",
    title: "Google Gemini",
    shortTitle: "Gemini",
    defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
    defaultModel: "gemini-2.5-flash",
    keyPlaceholder: "粘贴 Google Gemini API Key (AIza...)",
  },
  {
    id: "groq",
    title: "Groq",
    shortTitle: "Groq",
    defaultBaseURL: "https://api.groq.com/openai/v1",
    defaultModel: "llama-3.3-70b-versatile",
    keyPlaceholder: "粘贴 Groq API Key (gsk_...)",
  },
  {
    id: "ollama",
    title: "Ollama 本地模型",
    shortTitle: "Ollama",
    defaultBaseURL: "http://localhost:11434/v1",
    defaultModel: "qwen2.5:7b",
    keyPlaceholder: "Ollama 本地接口免密（可留空）",
  },
  {
    id: "custom",
    title: "自定义兼容接口",
    shortTitle: "自定义",
    defaultBaseURL: "",
    defaultModel: "",
    keyPlaceholder: "粘贴 API Key (本机接口可留空)",
  },
];

export interface AssistantEndpoint {
  readonly scheme: "http" | "https";
  /** Lowercased host without IPv6 brackets or a trailing dot. */
  readonly host: string;
  readonly port: number | null;
}

/** Parses a user-typed endpoint. A missing scheme means https (`api.deepseek.com/v1`). Mirrors macOS `AssistantEndpoint`. */
export function parseAssistantEndpoint(raw: string): AssistantEndpoint | null {
  let text = raw.trim();
  if (!text) return null;
  if (!text.includes("://")) text = `https://${text}`;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  const scheme = url.protocol.replace(/:$/, "").toLowerCase();
  if (scheme !== "http" && scheme !== "https") return null;
  let host = url.hostname.toLowerCase();
  if (host.startsWith("[") && host.endsWith("]")) host = host.slice(1, -1);
  host = host.replace(/\.+$/, "");
  if (!host) return null;
  return { scheme, host, port: url.port ? Number(url.port) : null };
}

/** `domain` itself or one of its subdomains: `api.openrouter.ai` matches, `openrouter.ai.evil.com` does not. */
export function endpointHostMatches(endpoint: AssistantEndpoint, domain: string): boolean {
  return endpoint.host === domain || endpoint.host.endsWith(`.${domain}`);
}

/** Four dotted decimal octets, or null when `host` is not an IPv4 literal (so `10.evil.com` is not a LAN address). */
export function ipv4Octets(host: string): number[] | null {
  const parts = host.split(".");
  if (parts.length !== 4) return null;
  const octets: number[] = [];
  for (const part of parts) {
    if (!/^[0-9]{1,3}$/.test(part)) return null;
    const value = Number(part);
    if (value > 255) return null;
    octets.push(value);
  }
  return octets;
}

/** Loopback, private LAN, link-local, CGNAT/Tailscale, IPv6 ULA/link-local, or mDNS `.local` names. */
export function isLocalNetworkEndpoint(endpoint: AssistantEndpoint): boolean {
  const host = endpoint.host;
  if (host === "localhost" || host === "::1" || host.endsWith(".local")) return true;
  const octets = ipv4Octets(host);
  if (octets) {
    const [a, b] = octets as [number, number, number, number];
    return (
      a === 127 ||
      a === 10 ||
      (a === 192 && b === 168) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 100 && b >= 64 && b <= 127)
    );
  }
  if (host.includes(":")) {
    return /^(fc|fd|fe[89ab])/.test(host);
  }
  return false;
}

/** API keys only travel over https, or over plain http that stays on the local network. */
export function endpointAllowsSendingSecrets(baseURL: string): boolean {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return false;
  return endpoint.scheme === "https" || isLocalNetworkEndpoint(endpoint);
}

/** True when the endpoint may run without an API key (this computer or the local network). */
export function isLocalAssistantEndpoint(baseURL: string): boolean {
  const endpoint = parseAssistantEndpoint(baseURL);
  return endpoint ? isLocalNetworkEndpoint(endpoint) : false;
}

/** Host plus explicit port; a saved key is bound to this value. */
export function assistantEndpointIdentity(baseURL: string): string | null {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return null;
  if (endpoint.port === null) return endpoint.host;
  return endpoint.host.includes(":") ? `[${endpoint.host}]:${endpoint.port}` : `${endpoint.host}:${endpoint.port}`;
}

function presetById(id: string): AssistantProviderPresetInfo {
  return ASSISTANT_PROVIDER_PRESETS.find((p) => p.id === id) ?? ASSISTANT_PROVIDER_PRESETS[ASSISTANT_PROVIDER_PRESETS.length - 1]!;
}

/**
 * Maps an endpoint to its provider by exact host (or a subdomain of a provider-owned domain).
 * Substring checks would also match `openrouter.ai.evil.com`. Shared cases: Tests/Fixtures/provider_golden.json.
 */
export function inferAssistantPreset(baseURL: string): AssistantProviderPresetInfo {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return presetById("custom");
  const host = endpoint.host;
  const is = (domain: string) => endpointHostMatches(endpoint, domain);
  if (is("openrouter.ai")) return presetById("openrouter_jev");
  if (is("typesafe.ai")) return presetById("native_jev");
  if (is("deepseek.com")) return presetById("deepseek");
  if (is("siliconflow.cn")) return presetById("siliconflow");
  // aliyuncs.com and googleapis.com also serve customer-owned buckets, so only the API hosts count.
  if (host === "dashscope.aliyuncs.com" || host === "dashscope-intl.aliyuncs.com") return presetById("dashscope");
  if (is("bigmodel.cn")) return presetById("zhipu_glm");
  if (is("moonshot.cn") || is("moonshot.ai")) return presetById("moonshot_kimi");
  if (is("openai.com")) return presetById("openai");
  if (host === "generativelanguage.googleapis.com") return presetById("gemini");
  if (is("groq.com")) return presetById("groq");
  if (endpoint.port === 11434 && isLocalNetworkEndpoint(endpoint)) return presetById("ollama");
  return presetById("custom");
}

export interface AssistantConfig {
  readonly baseURL: string;
  readonly model: string;
  readonly apiKey: string;
}

export const DEFAULT_ASSISTANT_CONFIG: AssistantConfig = {
  baseURL: "https://openrouter.ai/api/v1",
  model: "~typesafe/jev-latest",
  apiKey: "",
};

/** Shown when a plain-http public endpoint would receive the API key and the user's words unencrypted (#19). */
export const INSECURE_ENDPOINT_MESSAGE =
  "AI 服务地址不是 https。为保护 API Key，只有本机或局域网地址可以用 http。";

// MARK: - Ambient Context & Jev SystemOne Request (#38)

/**
 * Ambient context sent with Jev `/v1/systemone` requests. Field names and empty-value
 * semantics match macOS `AssistantContext` (Sources/MijiaCore/UserHabitMemory.swift),
 * so both ends send the same `state` keys for the same home (#38).
 */
export interface AssistantContext {
  readonly timeSummary: string;
  readonly environmentSummary: string;
  readonly activeDevicesSummary: string;
  readonly habitSummary: string;
}

export const EMPTY_ASSISTANT_CONTEXT: AssistantContext = {
  timeSummary: "",
  environmentSummary: "",
  activeDevicesSummary: "",
  habitSummary: "",
};

/** The part of `learnedShortcuts` the habit summary reads. */
export interface HabitPhraseSummary {
  readonly phrase: string;
  readonly reply: string;
}

/** Time-of-day buckets, identical to macOS `UserHabitMemory.TimeBucket`. */
export function timeBucketLabel(hour: number): string {
  if (hour >= 6 && hour < 11) return "清晨";
  if (hour >= 11 && hour < 14) return "午间";
  if (hour >= 14 && hour < 18) return "下午";
  if (hour >= 18 && hour < 23) return "夜晚";
  return "深夜";
}

/** `下午 15:07`, matching HomeStore.buildAssistantContext on macOS. */
export function buildTimeSummary(now: Date): string {
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  return `${timeBucketLabel(now.getHours())} ${hours}:${minutes}`;
}

/** `客厅 25.5°C 52%，卧室 23.0°C`, matching the macOS environment summary. */
export function buildEnvironmentSummary(readings: readonly EnvironmentReading[]): string {
  return readings
    .map((reading) => {
      let text = reading.roomName;
      if (reading.temperature !== null) text += ` ${reading.temperature.toFixed(1)}°C`;
      if (reading.humidity !== null) text += ` ${Math.round(reading.humidity)}%`;
      return text;
    })
    .join("，");
}

/**
 * Windows' habit memory only stores phrase → action pairs (`learnedShortcuts`), not the
 * macOS time-bucket/frequency entries. TODO-#38: replace this with a full habit summary
 * once Windows tracks per-bucket counts; the `user_habits` field name must stay aligned
 * with macOS.
 */
export function buildHabitSummary(
  enabled: boolean,
  shortcuts: readonly HabitPhraseSummary[]
): string {
  if (!enabled || shortcuts.length === 0) return "";
  const top = shortcuts.slice(0, 4).map((shortcut) => `「${shortcut.phrase}」→${shortcut.reply}`);
  return `个人口头禅：${top.join("；")}`;
}

/** Builds the ambient context macOS sends: time, indoor readings, running devices, habits. */
export function buildAssistantContext(options: {
  readonly now: Date;
  readonly readings: readonly EnvironmentReading[];
  readonly devices: readonly SmartDevice[];
  readonly habitSummary?: string;
}): AssistantContext {
  const active = options.devices
    .filter((device) => device.isOnline && isDeviceActiveOn(device))
    .map((device) => `${device.name}(${catalogStateSummary(device)})`);
  return {
    timeSummary: buildTimeSummary(options.now),
    environmentSummary: buildEnvironmentSummary(options.readings),
    activeDevicesSummary: active.length > 0 ? active.join("、") : "全屋设备均关闭",
    habitSummary: options.habitSummary ?? "",
  };
}

/** `light`/`climate`/`fan`/`airPurifier`/`plug`/`vacuum`; `null` for sensors (not assistant-controllable). */
export function assistantDeviceCategory(device: SmartDevice): string | null {
  switch (device.kind.kind) {
    case "light":
    case "climate":
    case "plug":
    case "vacuum":
    case "camera":
      return device.kind.kind;
    case "fan":
      // Same classification the local parser and the macOS catalog use (#98).
      return isAirPurifierDevice(device) ? "airPurifier" : "fan";
    case "sensor":
      return null;
  }
}

function formatTemperatureValue(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/**
 * One-line state summary inside the catalog, mirroring macOS `IntentCatalog.stateSummary`.
 * Kept byte-for-byte compatible in shape (Chinese words and separators) so a prompt built
 * on either platform means the same thing to the model.
 */
export function catalogStateSummary(device: SmartDevice): string {
  if (!device.isOnline) return "离线";
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      const effects = kind.availableEffects.length > 0 ? ` 可用模式:${kind.availableEffects.join("/")}` : "";
      if (!kind.isOn) return `关${effects}`;
      let text = "开";
      if (kind.brightnessPercent !== null) text += ` 亮度${kind.brightnessPercent}%`;
      if (kind.currentEffect) text += ` 当前:${kind.currentEffect}`;
      return text + effects;
    }
    case "climate": {
      const modes = kind.availableModes.join("/");
      const range = `${formatTemperatureValue(kind.minTemp)}-${formatTemperatureValue(kind.maxTemp)}°C`;
      const current = kind.isOn && kind.hvacMode !== "off"
        ? `${kind.hvacMode} ${formatTemperatureValue(kind.targetTemperature)}°C`
        : "关";
      const fan = kind.availableFanModes.length > 0 ? ` 可选风速:${kind.availableFanModes.join("/")}` : "";
      return `${current} 可用模式:${modes} 温度范围:${range}${fan}`;
    }
    case "fan": {
      let text = kind.isOn ? "开" : "关";
      if (kind.isOn && kind.presetMode) text += ` 风速:${kind.presetMode}`;
      if (kind.availablePresetModes.length > 0) text += ` 可选风速:${kind.availablePresetModes.join("/")}`;
      if (kind.isOscillating !== null) text += ` 摇头:${kind.isOscillating ? "开" : "关"}`;
      return text;
    }
    case "plug":
      return kind.isOn ? "开" : "关";
    case "vacuum":
      // macOS VacuumSpec.isCleaning treats both "cleaning" and "on" as 清扫中 (#38).
      return kind.status === "cleaning" || kind.status === "on" ? "清扫中" : "待机";
    case "camera":
      return kind.isOn ? "开" : "关";
    case "sensor":
      return "";
  }
}

export interface IntentCatalog {
  /** Two-section prompt text: controllable devices then scenes, exactly like macOS. */
  readonly text: string;
  readonly aliasDevices: ReadonlyArray<{ readonly alias: string; readonly device: SmartDevice }>;
  readonly criteriaByAlias: Readonly<Record<string, string>>;
  readonly aliasToIds: ReadonlyMap<string, readonly string[]>;
}

/**
 * Short aliases for controllable devices (d1…dN, never truncated) plus scene aliases and
 * the room/all-light/whole-home shortcuts macOS offers the model (#33 / #38).
 */
export function buildIntentCatalog(
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentCatalog {
  const lines: string[] = [];
  const sceneLines: string[] = [];
  const aliasDevices: Array<{ alias: string; device: SmartDevice }> = [];
  const aliasToIds = new Map<string, string[]>();
  const criteriaByAlias: Record<string, string> = {};
  const allLightIds: string[] = [];
  const allDeviceIds: string[] = [];
  const roomLights = new Map<string, string[]>();

  for (const device of devices) {
    const category = assistantDeviceCategory(device);
    if (category === null) continue;
    const alias = `d${aliasDevices.length + 1}`;
    const summary = catalogStateSummary(device);
    aliasDevices.push({ alias, device });
    aliasToIds.set(alias, [device.id]);
    aliasToIds.set(device.id, [device.id]);
    if (!aliasToIds.has(device.name)) aliasToIds.set(device.name, [device.id]);
    criteriaByAlias[alias] = `${device.name} (${device.roomName}, ${category}, ${summary})`;
    lines.push([alias, device.name, device.roomName, category, summary].join("|"));
    allDeviceIds.push(device.id);
    if (category === "light") {
      allLightIds.push(device.id);
      if (device.roomName) {
        const ids = roomLights.get(device.roomName) ?? [];
        ids.push(device.id);
        roomLights.set(device.roomName, ids);
      }
    }
  }

  for (const [room, ids] of roomLights.entries()) {
    if (ids.length < 2) continue;
    const alias = `room_lights:${room}`;
    aliasToIds.set(alias, ids);
    criteriaByAlias[alias] = `${room}所有灯具 (${ids.length}盏)`;
  }
  if (allLightIds.length >= 2) {
    aliasToIds.set("all_lights", allLightIds);
    criteriaByAlias["all_lights"] = `全屋所有灯具 (${allLightIds.length}盏)`;
  }
  if (allDeviceIds.length >= 2) {
    aliasToIds.set("all_devices", allDeviceIds);
    criteriaByAlias["all_devices"] = `全屋所有可控设备 (${allDeviceIds.length}台)`;
  }

  scenes.forEach((scene, index) => {
    const alias = `s${index + 1}`;
    aliasToIds.set(alias, [scene.id]);
    aliasToIds.set(scene.id, [scene.id]);
    if (!aliasToIds.has(scene.name)) aliasToIds.set(scene.name, [scene.id]);
    criteriaByAlias[alias] = `场景：${scene.name}`;
    sceneLines.push(`${alias}|${scene.name}`);
  });

  let text = "设备(id|名称|房间|类型|当前状态):\n" + lines.join("\n");
  if (sceneLines.length > 0) {
    text += "\n场景(id|名称):\n" + sceneLines.join("\n");
  }

  return { text, aliasDevices, criteriaByAlias, aliasToIds };
}

/** Operations offered to the model, matching macOS `opCriteria` (#38). */
export function systemOneOpCriteria(): Record<string, string> {
  return {
    power_on: "打开设备电源",
    power_off: "关闭设备电源",
    effect_night: "切换月光/夜灯模式 (Night)",
    effect_day: "切换日光模式 (Day)",
    bri_20: "调暗灯光 (亮度 20%)",
    bri_50: "中等亮度 (亮度 50%)",
    bri_100: "调亮/最亮灯光 (亮度 100%)",
    bri_down_20: "相对调暗一点 (-20%)",
    bri_up_20: "相对调亮一点 (+20%)",
    ct_2700: "暖光/黄光 (色温 2700K)",
    ct_4000: "自然光 (色温 4000K)",
    ct_6500: "白光/冷光 (色温 6500K)",
    hvac_cool: "空调制冷模式",
    hvac_heat: "空调制热模式",
    hvac_dry: "空调除湿模式",
    hvac_fan: "空调送风模式",
    hvac_auto: "空调自动模式",
    temp: "仅调节空调温度",
    temp_up_2: "空调温度相对调高 2°C",
    temp_down_2: "空调温度相对调低 2°C",
    fan_low: "风速调为低档/一档",
    fan_medium: "风速调为中档/二档",
    fan_high: "风速调为高档/三档",
    fan_auto: "风速调为自动档",
    osc_on: "开启风扇摇头/摆风",
    osc_off: "停止风扇摇头/摆风",
    scene: "执行智能场景",
  };
}

export function systemOneTempCriteria(): Record<string, string> {
  const criteria: Record<string, string> = { none: "不指定具体温度" };
  for (let celsius = 18; celsius <= 28; celsius += 1) {
    criteria[String(celsius)] = `${celsius}°C`;
  }
  return criteria;
}

/** Per-device decision head choices, mirroring macOS `deviceSpecificCriteria` (#38). */
export function deviceSpecificCriteria(device: SmartDevice): Record<string, string> {
  const criteria: Record<string, string> = {
    none: `保持不变，不操作${device.name}`,
    power_on: `打开${device.name}`,
    power_off: `关闭${device.name}`,
  };
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "day")) {
        criteria["effect_day"] = "切换为日光模式（专注照明）";
      }
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "night")) {
        criteria["effect_night"] = "切换为月光/夜灯模式（柔和助眠）";
      }
      criteria["bri_20"] = "调暗灯光 (20%)";
      criteria["bri_100"] = "调亮灯光 (100%)";
      if (kind.isOn) {
        criteria["bri_down_20"] = "再暗一点 (-20%)";
        criteria["bri_up_20"] = "再亮一点 (+20%)";
      }
      break;
    }
    case "climate": {
      if (kind.availableModes.includes("cool")) {
        criteria["cool_24"] = "开启制冷 24°C（快速降温）";
        criteria["cool_25"] = "开启制冷 25°C";
        criteria["cool_26"] = "开启制冷 26°C（舒适恒温）";
      }
      if (kind.availableModes.includes("heat")) {
        criteria["heat_22"] = "开启制热 22°C";
        criteria["heat_24"] = "开启制热 24°C";
      }
      if (kind.availableModes.includes("dry")) {
        criteria["hvac_dry"] = "开启除湿模式";
      }
      if (kind.isOn) {
        criteria["temp_up_2"] = "温度相对调高 2°C";
        criteria["temp_down_2"] = "温度相对调低 2°C";
      }
      break;
    }
    case "fan": {
      if (kind.availablePresetModes.length > 0) {
        criteria["fan_low"] = "风速调为低档";
        criteria["fan_medium"] = "风速调为中档";
        criteria["fan_high"] = "风速调为高档";
      }
      criteria["osc_on"] = "开启摇头";
      criteria["osc_off"] = "停止摇头";
      break;
    }
    case "plug":
    case "vacuum":
    case "camera":
    case "sensor":
      break;
  }
  return criteria;
}

export interface SystemOneRequest {
  readonly body: {
    readonly model: string;
    readonly state: Record<string, unknown>;
    readonly questions: Record<string, unknown>;
  };
  readonly catalog: IntentCatalog;
}

/**
 * Builds the Jev `/v1/systemone` body with the same keys and per-device heads as macOS
 * `ModelIntentResolver.makeSystemOneRequest` (#38). Shared fixture:
 * Tests/Fixtures/ai_request_golden.json.
 */
export function buildSystemOneRequestBody(options: {
  readonly model: string;
  readonly utterance: string;
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly context?: AssistantContext;
}): SystemOneRequest {
  const catalog = buildIntentCatalog(options.devices, options.scenes);
  const context = options.context ?? EMPTY_ASSISTANT_CONTEXT;

  const targetCriteria: Record<string, string> = { ...catalog.criteriaByAlias, none: "无匹配设备或场景" };
  const questions: Record<string, unknown> = {
    target: {
      type: "choice",
      instructions: "Select the primary target device, room light group, or scene id for the command",
      criteria: targetCriteria,
    },
    op: {
      type: "choice",
      instructions: "Select the primary operation to perform on the target",
      criteria: systemOneOpCriteria(),
    },
    temp: {
      type: "choice",
      instructions: "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
      criteria: systemOneTempCriteria(),
    },
  };

  for (const { alias, device } of catalog.aliasDevices) {
    questions[`dev_${alias}`] = {
      type: "choice",
      instructions:
        `What action should be taken on ${device.name} (room: ${device.roomName}) for this command? ` +
        "Choose none if unrelated.",
      criteria: deviceSpecificCriteria(device),
    };
  }

  const state: Record<string, unknown> = {
    catalog: catalog.text,
    command: options.utterance,
  };
  if (context.timeSummary) state["time"] = context.timeSummary;
  if (context.environmentSummary) state["environment"] = context.environmentSummary;
  if (context.activeDevicesSummary) state["active_devices"] = context.activeDevicesSummary;
  if (context.habitSummary) state["user_habits"] = context.habitSummary;

  return {
    body: { model: options.model, state, questions },
    catalog,
  };
}

export class ModelIntentResolver {
  private readonly config: AssistantConfig;
  private readonly transport: HttpTransport;

  constructor(config: AssistantConfig, transport: HttpTransport) {
    this.config = config;
    this.transport = transport;
  }

  static isSystemOneModel(model: string): boolean {
    const lower = model.trim().toLowerCase();
    if (lower.includes("jev-router")) return false;
    return lower.includes("jev") || lower.includes("clef") || lower.includes("decision");
  }

  static extractFirstJSONObject(text: string): string | null {
    const start = text.indexOf("{");
    if (start < 0) return null;
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i]!;
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === "\\") {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
      } else if (ch === "{") {
        depth += 1;
      } else if (ch === "}") {
        depth -= 1;
        if (depth === 0) {
          return text.slice(start, i + 1);
        }
      }
    }
    return null;
  }

  get usesSystemOne(): boolean {
    return ModelIntentResolver.isSystemOneModel(this.config.model);
  }

  async resolve(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext = EMPTY_ASSISTANT_CONTEXT
  ): Promise<IntentPlan> {
    if (this.usesSystemOne) {
      return this.resolveViaSystemOne(utterance, devices, scenes, context);
    }
    return this.resolveViaChatCompletions(utterance, devices, scenes);
  }

  private endpointURL(path: string): string {
    let base = this.config.baseURL.trim().replace(/\/+$/, "");
    for (const suffix of ["/chat/completions", "/systemone"]) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.slice(0, -suffix.length).replace(/\/+$/, "");
      }
    }
    if (base && !base.includes("://")) base = `https://${base}`;
    const endpoint = parseAssistantEndpoint(base);
    if (!endpoint) {
      throw new Error(`AI 服务地址无效：${this.config.baseURL}`);
    }
    if (!endpointAllowsSendingSecrets(base)) {
      throw new Error(INSECURE_ENDPOINT_MESSAGE);
    }
    const pathname = new URL(base).pathname.replace(/\/+$/, "");
    if (endpointHostMatches(endpoint, "openrouter.ai")) {
      if (pathname === "") base += "/api/v1";
      else if (pathname === "/api") base += "/v1";
    } else if (pathname === "") {
      base += "/v1";
    }
    return `${base}${path}`;
  }

  private resolvedSystemOneModel(url: string): string {
    const trimmed = this.config.model.trim();
    const lower = trimmed.toLowerCase();
    const endpoint = parseAssistantEndpoint(url);
    if (endpoint && endpointHostMatches(endpoint, "openrouter.ai")) {
      if (lower.includes("jev") && !trimmed.startsWith("~")) {
        return lower.startsWith("typesafe/") ? `~${trimmed}` : `~typesafe/${trimmed}`;
      }
      return trimmed;
    }
    if (lower.startsWith("~typesafe/")) {
      return trimmed.slice("~typesafe/".length);
    }
    if (lower.startsWith("typesafe/")) {
      return trimmed.slice("typesafe/".length);
    }
    return trimmed || "jev-latest";
  }

  private effectiveAPIKey(): string {
    let key = this.config.apiKey.trim();
    if (key.toLowerCase().startsWith("bearer ")) {
      key = key.slice("bearer ".length).trim();
    }
    return key || "local";
  }

  private async resolveViaSystemOne(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext
  ): Promise<IntentPlan> {
    const url = this.endpointURL("/systemone");
    const model = this.resolvedSystemOneModel(url);
    const request = buildSystemOneRequestBody({ model, utterance, devices, scenes, context });

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.effectiveAPIKey()}`,
      },
      body: JSON.stringify(request.body),
    });

    if (resp.status !== 200) {
      throw new Error(this.friendlyHttpError(resp.status));
    }

    return ModelIntentResolver.planFromSystemOne(resp.body, request.catalog.aliasToIds, devices, scenes);
  }

  static planFromSystemOne(
    bodyText: string,
    aliasToIds: ReadonlyMap<string, readonly string[]>,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan {
    const parsed = JSON.parse(bodyText) as Record<string, unknown>;
    const answers = (parsed["answers"] ?? {}) as Record<string, Record<string, unknown>>;
    const targetChoice = String(answers["target"]?.["choice"] ?? "none");
    const opChoice = String(answers["op"]?.["choice"] ?? "");
    const tempChoice = String(answers["temp"]?.["choice"] ?? "none");

    const targetIds = aliasToIds.get(targetChoice) ?? [];
    const raw: DeviceIntent[] = [];
    const primaryOp = this.decodeSystemOneOp(opChoice);
    const hasTemp = tempChoice !== "none" && Number.isFinite(Number(tempChoice));

    // Runs by itself only when every answer involved is at least 80% sure (#21).
    let confidence = ModelActionPolicy.probabilityOf(answers["target"], targetChoice);
    if (primaryOp) confidence = Math.min(confidence, ModelActionPolicy.probabilityOf(answers["op"], opChoice));
    if (hasTemp) confidence = Math.min(confidence, ModelActionPolicy.probabilityOf(answers["temp"], tempChoice));

    for (const id of targetIds) {
      if (primaryOp) raw.push({ targetId: id, operation: primaryOp });
      if (hasTemp) {
        raw.push({ targetId: id, operation: { kind: "targetTemperature", celsius: Number(tempChoice) } });
      }
    }

    const sanitized = IntentValidator.sanitize(raw, devices, scenes);
    const confident = confidence >= ModelActionPolicy.AUTO_RUN_THRESHOLD;
    const split = ModelActionPolicy.partition(sanitized, devices);
    const intents = confident ? split.run : [];
    const waiting = confident ? split.confirm : sanitized;
    // Below the auto-run threshold everything waits for a tap, including answers with no
    // probability at all (#21: 低于门槛的一律进候选胶囊, never silently dropped).
    const suggestions = ModelActionPolicy.chips(waiting, confidence, `jev:primary:${targetChoice}:${opChoice}`, devices, scenes, true);
    const described = IntentReply.describe(intents, devices, scenes);
    return {
      intents,
      reply: suggestions.length > 0
        ? ModelActionPolicy.confirmationReply(intents.length > 0 ? described : null)
        : described,
      source: "model",
      suggestions,
    };
  }

  private static decodeSystemOneOp(choice: string): IntentOperation | null {
    switch (choice) {
      case "power_on": return { kind: "power", isOn: true };
      case "power_off": return { kind: "power", isOn: false };
      case "effect_night": return { kind: "lightEffect", effect: "Night" };
      case "effect_day": return { kind: "lightEffect", effect: "Day" };
      case "bri_20": return { kind: "brightness", percent: 20 };
      case "bri_50": return { kind: "brightness", percent: 50 };
      case "bri_100": return { kind: "brightness", percent: 100 };
      case "bri_down_20": return { kind: "brightnessStep", delta: -20 };
      case "bri_up_20": return { kind: "brightnessStep", delta: 20 };
      case "ct_2700": return { kind: "colorTemperature", kelvin: 2700 };
      case "ct_4000": return { kind: "colorTemperature", kelvin: 4000 };
      case "ct_6500": return { kind: "colorTemperature", kelvin: 6500 };
      case "hvac_cool": return { kind: "hvacMode", mode: "cool" };
      case "hvac_heat": return { kind: "hvacMode", mode: "heat" };
      case "hvac_dry": return { kind: "hvacMode", mode: "dry" };
      case "hvac_fan": return { kind: "hvacMode", mode: "fan_only" };
      case "hvac_auto": return { kind: "hvacMode", mode: "auto" };
      case "temp": return null; // the temperature itself arrives through the `temp` question
      case "temp_up_2": return { kind: "temperatureStep", delta: 2 };
      case "temp_down_2": return { kind: "temperatureStep", delta: -2 };
      case "fan_low": return { kind: "fanSpeed", speed: "low" };
      case "fan_medium": return { kind: "fanSpeed", speed: "medium" };
      case "fan_high": return { kind: "fanSpeed", speed: "high" };
      case "fan_auto": return { kind: "fanSpeed", speed: "auto" };
      case "osc_on": return { kind: "oscillation", enabled: true };
      case "osc_off": return { kind: "oscillation", enabled: false };
      case "scene": return { kind: "activateScene" };
      default: return null;
    }
  }

  private async resolveViaChatCompletions(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): Promise<IntentPlan> {
    const url = this.endpointURL("/chat/completions");
    const aliasToIds = new Map<string, string[]>();
    const controllable = devices.filter((d) => d.kind.kind !== "sensor");

    const catalogLines: string[] = [];
    controllable.forEach((d, idx) => {
      const alias = `d${idx + 1}`;
      aliasToIds.set(alias, [d.id]);
      aliasToIds.set(d.id, [d.id]);
      aliasToIds.set(d.name, [d.id]);
      catalogLines.push(`${alias}|${d.name}|${d.roomName}|${d.kind.kind}`);
    });
    const sceneLines: string[] = [];
    scenes.forEach((s, idx) => {
      const alias = `s${idx + 1}`;
      aliasToIds.set(alias, [s.id]);
      aliasToIds.set(s.id, [s.id]);
      aliasToIds.set(s.name, [s.id]);
      sceneLines.push(`${alias}|${s.name}`);
    });

    const sceneSection = sceneLines.length > 0 ? `\n场景(id|名称):\n${sceneLines.join("\n")}` : "";
    const prompt = `你是智能家居指令解析器。把中文指令转为 JSON，只输出 JSON，不要解释。\n设备(id|名称|房间|类型):\n${catalogLines.join("\n")}${sceneSection}\nschema: {"actions":[{"device":"id","op":"power|brightness|brightness_step|color_temp|effect|hvac_mode|temperature|temperature_step|fan_speed|oscillation|scene","value":...}],"reply":"一句话中文回执"}`;

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.effectiveAPIKey()}`,
      },
      body: JSON.stringify({
        model: this.config.model.trim(),
        messages: [
          { role: "system", content: prompt },
          { role: "user", content: utterance },
        ],
        temperature: 0,
      }),
    });

    if (resp.status !== 200) {
      throw new Error(this.friendlyHttpError(resp.status));
    }

    const root = JSON.parse(resp.body) as Record<string, unknown>;
    const choices = (root["choices"] as Array<Record<string, Record<string, unknown>>>) ?? [];
    let content = String(choices[0]?.["message"]?.["content"] ?? "");
    const closeThinkIdx = content.toLowerCase().lastIndexOf("</think>");
    if (closeThinkIdx >= 0) {
      content = content.slice(closeThinkIdx + "</think>".length);
    }
    const jsonSlice = ModelIntentResolver.extractFirstJSONObject(content);
    if (!jsonSlice) throw new Error("AI 返回格式无法解析");
    const payload = JSON.parse(jsonSlice) as Record<string, unknown>;
    const actions = (payload["actions"] as Array<Record<string, unknown>>) ?? [];

    const raw: DeviceIntent[] = [];
    for (const act of actions) {
      const alias = String(act["device"] ?? "").trim();
      const opName = String(act["op"] ?? "").trim();
      const val = act["value"];
      const op = this.decodeChatOp(opName, val);
      const targetIds = aliasToIds.get(alias) ?? (alias ? [alias] : []);
      if (op) {
        for (const targetId of targetIds) {
          raw.push({ targetId, operation: op });
        }
      }
    }
    // Heaters, plugs and vacuums wait for a tap even when the model asks for them directly (#21).
    const { run: intents, confirm } = ModelActionPolicy.partition(IntentValidator.sanitize(raw, devices, scenes), devices);
    const suggestions = ModelActionPolicy.chips(confirm, null, "confirm", devices, scenes);
    const described = IntentReply.describe(intents, devices, scenes);
    // The model's own reply may claim the waiting actions already happened.
    const reply = suggestions.length > 0
      ? ModelActionPolicy.confirmationReply(intents.length > 0 ? described : null)
      : String(payload["reply"] ?? "").trim() || described;
    return { intents, reply, source: "model", suggestions };
  }

  private decodeChatOp(name: string, val: unknown): IntentOperation | null {
    const numVal = typeof val === "number" ? val : typeof val === "string" ? Number(val.replace(/[%°CcKk\s]/g, "")) : NaN;
    const boolVal =
      typeof val === "boolean"
        ? val
        : typeof val === "number"
          ? val !== 0
          : typeof val === "string"
            ? ["true", "on", "1", "开"].includes(val.trim().toLowerCase())
            : false;

    switch (name.toLowerCase()) {
      case "power": return { kind: "power", isOn: boolVal };
      case "brightness": return Number.isFinite(numVal) ? { kind: "brightness", percent: Math.round(numVal) } : null;
      case "brightness_step": return Number.isFinite(numVal) ? { kind: "brightnessStep", delta: Math.round(numVal) } : null;
      case "color_temp":
      case "color_temperature":
        return Number.isFinite(numVal) ? { kind: "colorTemperature", kelvin: Math.round(numVal) } : null;
      case "effect":
      case "light_effect":
        return typeof val === "string" ? { kind: "lightEffect", effect: val } : null;
      case "hvac_mode":
      case "mode":
        return typeof val === "string" ? { kind: "hvacMode", mode: val } : null;
      case "temperature":
      case "target_temperature":
        return Number.isFinite(numVal) ? { kind: "targetTemperature", celsius: numVal } : null;
      case "temperature_step":
        return Number.isFinite(numVal) ? { kind: "temperatureStep", delta: numVal } : null;
      case "fan_speed":
      case "fan_mode":
      case "preset":
        return typeof val === "string" ? { kind: "fanSpeed", speed: val } : null;
      case "oscillation":
      case "swing":
        return { kind: "oscillation", enabled: boolVal };
      case "scene":
        return { kind: "activateScene" };
      default: return null;
    }
  }

  private friendlyHttpError(status: number): string {
    if (status === 401 || status === 403) return "API Key 无效或未填写，请在设置中检查";
    if (status === 429) return "AI 调用过于频繁（触发限流），请稍后再试";
    if (status >= 500) return `AI 服务端暂时不可用 (HTTP ${status})`;
    return `AI 请求失败 (HTTP ${status})`;
  }
}
