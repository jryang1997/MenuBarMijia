import {
  DelayPhrase,
  IntentReply,
  IntentValidator,
  LocalIntentParser,
  ModelIntentResolver,
  UndoPhrase,
} from "../core/assistant.js";
import {
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  MiAccountLogin,
  MiCloudClient,
  MiotCommandMapper,
  type MiotDeviceSpec,
  type MiotPropKey,
  MiotSynthesizer,
  type MiSession,
  type QRLoginTicket,
  maskedMiUserId,
} from "../core/miCloudClient.js";
import {
  type DeviceCommand,
  type DeviceIntent,
  type HomeScene,
  type IntentPlan,
  type ScheduledCommand,
  type SmartDevice,
  deviceStatusSummary,
  isDeviceActiveOn,
} from "../core/models.js";

declare global {
  interface Window {
    __TAURI_INTERNALS__?: {
      invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;
    };
    webkitSpeechRecognition?: new () => SpeechRecognitionInstance;
    SpeechRecognition?: new () => SpeechRecognitionInstance;
  }
}

interface SpeechRecognitionAlternative {
  readonly transcript: string;
}

interface SpeechRecognitionResultItem {
  readonly isFinal: boolean;
  readonly 0: SpeechRecognitionAlternative;
}

interface SpeechRecognitionEventLike {
  readonly results: ArrayLike<SpeechRecognitionResultItem>;
}

interface SpeechRecognitionInstance {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
}

type ConnectionMode = "demo" | "xiaomiCloud" | "homeAssistant";

interface LearnedShortcut {
  readonly phrase: string;
  readonly reply: string;
  readonly intents: readonly DeviceIntent[];
  readonly learnedAt: string;
}

interface PersistedSettings {
  connectionMode: ConnectionMode;
  miSession: MiSession | null;
  haBaseURL: string;
  haToken: string;
  openRouterApiKey: string;
  assistantModel: string;
  habitLearningEnabled: boolean;
  learnedShortcuts: LearnedShortcut[];
  hasCompletedOnboarding: boolean;
}

interface UndoAction {
  readonly summary: string;
  readonly snapshot: SmartDevice[];
  readonly inverseCommands: DeviceCommand[];
  readonly expiresAtMs: number;
}

interface ReplyBannerState {
  readonly text: string;
  readonly source: string;
}

const STORAGE_KEY = "menumijia.windows.settings.v1";

const DEMO_DEVICES: SmartDevice[] = [
  {
    id: "light.living_ceiling",
    name: "客厅吸顶灯",
    roomId: "room_living",
    roomName: "客厅",
    model: "yeelink.light.ceiling22",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "miot:light.living_ceiling:2",
      isOn: true,
      brightnessPercent: 78,
      colorTempKelvin: 4100,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: "Day",
      availableEffects: ["Day", "Night"],
    },
  },
  {
    id: "climate.living_ac",
    name: "客厅立式空调",
    roomId: "room_living",
    roomName: "客厅",
    model: "xiaomi.aircondition.mc5",
    isOnline: true,
    kind: {
      kind: "climate",
      entityId: "miot:climate.living_ac:2",
      isOn: true,
      hvacMode: "cool",
      availableModes: ["cool", "heat", "dry", "fan_only", "auto", "off"],
      targetTemperature: 25,
      currentTemperature: 26,
      minTemp: 16,
      maxTemp: 30,
      step: 0.5,
      fanMode: "auto",
      availableFanModes: ["auto", "low", "medium", "high"],
    },
  },
  {
    id: "light.study_desk",
    name: "书房台灯",
    roomId: "room_study",
    roomName: "书房",
    model: "yeelink.light.lamp15",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "miot:light.study_desk:2",
      isOn: true,
      brightnessPercent: 64,
      colorTempKelvin: 4600,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: ["Day", "Night"],
    },
  },
  {
    id: "fan.bedroom_standing",
    name: "主卧直流风扇",
    roomId: "room_bedroom",
    roomName: "主卧",
    model: "zhimi.fan.za5",
    isOnline: true,
    kind: {
      kind: "fan",
      entityId: "miot:fan.bedroom_standing:2",
      isOn: false,
      percentage: 50,
      presetMode: "Level 2",
      availablePresetModes: ["Level 1", "Level 2", "Level 3", "Level 4"],
      isOscillating: false,
    },
  },
  {
    id: "plug.entry_socket",
    name: "玄关智能插座",
    roomId: "room_entry",
    roomName: "玄关",
    model: "cuco.plug.cp1",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: "miot:plug.entry_socket:2",
      isOn: true,
      powerWatts: 18.4,
      childLockEntityId: null,
      isChildLocked: false,
    },
  },
  {
    id: "vacuum.roborock",
    name: "全屋扫拖机器人",
    roomId: "room_living",
    roomName: "客厅",
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: "miot:vacuum.roborock:2",
      status: "docked",
      battery: 100,
      modeEntityId: null,
      currentMode: null,
      availableModes: [],
    },
  },
  {
    id: "sensor.living_env",
    name: "客厅温湿度计",
    roomId: "room_living",
    roomName: "客厅",
    model: "miaomiaoce.sensor_ht.t2",
    isOnline: true,
    kind: {
      kind: "sensor",
      temperature: 25.5,
      humidity: 52,
      battery: 94,
    },
  },
];

const DEMO_SCENES: HomeScene[] = [
  { id: "scene.home", name: "回家模式", entityId: "scene.home" },
  { id: "scene.focus", name: "专注模式", entityId: "scene.focus" },
  { id: "scene.sleep", name: "睡眠模式", entityId: "scene.sleep" },
  { id: "scene.leave", name: "离家模式", entityId: "scene.leave" },
];

