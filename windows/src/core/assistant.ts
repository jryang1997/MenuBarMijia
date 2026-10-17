import type { HttpTransport } from "./miCloudClient.js";
import type {
  AssistantSuggestion,
  DeviceCommand,
  DeviceIntent,
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

export const DelayPhrase = {
  isCancel(utterance: string): boolean {
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    return clean === "取消定时" || clean === "取消倒计时" || clean === "取消所有定时" || clean === "清除定时";
  },

  extract(utterance: string): ParsedDelay | null {
    const trimmed = utterance.trim();
    if (/^半小时(?:以)?后(.+)$/.test(trimmed)) {
      const m = /^半小时(?:以)?后(.+)$/.exec(trimmed);
      const rem = m?.[1]?.trim() ?? "";
      if (rem) return { seconds: 1800, remainder: rem };
    }
    const regex = /^(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)(秒钟?|分钟?|小时|钟头)(?:以)?后?[，,\s]*(.+)$/;
    const front = regex.exec(trimmed);
    if (front) {
      const num = parseCnOrArabicNumber(front[1] ?? "");
      const unit = front[2] ?? "";
      const rem = (front[3] ?? "").trim();
      if (num && rem) {
        const mult = unit.startsWith("小") || unit.startsWith("钟") ? 3600 : unit.startsWith("分") ? 60 : 1;
        return { seconds: Math.min(86400, num * mult), remainder: rem };
      }
    }
    const backRegex = /^(.+?)[，,\s]*(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)(秒钟?|分钟?|小时|钟头)(?:以)?后$/;
    const back = backRegex.exec(trimmed);
    if (back) {
      const rem = (back[1] ?? "").trim();
      const num = parseCnOrArabicNumber(back[2] ?? "");
      const unit = back[3] ?? "";
      if (num && rem) {
        const mult = unit.startsWith("小") || unit.startsWith("钟") ? 3600 : unit.startsWith("分") ? 60 : 1;
        return { seconds: Math.min(86400, num * mult), remainder: rem };
      }
    }
    return null;
  },

  formatDelay(seconds: number): string {
    if (seconds % 3600 === 0) return `${seconds / 3600} 小时`;
    if (seconds % 60 === 0) return `${seconds / 60} 分钟`;
    return `${seconds} 秒`;
  },
};

export const UndoPhrase = {
  isUndo(utterance: string): boolean {
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
        if (k.kind === "light" || k.kind === "climate" || k.kind === "fan" || k.kind === "plug" || k.kind === "vacuum") {
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
        if (k.kind !== "climate") return null;
        const matched = k.availableModes.find((m) => m.toLowerCase() === op.mode.toLowerCase());
        return matched ? { kind: "hvacMode", mode: matched } : null;
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
        const ranked = list.filter((m) => !/auto|自动|sleep|睡眠/i.test(m));
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

export const LocalIntentParser = {
  parse(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan | null {
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    if (!clean) return null;

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
    } else if (clean.includes("自动风") || clean.includes("自动档")) {
      ops.push({ kind: "fanSpeed", speed: "auto" });
    }

    const hasOpen = clean.includes("打开") || clean.includes("开启") || clean.startsWith("开");
    const hasClose = clean.includes("关闭") || clean.includes("关掉") || clean.startsWith("关");
    if (hasOpen && hasClose) return null;
    if (ops.length === 0) {
      if (hasOpen) ops = [{ kind: "power", isOn: true }];
      else if (hasClose) ops = [{ kind: "power", isOn: false }];
      else return null;
    }

    const explicitDevs = devices.filter((d) => clean.includes(d.name));
    const hasAllScope = clean.includes("所有") || clean.includes("全部") || clean.includes("全屋");
    const onlyActive = ops.every(
      (o) => o.kind === "brightnessStep" || o.kind === "temperatureStep"
    );

    let candidates: SmartDevice[] = [];
    if (explicitDevs.length > 0) {
      candidates = explicitDevs;
    } else {
      const roomNames = Array.from(new Set(devices.map((d) => d.roomName)));
      const matchedRooms = roomNames.filter(
        (r) => clean.includes(r) || (r === "主卧" && clean.includes("卧室"))
      );
      const wantsLight =
        clean.includes("灯") ||
        ops.some(
          (o) =>
            o.kind === "brightness" ||
            o.kind === "brightnessStep" ||
            o.kind === "colorTemperature" ||
            o.kind === "lightEffect"
        );
      const wantsAC =
        clean.includes("空调") ||
        ops.some(
          (o) =>
            o.kind === "hvacMode" ||
            o.kind === "targetTemperature" ||
            o.kind === "temperatureStep"
        );
      const wantsFan =
        clean.includes("风扇") || ops.some((o) => o.kind === "oscillation");

      candidates = devices.filter((d) => {
        if (!d.isOnline) return false;
        if (onlyActive && !isDeviceActiveOn(d)) return false;
        if (matchedRooms.length > 0 && !matchedRooms.includes(d.roomName)) return false;
        if (wantsLight) return d.kind.kind === "light";
        if (wantsAC) return d.kind.kind === "climate" && !d.name.includes("暖");
        if (wantsFan) return d.kind.kind === "fan";
        return false;
      });

      if (!onlyActive && !hasAllScope && matchedRooms.length === 0 && candidates.length !== 1) {
        return null;
      }
    }

    const intents: DeviceIntent[] = [];
    for (const dev of candidates) {
      const normOps = ops
        .map((o) => IntentValidator.normalize(o, dev))
        .filter((o): o is IntentOperation => o !== null);
      if (normOps.length !== ops.length) {
        if (explicitDevs.some((e) => e.id === dev.id)) return null;
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
  },
};

// MARK: - Jev /v1/systemone & /v1/chat/completions Resolver

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

export class ModelIntentResolver {
  private readonly config: AssistantConfig;
  private readonly transport: HttpTransport;

  constructor(config: AssistantConfig, transport: HttpTransport) {
    this.config = config;
    this.transport = transport;
  }

  get usesSystemOne(): boolean {
    return this.config.model.toLowerCase().includes("jev");
  }

  async resolve(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): Promise<IntentPlan> {
    if (this.usesSystemOne) {
      return this.resolveViaSystemOne(utterance, devices, scenes);
    }
    return this.resolveViaChatCompletions(utterance, devices, scenes);
  }

  private async resolveViaSystemOne(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): Promise<IntentPlan> {
    const base = this.config.baseURL.replace(/\/+$/, "");
    const url = `${base}/systemone`;
    const model =
      url.includes("openrouter.ai") && !this.config.model.startsWith("~")
        ? `~${this.config.model}`
        : this.config.model;

    const targetCriteria: Record<string, string> = { none: "无匹配设备或场景" };
    const aliasToIds = new Map<string, string[]>();
    const controllable = devices.filter((d) => d.kind.kind !== "sensor");

    controllable.forEach((d, idx) => {
      const alias = `d${idx + 1}`;
      aliasToIds.set(alias, [d.id]);
      targetCriteria[alias] = `${d.name} (${d.roomName}, ${d.isOnline ? "在线" : "离线"})`;
    });

    const roomLights = new Map<string, string[]>();
    for (const d of controllable) {
      if (d.kind.kind === "light") {
        const prev = roomLights.get(d.roomName) ?? [];
        prev.push(d.id);
        roomLights.set(d.roomName, prev);
      }
    }
    for (const [room, ids] of roomLights.entries()) {
      const key = `room_lights:${room}`;
      aliasToIds.set(key, ids);
      targetCriteria[key] = `${room}的所有灯`;
    }

    scenes.forEach((s, idx) => {
      const alias = `s${idx + 1}`;
      aliasToIds.set(alias, [s.id]);
      targetCriteria[alias] = `场景：${s.name}`;
    });

    const opCriteria: Record<string, string> = {
      power_on: "打开设备电源",
      power_off: "关闭设备电源",
      effect_night: "切换月光/夜灯模式 (Night)",
      effect_day: "切换日光模式 (Day)",
      bri_20: "调暗灯光 (20%)",
      bri_50: "中等亮度 (50%)",
      bri_100: "调亮灯光 (100%)",
      bri_down_20: "相对调暗一点 (-20%)",
      bri_up_20: "相对调亮一点 (+20%)",
      ct_2700: "暖光 (2700K)",
      ct_4000: "自然光 (4000K)",
      ct_6500: "冷白光 (6500K)",
      hvac_cool: "空调制冷模式",
      hvac_heat: "空调制热模式",
      hvac_dry: "空调除湿模式",
      hvac_fan: "空调送风模式",
      hvac_auto: "空调自动模式",
      temp_up_2: "空调温度相对调高 2°C",
      temp_down_2: "空调温度相对调低 2°C",
      fan_low: "风速低档",
      fan_medium: "风速中档",
      fan_high: "风速高档",
      osc_on: "开启摇头",
      osc_off: "停止摇头",
      scene: "执行智能场景",
    };

    const tempCriteria: Record<string, string> = {
      none: "不指定具体温度",
      "18": "18°C", "20": "20°C", "22": "22°C", "24": "24°C", "25": "25°C", "26": "26°C", "27": "27°C", "28": "28°C",
    };

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.config.apiKey.trim() || "local"}`,
      },
      body: JSON.stringify({
        model,
        state: { command: utterance },
        questions: {
          target: { type: "choice", instructions: "Select primary target", criteria: targetCriteria },
          op: { type: "choice", instructions: "Select primary operation", criteria: opCriteria },
          temp: { type: "choice", instructions: "Select temperature in Celsius or none", criteria: tempCriteria },
        },
      }),
    });

    if (resp.status !== 200) {
      throw new Error(this.friendlyHttpError(resp.status));
    }

    return ModelIntentResolver.planFromSystemOne(resp.body, aliasToIds, devices, scenes);
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

    for (const id of targetIds) {
      if (primaryOp) raw.push({ targetId: id, operation: primaryOp });
      if (tempChoice !== "none" && Number.isFinite(Number(tempChoice))) {
        raw.push({ targetId: id, operation: { kind: "targetTemperature", celsius: Number(tempChoice) } });
      }
    }

    const intents = IntentValidator.sanitize(raw, devices, scenes);
    return {
      intents,
      reply: IntentReply.describe(intents, devices, scenes),
      source: "model",
      suggestions: [],
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
      case "temp_up_2": return { kind: "temperatureStep", delta: 2 };
      case "temp_down_2": return { kind: "temperatureStep", delta: -2 };
      case "fan_low": return { kind: "fanSpeed", speed: "low" };
      case "fan_medium": return { kind: "fanSpeed", speed: "medium" };
      case "fan_high": return { kind: "fanSpeed", speed: "high" };
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
    const base = this.config.baseURL.replace(/\/+$/, "");
    const url = `${base}/chat/completions`;
    const catalogLines = devices.map((d) => `- id=${d.id} 名称=${d.name} 房间=${d.roomName} 类型=${d.kind.kind}`).join("\n");
    const prompt = `你是智能家居指令解析器。把中文指令转为 JSON：{"actions":[{"device":"id","op":"power|brightness|brightness_step|color_temp|effect|hvac_mode|temperature|temperature_step|fan_speed|oscillation","value":...}],"reply":"中文回执"}\n设备列表：\n${catalogLines}`;

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.config.apiKey.trim() || "local"}`,
      },
      body: JSON.stringify({
        model: this.config.model,
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
    const content = String(choices[0]?.["message"]?.["content"] ?? "");
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start < 0 || end <= start) throw new Error("AI 返回格式无法解析");
    const payload = JSON.parse(content.slice(start, end + 1)) as Record<string, unknown>;
    const actions = (payload["actions"] as Array<Record<string, unknown>>) ?? [];

    const raw: DeviceIntent[] = [];
    for (const act of actions) {
      const targetId = String(act["device"] ?? "");
      const opName = String(act["op"] ?? "");
      const val = act["value"];
      const op = this.decodeChatOp(opName, val);
      if (targetId && op) raw.push({ targetId, operation: op });
    }
    const intents = IntentValidator.sanitize(raw, devices, scenes);
    const reply = String(payload["reply"] ?? "").trim() || IntentReply.describe(intents, devices, scenes);
    return { intents, reply, source: "model", suggestions: [] };
  }

  private decodeChatOp(name: string, val: unknown): IntentOperation | null {
    switch (name) {
      case "power": return { kind: "power", isOn: Boolean(val) };
      case "brightness": return typeof val === "number" ? { kind: "brightness", percent: val } : null;
      case "brightness_step": return typeof val === "number" ? { kind: "brightnessStep", delta: val } : null;
      case "color_temp": return typeof val === "number" ? { kind: "colorTemperature", kelvin: val } : null;
      case "effect": return typeof val === "string" ? { kind: "lightEffect", effect: val } : null;
      case "hvac_mode": return typeof val === "string" ? { kind: "hvacMode", mode: val } : null;
      case "temperature": return typeof val === "number" ? { kind: "targetTemperature", celsius: val } : null;
      case "temperature_step": return typeof val === "number" ? { kind: "temperatureStep", delta: val } : null;
      case "fan_speed": return typeof val === "string" ? { kind: "fanSpeed", speed: val } : null;
      case "oscillation": return { kind: "oscillation", enabled: Boolean(val) };
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