const SCENE_CARDS: ReadonlyArray<{
  readonly id: string;
  readonly title: string;
  readonly subtitle: string;
  readonly icon: string;
  readonly command: string;
}> = [
  { id: "home", title: "回家", subtitle: "开主灯+空调", icon: "🏠", command: "打开客厅吸顶灯" },
  { id: "focus", title: "专注", subtitle: "书房台灯100%", icon: "💻", command: "书房台灯调亮" },
  { id: "sleep", title: "睡眠", subtitle: "全屋关灯", icon: "🌙", command: "关闭所有灯" },
  { id: "cool", title: "清凉", subtitle: "空调制冷25度", icon: "❄️", command: "空调调到25度" },
];

function createTransport(): HttpTransport {
  return async (req: HttpRequest): Promise<HttpResponse> => {
    if (window.__TAURI_INTERNALS__?.invoke) {
      return window.__TAURI_INTERNALS__.invoke<HttpResponse>("native_http", {
        url: req.url,
        method: req.method ?? "GET",
        headers: req.headers ?? {},
        body: req.body ?? null,
        followRedirects: req.followRedirects ?? true,
        timeoutMs: req.timeoutMs ?? 15000,
      });
    }
    const response = await fetch(req.url, {
      method: req.method ?? "GET",
      headers: req.headers,
      body: req.body,
    });
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    return {
      status: response.status,
      headers,
      body: await response.text(),
    };
  };
}

function loadSettings(): PersistedSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<PersistedSettings>;
      return {
        connectionMode: parsed.connectionMode ?? "demo",
        miSession: parsed.miSession ?? null,
        haBaseURL: parsed.haBaseURL ?? "",
        haToken: parsed.haToken ?? "",
        openRouterApiKey: parsed.openRouterApiKey ?? "",
        assistantModel: parsed.assistantModel ?? "~typesafe/jev-latest",
        habitLearningEnabled: parsed.habitLearningEnabled ?? true,
        learnedShortcuts: parsed.learnedShortcuts ?? [],
        hasCompletedOnboarding: parsed.hasCompletedOnboarding ?? false,
      };
    }
  } catch {
    // ignore corrupt localStorage
  }
  return {
    connectionMode: "demo",
    miSession: null,
    haBaseURL: "",
    haToken: "",
    openRouterApiKey: "",
    assistantModel: "~typesafe/jev-latest",
    habitLearningEnabled: true,
    learnedShortcuts: [],
    hasCompletedOnboarding: false,
  };
}

function saveSettings(settings: PersistedSettings): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
}

class MenuMijiaWindowsApp {
  private settings: PersistedSettings = loadSettings();
  private devices: SmartDevice[] = structuredClone(DEMO_DEVICES);
  private scenes: HomeScene[] = structuredClone(DEMO_SCENES);
  private modelSpecs: Record<string, MiotDeviceSpec> = {};
  private selectedRoom = "全部";
  private expandedDeviceId: string | null = null;
  private activeSheet: "none" | "onboarding" | "settings" = "none";
  private onboardingStep = 0;
  private replyBanner: ReplyBannerState | null = null;
  private isResolvingIntent = false;
  private isListeningVoice = false;
  private scheduledCommands: ScheduledCommand[] = [];
  private lastUndoAction: UndoAction | null = null;
  private qrTicket: QRLoginTicket | null = null;
  private qrStatusText = "点击「获取二维码」，用手机米家 App 扫一扫即可直连全屋设备。";
  private isPollingQR = false;
  private readonly transport: HttpTransport = createTransport();
  private speechRecognition: SpeechRecognitionInstance | null = null;

  constructor(private readonly root: HTMLElement) {
    if (!this.settings.hasCompletedOnboarding) {
      this.activeSheet = "onboarding";
    }
    this.startTimerLoop();
    this.render();
    if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
      void this.refreshXiaomiDevices();
    }
  }

  private startTimerLoop(): void {
    window.setInterval(() => {
      const now = Date.now();
      let changed = false;

      if (this.lastUndoAction && this.lastUndoAction.expiresAtMs <= now) {
        this.lastUndoAction = null;
        changed = true;
      }

      const due: ScheduledCommand[] = [];
      const remaining: ScheduledCommand[] = [];
      for (const item of this.scheduledCommands) {
        if (item.fireTimestampMs <= now) {
          due.push(item);
        } else {
          remaining.push(item);
        }
      }

      if (due.length > 0) {
        this.scheduledCommands = remaining;
        changed = true;
        for (const item of due) {
          void this.handleNaturalCommand(item.command, true);
        }
      } else if (this.scheduledCommands.length > 0) {
        changed = true;
      }

      if (changed) {
        this.render();
      }
    }, 1000);
  }

  private get rooms(): string[] {
    const unique = Array.from(new Set(this.devices.map((d) => d.roomName)));
    return ["全部", ...unique];
  }

  private get filteredDevices(): SmartDevice[] {
    if (this.selectedRoom === "全部") return this.devices;
    return this.devices.filter((d) => d.roomName === this.selectedRoom);
  }

  private get activeDeviceCount(): number {
    return this.devices.filter((d) => isDeviceActiveOn(d)).length;
  }

  private get averageTemperatureText(): string {
    const temps: number[] = [];
    for (const d of this.devices) {
      if (d.kind.kind === "sensor" && d.kind.temperature !== null) {
        temps.push(d.kind.temperature);
      } else if (d.kind.kind === "climate" && d.kind.currentTemperature !== null) {
        temps.push(d.kind.currentTemperature);
      }
    }
    if (temps.length === 0) return "--°C";
    const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
    return `${avg.toFixed(1)}°C`;
  }

  private async fetchSpecForModel(model: string, specType: string | null): Promise<MiotDeviceSpec | null> {
    const cached = this.modelSpecs[model];
    if (cached) return cached;
    if (!specType) return null;
    try {
      const resp = await this.transport({
        url: `https://miot-spec.org/miot-spec-v2/instance?type=${encodeURIComponent(specType)}`,
        method: "GET",
      });
      if (resp.status !== 200) return null;
      const spec = JSON.parse(resp.body) as MiotDeviceSpec;
      if (spec && Array.isArray(spec.services)) {
        this.modelSpecs[model] = spec;
        return spec;
      }
    } catch {
      // ignore spec lookup failure
    }
    return null;
  }

  private async refreshXiaomiDevices(): Promise<void> {
    if (!this.settings.miSession) return;
    try {
      const client = new MiCloudClient(this.settings.miSession, this.transport);
      const [rawDevices, rooms] = await Promise.all([
        client.deviceList(),
        client.homeRooms().catch(() => []),
      ]);
      const propKeys: MiotPropKey[] = [];
      for (const dev of rawDevices) {
        const spec = await this.fetchSpecForModel(dev.model, dev.specType);
        if (spec) {
          propKeys.push(...MiotSynthesizer.requiredProps(dev, spec));
        }
      }
      const values = propKeys.length > 0 ? await client.getProps(propKeys) : new Map<string, unknown>();
      const home = MiotSynthesizer.synthesize(rawDevices, rooms, this.modelSpecs, values);
      if (home.devices.length > 0) {
        this.devices = home.devices;
        this.render();
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.replyBanner = {
        text: `米家云同步失败：${msg}`,
        source: "连接提示",
      };
      this.render();
    }
  }

  private async handleNaturalCommand(rawInput: string, fromScheduled = false): Promise<void> {
    const trimmed = rawInput.trim();
    if (!trimmed) return;

    if (UndoPhrase.isUndo(trimmed)) {
      await this.performUndo();
      return;
    }

    if (DelayPhrase.isCancel(trimmed)) {
      const count = this.scheduledCommands.length;
      this.scheduledCommands = [];
      this.replyBanner = {
        text: count > 0 ? `已取消 ${count} 项定时指令` : "当前没有待执行的定时指令",
        source: "0ms 本地直达",
      };
      this.render();
      return;
    }

    if (!fromScheduled) {
      const delaySpec = DelayPhrase.extract(trimmed);
      if (delaySpec) {
        const scheduled: ScheduledCommand = {
          id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          command: delaySpec.remainder,
          delaySeconds: delaySpec.seconds,
          fireTimestampMs: Date.now() + delaySpec.seconds * 1000,
          reply: `${DelayPhrase.formatDelay(delaySpec.seconds)}后：${delaySpec.remainder}`,
        };
        this.scheduledCommands.push(scheduled);
        this.replyBanner = {
          text: `已设定 ${DelayPhrase.formatDelay(delaySpec.seconds)}后执行「${delaySpec.remainder}」`,
          source: "定时任务",
        };
        this.render();
        return;
      }
    }

    const learnedMatch = this.settings.learnedShortcuts.find(
      (s) => s.phrase.replace(/\s+/g, "") === trimmed.replace(/\s+/g, ""),
    );
    if (learnedMatch) {
      await this.executeIntents(learnedMatch.intents, learnedMatch.reply, "习惯记忆 0ms");
      return;
    }

    this.isResolvingIntent = true;
    this.render();

    try {
      const localPlan = LocalIntentParser.parse(trimmed, this.devices, this.scenes);
      let plan: IntentPlan | null = localPlan;
      let sourceLabel = "0ms 本地直达";

      if (!plan) {
        const apiKey = this.settings.openRouterApiKey.trim();
        if (!apiKey) {
          this.replyBanner = {
            text: "未命中本地规则。请在设置中填写 OpenRouter API Key 以启用 Jev SystemOne 决策模型。",
            source: "需要 API Key",
          };
          this.isResolvingIntent = false;
          this.render();
          return;
        }
        const resolver = new ModelIntentResolver(
          {
            baseURL: "https://openrouter.ai/api/v1",
            model: this.settings.assistantModel,
            apiKey,
          },
          this.transport,
        );
        plan = await resolver.resolve(trimmed, this.devices, this.scenes);
        sourceLabel = resolver.usesSystemOne ? "Jev SystemOne" : this.settings.assistantModel;
      }

      const sanitized = IntentValidator.sanitize(plan.intents, this.devices, this.scenes);
      const replyText =
        plan.reply || IntentReply.describe(sanitized, this.devices, this.scenes);
      await this.executeIntents(sanitized, replyText, sourceLabel);

      if (
        this.settings.habitLearningEnabled &&
        plan.source === "model" &&
        sanitized.length > 0
      ) {
        this.learnShortcut(trimmed, replyText, sanitized);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.replyBanner = {
        text: msg,
        source: "出错提示",
      };
    } finally {
      this.isResolvingIntent = false;
      this.render();
    }
  }

  private learnShortcut(
    phrase: string,
    reply: string,
    intents: readonly DeviceIntent[],
  ): void {
    const clean = phrase.trim();
    if (clean.length < 2 || clean.length > 18) return;
    if (this.settings.learnedShortcuts.some((s) => s.phrase === clean)) return;
    this.settings.learnedShortcuts.unshift({
      phrase: clean,
      reply,
      intents,
      learnedAt: new Date().toISOString(),
    });
    if (this.settings.learnedShortcuts.length > 25) {
      this.settings.learnedShortcuts.length = 25;
    }
    saveSettings(this.settings);
  }

  private buildInverseCommand(dev: SmartDevice): DeviceCommand[] {
    const k = dev.kind;
    switch (k.kind) {
      case "light": {
        const cmds: DeviceCommand[] = [
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ];
        if (k.brightnessPercent !== null) {
          cmds.push({
            kind: "setLightBrightness",
            entityId: k.entityId,
            percent: k.brightnessPercent,
          });
        }
        return cmds;
      }
      case "climate":
        return [
          {
            kind: "setClimatePower",
            entityId: k.entityId,
            isOn: k.isOn,
            resumeMode: k.hvacMode,
          },
          {
            kind: "setClimateTemperature",
            entityId: k.entityId,
            temperature: k.targetTemperature,
          },
        ];
      case "fan":
        return [{ kind: "setFanPower", entityId: k.entityId, isOn: k.isOn }];
      case "plug":
        return [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: k.isOn }];
      case "vacuum":
      case "sensor":
        return [];
    }
  }

  private async executeIntents(
    intents: readonly DeviceIntent[],
    replyText: string,
    sourceLabel: string,
  ): Promise<void> {
    const commands: DeviceCommand[] = [];
    const inverseCommands: DeviceCommand[] = [];
    const snapshot = structuredClone(this.devices);

    for (const intent of intents) {
      const dev = this.devices.find((d) => d.id === intent.targetId);
      if (!dev) continue;
      inverseCommands.push(...this.buildInverseCommand(dev));
      commands.push(...IntentValidator.commandsForIntent(intent, dev));
    }

    if (commands.length > 0) {
      this.lastUndoAction = {
        summary: replyText,
        snapshot,
        inverseCommands,
        expiresAtMs: Date.now() + 10 * 60 * 1000,
      };
    }

    for (const cmd of commands) {
      await this.applyCommand(cmd);
    }

    this.replyBanner = {
      text: replyText,
      source: sourceLabel,
    };
    this.render();
  }

  private async executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
  ): Promise<void> {
    this.lastUndoAction = {
      summary,
      snapshot: structuredClone(this.devices),
      inverseCommands: this.buildInverseCommand(device),
      expiresAtMs: Date.now() + 10 * 60 * 1000,
    };
    await this.applyCommand(command);
    this.replyBanner = {
      text: summary,
      source: "手动控制",
    };
    this.render();
  }

  private async performUndo(): Promise<void> {
    if (!this.lastUndoAction || this.lastUndoAction.expiresAtMs <= Date.now()) {
      this.lastUndoAction = null;
      this.replyBanner = {
        text: "没有可撤销的操作（仅支持 10 分钟内的操作撤销）",
        source: "撤销提示",
      };
      this.render();
      return;
    }
    const action = this.lastUndoAction;
    this.lastUndoAction = null;
    this.devices = action.snapshot;
    for (const cmd of action.inverseCommands) {
      await this.dispatchCloudCommand(cmd);
    }
    this.replyBanner = {
      text: `已撤销：${action.summary}`,
      source: "10分钟内撤销",
    };
    this.render();
  }

  private async applyCommand(command: DeviceCommand): Promise<void> {
    for (const dev of this.devices) {
      const k = dev.kind;
      switch (command.kind) {
        case "setLightPower":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setLightBrightness":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.percent > 0;
            k.brightnessPercent = command.percent;
          }
          break;
        case "setLightColorTemp":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.colorTempKelvin = command.kelvin;
          }
          break;
        case "setLightEffect":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.currentEffect = command.effect;
          }
          break;
        case "setClimatePower":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
            k.hvacMode = command.isOn ? command.resumeMode : "off";
          }
          break;
        case "setClimateMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.hvacMode !== "off";
            k.hvacMode = command.hvacMode;
          }
          break;
        case "setClimateTemperature":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = true;
            k.targetTemperature = command.temperature;
          }
          break;
        case "setClimateFanMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.fanMode = command.fanMode;
          }
          break;
        case "setFanPower":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setFanPresetMode":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.presetMode = command.presetMode;
          }
          break;
        case "setFanOscillating":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.isOscillating = command.oscillating;
          }
          break;
        case "setSwitch":
          if (k.kind === "plug" && k.switchEntityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "vacuumAction":
          if (k.kind === "vacuum" && k.entityId === command.entityId) {
            k.status =
              command.action === "start"
                ? "cleaning"
                : command.action === "pause"
                  ? "paused"
                  : "returning";
          }
          break;
        case "activateScene":
          break;
      }
    }

    await this.dispatchCloudCommand(command);
  }

  private async dispatchCloudCommand(command: DeviceCommand): Promise<void> {
    if (this.settings.connectionMode !== "xiaomiCloud" || !this.settings.miSession) {
      return;
    }
    const dev = this.devices.find((d) => {
      const k = d.kind;
      if (k.kind === "plug") return k.switchEntityId === command.entityId;
      if (k.kind === "sensor") return false;
      return k.entityId === command.entityId;
    });
    if (!dev) return;
    const spec = this.modelSpecs[dev.model];
    if (!spec) return;

    try {
      const mapped = MiotCommandMapper.map(command, spec);
      const client = new MiCloudClient(this.settings.miSession, this.transport);
      if (mapped.kind === "setProps") {
        await client.setProps(mapped.writes);
      } else {
        await client.action(mapped.call);
      }
    } catch {
      // keep optimistic UI update
    }
  }

  private toggleVoiceInput(): void {
    if (this.isListeningVoice) {
      this.speechRecognition?.stop();
      this.isListeningVoice = false;
      this.render();
      return;
    }

    const SpeechCtor = window.SpeechRecognition ?? window.webkitSpeechRecognition;
    if (!SpeechCtor) {
      this.replyBanner = {
        text: "当前宿主不支持语音识别，请直接输入文字指令。",
        source: "语音提示",
      };
      this.render();
      return;
    }

    const recognition = new SpeechCtor();
    recognition.lang = "zh-CN";
    recognition.interimResults = false;
    recognition.continuous = false;

    recognition.onresult = (event) => {
      const first = event.results[0]?.[0]?.transcript;
      if (first) {
        const inputEl = this.root.querySelector<HTMLInputElement>("#command-input");
        if (inputEl) inputEl.value = first;
        void this.handleNaturalCommand(first);
      }
    };
    recognition.onerror = () => {
      this.isListeningVoice = false;
      this.render();
    };
    recognition.onend = () => {
      this.isListeningVoice = false;
      this.render();
    };

    this.speechRecognition = recognition;
    this.isListeningVoice = true;
    this.render();
    recognition.start();
  }

  private async startXiaomiQRLogin(): Promise<void> {
    if (this.isPollingQR) return;
    this.isPollingQR = true;
    this.qrStatusText = "正在获取小米安全二维码...";
    this.render();

    try {
      const login = new MiAccountLogin(this.transport);
      const ticket = await login.start();
      this.qrTicket = ticket;
      this.qrStatusText = "请打开手机「米家 App → 扫一扫」确认登录";
      this.render();

      const session = await login.waitForScan(ticket);
      this.settings.miSession = session;
      this.settings.connectionMode = "xiaomiCloud";
      saveSettings(this.settings);
      this.qrStatusText = `已连接小米账号 ${maskedMiUserId(session.userId)}`;
      await this.refreshXiaomiDevices();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.qrStatusText = `扫码登录未完成：${msg}`;
    } finally {
      this.isPollingQR = false;
      this.render();
    }
  }

  private formatRemainingMs(ms: number): string {
    const secs = Math.max(0, Math.ceil(ms / 1000));
    if (secs >= 60) {
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return s > 0 ? `${m}分${s}秒` : `${m}分钟`;
    }
    return `${secs}秒`;
  }

  private render(): void {
    const modeLabel =
      this.settings.connectionMode === "xiaomiCloud"
        ? "米家直连"
        : this.settings.connectionMode === "homeAssistant"
          ? "HA 网关"
          : "演示模式";

    const activeUndo =
      this.lastUndoAction && this.lastUndoAction.expiresAtMs > Date.now()
        ? this.lastUndoAction
        : null;

    this.root.innerHTML = `
      <div class="tray-shell">
        <header class="header-bar">
          <div class="brand-group">
            <div class="brand-icon">🏠</div>
            <div class="brand-text">
              <h1>MenuMijia <span class="badge-mode">${modeLabel}</span></h1>
              <p>${this.activeDeviceCount} 台设备开启 · 室内 ${this.averageTemperatureText}</p>
            </div>
          </div>
          <div class="header-actions">
            <button class="icon-btn" id="btn-refresh" title="刷新设备状态">↻</button>
            <button class="icon-btn" id="btn-onboarding" title="新手引导">?</button>
            <button class="icon-btn" id="btn-settings" title="设置与连接">⚙</button>
          </div>
        </header>

        <section class="command-section">
          <div class="command-box">
            <input
              id="command-input"
              class="command-input"
              type="text"
              placeholder="说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销..."
              ${this.isResolvingIntent ? "disabled" : ""}
            />
            <button
              id="btn-mic"
              class="mic-btn ${this.isListeningVoice ? "listening" : ""}"
              title="语音输入 (Alt+M 呼出面板)"
            >🎤</button>
            <button id="btn-send" class="send-btn" ${this.isResolvingIntent ? "disabled" : ""}>
              ${this.isResolvingIntent ? "..." : "执行"}
            </button>
          </div>

          ${
            this.replyBanner || this.scheduledCommands.length > 0 || activeUndo
              ? `
            <div class="reply-banner">
              ${
                this.replyBanner
                  ? `
                <div class="reply-row">
                  <span class="reply-source">${this.escapeHtml(this.replyBanner.source)}</span>
                  <span class="reply-text">${this.escapeHtml(this.replyBanner.text)}</span>
                  ${
                    activeUndo
                      ? `<button class="undo-pill" id="btn-undo">撤销</button>`
                      : ""
                  }
                </div>
              `
                  : ""
              }
              ${
                this.scheduledCommands.length > 0
                  ? `
                <div class="timer-list">
                  ${this.scheduledCommands
                    .map(
                      (item) => `
                    <div class="timer-chip">
                      <span>⏳ ${this.escapeHtml(item.command)} (${this.formatRemainingMs(item.fireTimestampMs - Date.now())})</span>
                      <button class="timer-cancel" data-cancel-timer="${item.id}">取消</button>
                    </div>
                  `,
                    )
                    .join("")}
                </div>
              `
                  : ""
              }
            </div>
          `
              : ""
          }
        </section>

        <section class="scenes-grid">
          ${SCENE_CARDS.map(
            (scene) => `
            <button class="scene-card" data-scene-cmd="${this.escapeHtml(scene.command)}">
              <span class="scene-icon">${scene.icon}</span>
              <div class="scene-meta">
                <strong>${scene.title}</strong>
                <span>${scene.subtitle}</span>
              </div>
            </button>
          `,
          ).join("")}
        </section>

        <nav class="room-tabs">
          ${this.rooms
            .map(
              (room) => `
            <button class="room-tab ${this.selectedRoom === room ? "active" : ""}" data-room="${this.escapeHtml(room)}">
              ${this.escapeHtml(room)}
            </button>
          `,
            )
            .join("")}
        </nav>

        <main class="devices-list">
          ${this.filteredDevices.map((dev) => this.renderDeviceCard(dev)).join("")}
        </main>

        ${this.activeSheet === "onboarding" ? this.renderOnboardingModal() : ""}
        ${this.activeSheet === "settings" ? this.renderSettingsModal() : ""}
      </div>
    `;

    this.bindEvents();
  }

  private renderDeviceCard(dev: SmartDevice): string {
    const isExpanded = this.expandedDeviceId === dev.id;
    const isOn = isDeviceActiveOn(dev);
    const kind = dev.kind.kind;
    const icon =
      kind === "light"
        ? "💡"
        : kind === "climate"
          ? "❄️"
          : kind === "fan"
            ? "🌀"
            : kind === "plug"
              ? "🔌"
              : kind === "vacuum"
                ? "🤖"
                : "🌡️";

    const hasDrawer = kind === "light" || kind === "climate" || kind === "fan";

    return `
      <div class="device-card ${isOn ? "is-on" : ""}">
        <div class="device-main">
          <button class="device-toggle-area" data-toggle-device="${dev.id}">
            <span class="device-icon">${icon}</span>
            <div class="device-info">
              <div class="device-name">${this.escapeHtml(dev.name)}</div>
              <div class="device-status">${this.escapeHtml(dev.roomName)} · ${this.escapeHtml(deviceStatusSummary(dev))}</div>
            </div>
          </button>
          <div class="device-actions">
            ${
              hasDrawer
                ? `<button class="expand-btn" data-expand-device="${dev.id}" title="展开精细调节">${isExpanded ? "▴" : "▾"}</button>`
                : ""
            }
            ${
              kind !== "sensor"
                ? `<button class="power-switch ${isOn ? "on" : ""}" data-toggle-device="${dev.id}">
                    <span class="power-knob"></span>
                  </button>`
                : ""
            }
          </div>
        </div>
        ${isExpanded ? this.renderDeviceDrawer(dev) : ""}
      </div>
    `;
  }

  private renderDeviceDrawer(dev: SmartDevice): string {
    const k = dev.kind;
    if (k.kind === "light") {
      const bri = k.brightnessPercent ?? 80;
      const ct = k.colorTempKelvin ?? 4000;
      return `
        <div class="device-drawer">
          <div class="slider-row">
            <span>亮度 ${bri}%</span>
            <input type="range" min="1" max="100" value="${bri}" data-brightness="${dev.id}" />
          </div>
          <div class="slider-row">
            <span>色温 ${ct}K</span>
            <input type="range" min="${k.minKelvin}" max="${k.maxKelvin}" step="100" value="${ct}" data-colortemp="${dev.id}" />
          </div>
        </div>
      `;
    }
    if (k.kind === "climate") {
      const modes: ReadonlyArray<{ readonly code: string; readonly label: string }> = [
        { code: "cool", label: "制冷" },
        { code: "heat", label: "制热" },
        { code: "dry", label: "除湿" },
        { code: "fan_only", label: "送风" },
        { code: "auto", label: "自动" },
      ];
      return `
        <div class="device-drawer">
          <div class="slider-row">
            <span>目标温度 ${k.targetTemperature}°C</span>
            <input type="range" min="${k.minTemp}" max="${k.maxTemp}" step="${k.step}" value="${k.targetTemperature}" data-actemp="${dev.id}" />
          </div>
          <div class="mode-pills">
            ${modes
              .map(
                (m) => `
              <button class="mode-pill ${k.hvacMode === m.code ? "active" : ""}" data-acmode="${dev.id}:${m.code}">
                ${m.label}
              </button>
            `,
              )
              .join("")}
          </div>
        </div>
      `;
    }
    if (k.kind === "fan") {
      const modes = k.availablePresetModes.length > 0
        ? k.availablePresetModes
        : ["Level 1", "Level 2", "Level 3"];
      return `
        <div class="device-drawer">
          <div class="mode-pills">
            ${modes
              .map(
                (preset) => `
              <button class="mode-pill ${k.presetMode === preset ? "active" : ""}" data-fanpreset="${dev.id}:${this.escapeHtml(preset)}">
                ${this.escapeHtml(IntentReply.fanSpeedLabel(preset))}
              </button>
            `,
              )
              .join("")}
            <button class="mode-pill ${k.isOscillating ? "active" : ""}" data-fanosc="${dev.id}">
              摇头 ${k.isOscillating ? "开" : "关"}
            </button>
          </div>
        </div>
      `;
    }
    return "";
  }

  private renderOnboardingModal(): string {
    const steps: ReadonlyArray<{
      readonly badge: string;
      readonly title: string;
      readonly desc: string;
    }> = [
      {
        badge: "第 1 步 / 共 3 步 · 账号直连",
        title: "扫码直连米家，或先体验内置设备",
        desc: "无需繁琐配置 token：点击「获取米家登录二维码」用手机米家 App 扫一扫即可同步全屋设备；也可以直接用内置的 7 台演示设备体验全部控制能力。",
      },
      {
        badge: "第 2 步 / 共 3 步 · 意图与 AI 决策",
        title: "省去一问一答，自然表达直接执行",
        desc: "常用指令（「关灯」「调高两度」「10分钟后关灯」「撤销」）0ms 本地直达；复杂表达（「我困了」「专心看书」）由 OpenRouter Jev SystemOne 一次性推理出多设备动作。",
      },
      {
        badge: "第 3 步 / 共 3 步 · 全局呼出",
        title: "系统托盘常驻 + Alt+M 随叫随到",
        desc: "在 Windows 11 右下角系统托盘点击图标，或随时按下 Alt+M 即可呼出控制面板，支持麦克风语音输入与 10 分钟内一键撤销。",
      },
    ];
    const current = steps[this.onboardingStep] ?? steps[0]!;

    return `
      <div class="modal-backdrop">
        <div class="modal-sheet">
          <div class="modal-header">
            <span class="step-badge">${current.badge}</span>
            <button class="icon-btn" id="btn-close-onboarding">✕</button>
          </div>
          <h2 class="modal-title">${current.title}</h2>
          <p class="modal-desc">${current.desc}</p>

          ${
            this.onboardingStep === 0
              ? `
            <div class="qr-card">
              <div class="qr-actions">
                <button class="primary-btn" id="btn-start-qr" ${this.isPollingQR ? "disabled" : ""}>
                  ${this.isPollingQR ? "等待米家 App 扫码..." : "获取米家登录二维码"}
                </button>
                <span class="qr-hint">${this.escapeHtml(this.qrStatusText)}</span>
              </div>
              ${
                this.qrTicket
                  ? `<div class="qr-preview">
                      <img src="${this.escapeHtml(this.qrTicket.qrImageURL)}" alt="Xiaomi QR" />
                    </div>`
                  : ""
              }
            </div>
          `
              : ""
          }

          ${
            this.onboardingStep === 1
              ? `
            <div class="field-group">
              <label>OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图推理）</label>
              <input
                id="onboarding-api-key"
                class="text-input"
                type="password"
                placeholder="sk-or-v1-..."
                value="${this.escapeHtml(this.settings.openRouterApiKey)}"
              />
            </div>
          `
              : ""
          }

          <div class="modal-footer">
            ${
              this.onboardingStep > 0
                ? `<button class="secondary-btn" id="btn-prev-step">上一步</button>`
                : `<span></span>`
            }
            ${
              this.onboardingStep < 2
                ? `<button class="primary-btn" id="btn-next-step">下一步</button>`
                : `<button class="primary-btn" id="btn-finish-onboarding">开始使用 MenuMijia</button>`
            }
          </div>
        </div>
      </div>
    `;
  }

  private renderSettingsModal(): string {
    return `
      <div class="modal-backdrop">
        <div class="modal-sheet">
          <div class="modal-header">
            <strong>连接、AI 决策与隐私设置</strong>
            <button class="icon-btn" id="btn-close-settings">✕</button>
          </div>

          <div class="field-group">
            <label>数据源模式</label>
            <div class="mode-pills">
              <button class="mode-pill ${this.settings.connectionMode === "demo" ? "active" : ""}" data-conn-mode="demo">演示模式</button>
              <button class="mode-pill ${this.settings.connectionMode === "xiaomiCloud" ? "active" : ""}" data-conn-mode="xiaomiCloud">米家云直连</button>
              <button class="mode-pill ${this.settings.connectionMode === "homeAssistant" ? "active" : ""}" data-conn-mode="homeAssistant">Home Assistant</button>
            </div>
          </div>

          <div class="qr-card">
            <div class="qr-actions">
              <button class="primary-btn" id="btn-start-qr" ${this.isPollingQR ? "disabled" : ""}>
                ${this.settings.miSession ? `重新扫码 (已连 ${maskedMiUserId(this.settings.miSession.userId)})` : "米家 App 扫码登录"}
              </button>
              <span class="qr-hint">${this.escapeHtml(this.qrStatusText)}</span>
            </div>
            ${
              this.qrTicket
                ? `<div class="qr-preview"><img src="${this.escapeHtml(this.qrTicket.qrImageURL)}" alt="Xiaomi QR" /></div>`
                : ""
            }
          </div>

          <div class="field-group">
            <label>OpenRouter API Key（驱动 Jev /v1/systemone 毫秒级意图决策）</label>
            <input
              id="settings-api-key"
              class="text-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${this.escapeHtml(this.settings.openRouterApiKey)}"
            />
          </div>

          <div class="field-group">
            <label>决策模型（默认 ~typesafe/jev-latest）</label>
            <input
              id="settings-model"
              class="text-input"
              type="text"
              value="${this.escapeHtml(this.settings.assistantModel)}"
            />
          </div>

          <div class="field-group">
            <label class="checkbox-row">
              <input type="checkbox" id="settings-habit" ${this.settings.habitLearningEnabled ? "checked" : ""} />
              <span>记住自然语言习惯（下次相同表达 0ms 本地直达）</span>
            </label>
            ${
              this.settings.learnedShortcuts.length > 0
                ? `<div class="habit-list">
                    ${this.settings.learnedShortcuts
                      .map(
                        (s, idx) => `
                      <div class="timer-chip">
                        <span>「${this.escapeHtml(s.phrase)}」→ ${this.escapeHtml(s.reply)}</span>
                        <button class="timer-cancel" data-del-habit="${idx}">删除</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>`
                : `<p class="privacy-note">隐私说明：仅在未命中本地规则时将指令文本与设备名称摘要发送给所选 AI 模型，账号凭证始终保存在本机。</p>`
            }
          </div>

          <div class="modal-footer">
            <button class="secondary-btn" id="btn-reopen-guide">重看新手引导</button>
            <button class="primary-btn" id="btn-save-settings">保存设置</button>
          </div>
        </div>
      </div>
    `;
  }

  private bindEvents(): void {
    const inputEl = this.root.querySelector<HTMLInputElement>("#command-input");
    const sendBtn = this.root.querySelector<HTMLButtonElement>("#btn-send");
    const micBtn = this.root.querySelector<HTMLButtonElement>("#btn-mic");

    inputEl?.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        void this.handleNaturalCommand(inputEl.value);
      }
    });
    sendBtn?.addEventListener("click", () => {
      if (inputEl) void this.handleNaturalCommand(inputEl.value);
    });
    micBtn?.addEventListener("click", () => {
      this.toggleVoiceInput();
    });

    this.root.querySelector("#btn-refresh")?.addEventListener("click", () => {
      if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
        void this.refreshXiaomiDevices();
      } else {
        this.render();
      }
    });

    this.root.querySelector("#btn-onboarding")?.addEventListener("click", () => {
      this.onboardingStep = 0;
      this.activeSheet = "onboarding";
      this.render();
    });

    this.root.querySelector("#btn-settings")?.addEventListener("click", () => {
      this.activeSheet = "settings";
      this.render();
    });

    this.root.querySelector("#btn-undo")?.addEventListener("click", () => {
      void this.performUndo();
    });

    this.root.querySelectorAll<HTMLElement>("[data-cancel-timer]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.cancelTimer;
        this.scheduledCommands = this.scheduledCommands.filter((c) => c.id !== id);
        this.render();
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-scene-cmd]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const cmd = btn.dataset.sceneCmd;
        if (cmd) void this.handleNaturalCommand(cmd);
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-room]").forEach((btn) => {
      btn.addEventListener("click", () => {
        this.selectedRoom = btn.dataset.room ?? "全部";
        this.render();
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-toggle-device]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.toggleDevice;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind === "sensor") return;
        const nextOn = !isDeviceActiveOn(dev);
        const cmds = IntentValidator.commandsForIntent(
          { targetId: dev.id, operation: { kind: "power", isOn: nextOn } },
          dev,
        );
        const firstCmd = cmds[0];
        if (firstCmd) {
          void this.executeSingleCommand(
            dev,
            firstCmd,
            `已${nextOn ? "打开" : "关闭"}${dev.name}`,
          );
        }
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-expand-device]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.expandDevice ?? null;
        this.expandedDeviceId = this.expandedDeviceId === id ? null : id;
        this.render();
      });
    });

    this.root.querySelectorAll<HTMLInputElement>("[data-brightness]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.brightness;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const percent = Number(slider.value);
        void this.executeSingleCommand(
          dev,
          { kind: "setLightBrightness", entityId: dev.kind.entityId, percent },
          `已将${dev.name}亮度设为 ${percent}%`,
        );
      });
    });

    this.root.querySelectorAll<HTMLInputElement>("[data-colortemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.colortemp;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const kelvin = Number(slider.value);
        void this.executeSingleCommand(
          dev,
          { kind: "setLightColorTemp", entityId: dev.kind.entityId, kelvin },
          `已将${dev.name}色温设为 ${kelvin}K`,
        );
      });
    });

    this.root.querySelectorAll<HTMLInputElement>("[data-actemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.actemp;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        const temperature = Number(slider.value);
        void this.executeSingleCommand(
          dev,
          { kind: "setClimateTemperature", entityId: dev.kind.entityId, temperature },
          `已将${dev.name}设为 ${temperature}°C`,
        );
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-acmode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.acmode;
        if (!raw) return;
        const [id, hvacMode] = raw.split(":");
        if (!id || !hvacMode) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        void this.executeSingleCommand(
          dev,
          { kind: "setClimateMode", entityId: dev.kind.entityId, hvacMode },
          `已切换${dev.name}模式`,
        );
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-fanpreset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.fanpreset;
        if (!raw) return;
        const [id, presetMode] = raw.split(":");
        if (!id || !presetMode) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        void this.executeSingleCommand(
          dev,
          { kind: "setFanPresetMode", entityId: dev.kind.entityId, presetMode },
          `已将${dev.name}设为 ${IntentReply.fanSpeedLabel(presetMode)}`,
        );
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-fanosc]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.fanosc;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        const nextOsc = !dev.kind.isOscillating;
        void this.executeSingleCommand(
          dev,
          { kind: "setFanOscillating", entityId: dev.kind.entityId, oscillating: nextOsc },
          `已${nextOsc ? "开启" : "关闭"}${dev.name}摇头`,
        );
      });
    });

    this.root.querySelector("#btn-start-qr")?.addEventListener("click", () => {
      void this.startXiaomiQRLogin();
    });

    this.root.querySelector("#btn-close-onboarding")?.addEventListener("click", () => {
      this.settings.hasCompletedOnboarding = true;
      saveSettings(this.settings);
      this.activeSheet = "none";
      this.render();
    });

    this.root.querySelector("#btn-prev-step")?.addEventListener("click", () => {
      this.onboardingStep = Math.max(0, this.onboardingStep - 1);
      this.render();
    });

    this.root.querySelector("#btn-next-step")?.addEventListener("click", () => {
      const keyInput = this.root.querySelector<HTMLInputElement>("#onboarding-api-key");
      if (keyInput) {
        this.settings.openRouterApiKey = keyInput.value.trim();
        saveSettings(this.settings);
      }
      this.onboardingStep = Math.min(2, this.onboardingStep + 1);
      this.render();
    });

    this.root.querySelector("#btn-finish-onboarding")?.addEventListener("click", () => {
      this.settings.hasCompletedOnboarding = true;
      saveSettings(this.settings);
      this.activeSheet = "none";
      this.render();
    });

    this.root.querySelector("#btn-close-settings")?.addEventListener("click", () => {
      this.activeSheet = "none";
      this.render();
    });

    this.root.querySelector("#btn-reopen-guide")?.addEventListener("click", () => {
      this.onboardingStep = 0;
      this.activeSheet = "onboarding";
      this.render();
    });

    this.root.querySelectorAll<HTMLElement>("[data-conn-mode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const mode = btn.dataset.connMode as ConnectionMode | undefined;
        if (!mode) return;
        this.settings.connectionMode = mode;
        if (mode === "demo") {
          this.devices = structuredClone(DEMO_DEVICES);
        }
        saveSettings(this.settings);
        this.render();
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-del-habit]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const idx = Number(btn.dataset.delHabit);
        if (!Number.isNaN(idx)) {
          this.settings.learnedShortcuts.splice(idx, 1);
          saveSettings(this.settings);
          this.render();
        }
      });
    });

    this.root.querySelector("#btn-save-settings")?.addEventListener("click", () => {
      const apiKeyEl = this.root.querySelector<HTMLInputElement>("#settings-api-key");
      const modelEl = this.root.querySelector<HTMLInputElement>("#settings-model");
      const habitEl = this.root.querySelector<HTMLInputElement>("#settings-habit");
      if (apiKeyEl) this.settings.openRouterApiKey = apiKeyEl.value.trim();
      if (modelEl) this.settings.assistantModel = modelEl.value.trim() || "~typesafe/jev-latest";
      if (habitEl) this.settings.habitLearningEnabled = habitEl.checked;
      saveSettings(this.settings);
      this.activeSheet = "none";
      this.render();
    });
  }

  private escapeHtml(str: string): string {
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
}

document.addEventListener("DOMContentLoaded", () => {
  const root = document.getElementById("app");
  if (root) {
    new MenuMijiaWindowsApp(root);
  }
});
