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
  MiotSpecResolver,
  MiotSynthesizer,
  type MiSession,
  type QRLoginTicket,
  maskedMiUserId,
} from "../core/miCloudClient.js";
import {
  type DeviceCommand,
  type DeviceIntent,
  type EnvironmentReading,
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
  isCompactGridMode: boolean;
  cachedXiaomiDevices: SmartDevice[];
  cachedModelTypes: Record<string, string>;
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
  readonly isError?: boolean;
}

const STORAGE_KEY = "menumijia.windows.settings.v2";
const LEGACY_STORAGE_KEY = "menumijia.windows.settings.v1";

// Crisp Apple SF-Symbol-matched vector icons (zero Windows emojis)
const SF_ICONS = {
  houseFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10.707 2.293a1 1 0 00-1.414 0l-7 7a1 1 0 001.414 1.414L4 10.414V17a1 1 0 001 1h3a1 1 0 001-1v-3a1 1 0 011-1h0a1 1 0 011 1v3a1 1 0 001 1h3a1 1 0 001-1v-6.586l.293.293a1 1 0 001.414-1.414l-7-7z"/></svg>`,
  lightbulbFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 2a6 6 0 00-3.815 10.631C7.237 13.5 8 14.443 8 15.5v.5a2 2 0 002 2h0a2 2 0 002-2v-.5c0-1.057.763-2 1.815-2.869A6 6 0 0010 2zm-1.5 15.5h3a.5.5 0 010 1h-3a.5.5 0 010-1z"/></svg>`,
  snowflake: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2v16M2 10h16M4.93 4.93l10.14 10.14M15.07 4.93L4.93 15.07M10 4.5L8 2.5M10 4.5l2-2M10 15.5l-2 2M10 15.5l2 2"/></svg>`,
  fanbladesFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 8.2a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6zm.5-6.2c-2.2 0-3.6 1.8-2.9 3.9.3.8.8 1.5 1.5 1.9.3-.2.6-.3.9-.3.7 0 1.3.4 1.6 1 .8-.6 1.4-1.7 1.4-3.1C13 3.4 11.9 2 10.5 2zm7.5 8.5c0-2.2-1.8-3.6-3.9-2.9-.8.3-1.5.8-1.9 1.5.2.3.3.6.3.9 0 .7-.4 1.3-1 1.6.6.8 1.7 1.4 3.1 1.4 2 0 3.4-1.1 3.4-2.5zM9.5 18c2.2 0 3.6-1.8 2.9-3.9-.3-.8-.8-1.5-1.5-1.9-.3.2-.6.3-.9.3-.7 0-1.3-.4-1.6-1-.8.6-1.4 1.7-1.4 3.1 0 2 1.1 3.4 2.5 3.4zM2 9.5c0 2.2 1.8 3.6 3.9 2.9.8-.3 1.5-.8 1.9-1.5-.2-.3-.3-.6-.3-.9 0-.7.4-1.3 1-1.6-.6-.8-1.7-1.4-3.1-1.4-2 0-3.4 1.1-3.4 2.5z"/></svg>`,
  powerplugFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M7 2a1 1 0 011 1v3h4V3a1 1 0 112 0v3h1a1 1 0 011 1v2.5a5.5 5.5 0 01-4.5 5.408V17a1 1 0 11-2 0v-2.092A5.5 5.5 0 014 9.5V7a1 1 0 011-1h1V3a1 1 0 011-1z"/></svg>`,
  sparkles: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10.8 2.4a.6.6 0 00-1.1 0L8.1 6.3a2.2 2.2 0 01-1.2 1.2L3 9.1a.6.6 0 000 1.1l3.9 1.6c.5.2 1 .7 1.2 1.2l1.6 3.9a.6.6 0 001.1 0l1.6-3.9c.2-.5.7-1 1.2-1.2l3.9-1.6a.6.6 0 000-1.1l-3.9-1.6a2.2 2.2 0 01-1.2-1.2L10.8 2.4zM15.8 13.2a.4.4 0 00-.7 0l-.6 1.4-.4.4-1.4.6a.4.4 0 000 .7l1.4.6.4.4.6 1.4a.4.4 0 00.7 0l.6-1.4.4-.4 1.4-.6a.4.4 0 000-.7l-1.4-.6-.4-.4-.6-1.4z"/></svg>`,
  sensorFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 3a2.5 2.5 0 00-2.5 2.5v6.085a4 4 0 105 0V5.5A2.5 2.5 0 0010 3zm0 1.5a1 1 0 011 1v6.6a.75.75 0 00.32.614 2.5 2.5 0 11-2.64 0 .75.75 0 00.32-.614V5.5a1 1 0 011-1z"/></svg>`,
  micFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 2.5a2.75 2.75 0 00-2.75 2.75v4.5a2.75 2.75 0 005.5 0v-4.5A2.75 2.75 0 0010 2.5zM5.25 9.25a.75.75 0 00-1.5 0 6.25 6.25 0 005.5 6.205V17.5h-2a.75.75 0 000 1.5h5.5a.75.75 0 000-1.5h-2v-2.045a6.25 6.25 0 005.5-6.205.75.75 0 00-1.5 0 4.75 4.75 0 11-9.5 0z"/></svg>`,
  arrowClockwise: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M16.5 4.5v4h-4"/><path d="M15.8 12.8a6.2 6.2 0 11-1.3-6.6L16.5 8.5"/></svg>`,
  sliderHorizontal: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M3 5.5h9M15 5.5h2M3 10h3M9 10h8M3 14.5h7M13 14.5h4"/><circle cx="13.5" cy="5.5" r="1.6" fill="currentColor"/><circle cx="7.5" cy="10" r="1.6" fill="currentColor"/><circle cx="11.5" cy="14.5" r="1.6" fill="currentColor"/></svg>`,
  power: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round"><path d="M10 2.8v6.4M6.1 4.8a6.2 6.2 0 107.8 0"/></svg>`,
  chevronRight: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 4.5L13 10l-5.5 5.5"/></svg>`,
  chevronDown: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7.5L10 12.5 15 7.5"/></svg>`,
  sunMaxFill: `<svg viewBox="0 0 20 20" fill="currentColor"><circle cx="10" cy="10" r="3.6"/><path stroke="currentColor" stroke-width="1.7" stroke-linecap="round" d="M10 2.2v2M10 15.8v2M2.2 10h2M15.8 10h2M4.48 4.48l1.42 1.42M14.1 14.1l1.42 1.42M15.52 4.48L14.1 5.9M5.9 14.1l-1.42 1.42"/></svg>`,
  moonStarsFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M14.9 13.3A6.5 6.5 0 017.7 4.1a.6.6 0 00-.78-.75 7.2 7.2 0 108.73 9.73.6.6 0 00-.75-.78z"/></svg>`,
  boltFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M11.3 1.9L4.6 10.6a.6.6 0 00.48.96H9.5l-.8 6.54a.5.5 0 00.89.36l6.7-8.7a.6.6 0 00-.48-.96H11.4l.79-6.54a.5.5 0 00-.89-.36z"/></svg>`,
  grid2x2: `<svg viewBox="0 0 20 20" fill="currentColor"><rect x="3" y="3" width="6" height="6" rx="1.6"/><rect x="11" y="3" width="6" height="6" rx="1.6"/><rect x="3" y="11" width="6" height="6" rx="1.6"/><rect x="11" y="11" width="6" height="6" rx="1.6"/></svg>`,
  grid1x2: `<svg viewBox="0 0 20 20" fill="currentColor"><rect x="3" y="3.5" width="14" height="5.2" rx="1.6"/><rect x="3" y="11.3" width="14" height="5.2" rx="1.6"/></svg>`,
  qrcode: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M3 3h6v6H3V3zm1.5 1.5v3h3v-3h-3zM11 3h6v6h-6V3zm1.5 1.5v3h3v-3h-3zM3 11h6v6H3v-6zm1.5 1.5v3h3v-3h-3zM11 11h2.5v2.5H11V11zm3.5 0H17v2.5h-2.5V11zM11 14.5h2.5V17H11v-2.5zm3.5 0H17V17h-2.5v-2.5z"/></svg>`,
  xmark: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M5.5 5.5l9 9M14.5 5.5l-9 9"/></svg>`,
  arrowUpCircle: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 18a8 8 0 100-16 8 8 0 000 16zm.53-11.28a.75.75 0 00-1.06 0L6.72 9.47a.75.75 0 101.06 1.06l1.47-1.47v4.19a.75.75 0 001.5 0V9.06l1.47 1.47a.75.75 0 101.06-1.06l-2.75-2.75z"/></svg>`,
};

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

const QUICK_ACTIONS: ReadonlyArray<{
  readonly id: string;
  readonly title: string;
  readonly icon: string;
  readonly tint: string;
  readonly command: string;
}> = [
  { id: "lights_on", title: "全开主灯", icon: SF_ICONS.sunMaxFill, tint: "amber", command: "打开所有灯" },
  { id: "lights_off", title: "睡眠关灯", icon: SF_ICONS.moonStarsFill, tint: "indigo", command: "关闭所有灯" },
  { id: "cool_25", title: "25°制冷", icon: SF_ICONS.snowflake, tint: "cyan", command: "空调调到25度" },
  { id: "focus", title: "调亮灯光", icon: SF_ICONS.lightbulbFill, tint: "amber", command: "再亮一点" },
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

function invokeTauriVoid(cmd: string, args?: Record<string, unknown>): void {
  if (window.__TAURI_INTERNALS__?.invoke) {
    void window.__TAURI_INTERNALS__.invoke(cmd, args);
  }
}

function loadSettings(): PersistedSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY) ?? localStorage.getItem(LEGACY_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<PersistedSettings>;
      const miSession = parsed.miSession ?? null;
      const mode: ConnectionMode = miSession
        ? "xiaomiCloud"
        : (parsed.connectionMode ?? "demo");
      return {
        connectionMode: mode,
        miSession,
        haBaseURL: parsed.haBaseURL ?? "",
        haToken: parsed.haToken ?? "",
        openRouterApiKey: parsed.openRouterApiKey ?? "",
        assistantModel: parsed.assistantModel ?? "~typesafe/jev-latest",
        habitLearningEnabled: parsed.habitLearningEnabled ?? true,
        learnedShortcuts: parsed.learnedShortcuts ?? [],
        hasCompletedOnboarding: parsed.hasCompletedOnboarding ?? Boolean(miSession),
        isCompactGridMode: parsed.isCompactGridMode ?? true,
        cachedXiaomiDevices: Array.isArray(parsed.cachedXiaomiDevices)
          ? parsed.cachedXiaomiDevices
          : [],
        cachedModelTypes:
          parsed.cachedModelTypes && typeof parsed.cachedModelTypes === "object"
            ? parsed.cachedModelTypes
            : {},
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
    isCompactGridMode: true,
    cachedXiaomiDevices: [],
    cachedModelTypes: {},
  };
}

function saveSettings(settings: PersistedSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    // ignore storage quota errors
  }
}

class MenuMijiaWindowsApp {
  private settings: PersistedSettings = loadSettings();
  private devices: SmartDevice[] =
    this.settings.connectionMode === "xiaomiCloud"
      ? structuredClone(this.settings.cachedXiaomiDevices)
      : structuredClone(DEMO_DEVICES);
  private scenes: HomeScene[] =
    this.settings.connectionMode === "xiaomiCloud" ? [] : structuredClone(DEMO_SCENES);
  private environmentReadings: EnvironmentReading[] = [];
  private selectedRoom = "全部";
  private expandedDeviceId: string | null = null;
  private isShowingAssistantBar = true;
  private activeSheet: "none" | "onboarding" | "settings" = "none";
  private onboardingStep = 0;
  private replyBanner: ReplyBannerState | null = null;
  private isResolvingIntent = false;
  private isSyncingCloud = false;
  private isListeningVoice = false;
  private scheduledCommands: ScheduledCommand[] = [];
  private lastUndoAction: UndoAction | null = null;
  private qrTicket: QRLoginTicket | null = null;
  private qrStatusText = "点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。";
  private isPollingQR = false;
  private readonly transport: HttpTransport = createTransport();
  private readonly specResolver: MiotSpecResolver;
  private speechRecognition: SpeechRecognitionInstance | null = null;

  constructor(private readonly root: HTMLElement) {
    this.specResolver = new MiotSpecResolver(
      this.transport,
      undefined,
      this.settings.cachedModelTypes,
    );

    if (!this.settings.hasCompletedOnboarding && !this.settings.miSession) {
      this.activeSheet = "onboarding";
    }

    this.bindGlobalKeys();
    this.startTimerLoop();
    this.render();

    if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
      void this.refreshXiaomiDevices();
    }
  }

  private bindGlobalKeys(): void {
    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        if (this.activeSheet !== "none") {
          this.activeSheet = "none";
          invokeTauriVoid("set_pin_popover", { pin: false });
          this.render();
        } else {
          invokeTauriVoid("hide_panel");
        }
      } else if (e.key === "/" && document.activeElement?.tagName !== "INPUT") {
        e.preventDefault();
        this.isShowingAssistantBar = true;
        this.render();
        this.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });
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

    // Background cloud state refresh every 12 seconds when logged into Xiaomi Cloud
    window.setInterval(() => {
      if (
        this.settings.connectionMode === "xiaomiCloud" &&
        this.settings.miSession &&
        !this.isSyncingCloud &&
        !this.isPollingQR
      ) {
        void this.refreshXiaomiDevices(true);
      }
    }, 12000);
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

  private get onlineDeviceCount(): number {
    return this.devices.filter((d) => d.isOnline).length;
  }

  private get totalPowerWatts(): number {
    let watts = 0;
    for (const d of this.devices) {
      if (d.kind.kind === "plug" && d.kind.powerWatts && d.kind.powerWatts > 0) {
        watts += d.kind.powerWatts;
      }
    }
    return watts;
  }

  private get computedEnvironmentReadings(): EnvironmentReading[] {
    if (this.environmentReadings.length > 0) return this.environmentReadings;
    const out: EnvironmentReading[] = [];
    for (const d of this.devices) {
      if (d.kind.kind === "sensor" && (d.kind.temperature !== null || d.kind.humidity !== null)) {
        out.push({
          id: d.id,
          label: d.name.replace("温湿度计", "").trim() || d.roomName,
          roomName: d.roomName,
          temperature: d.kind.temperature,
          humidity: d.kind.humidity,
          battery: d.kind.battery,
        });
      }
    }
    return out;
  }

  private async refreshXiaomiDevices(silent = false): Promise<void> {
    if (!this.settings.miSession) return;
    if (!silent) {
      this.isSyncingCloud = true;
      this.render();
    }

    try {
      const client = new MiCloudClient(this.settings.miSession, this.transport);
      const [rawDevices, rooms] = await Promise.all([
        client.deviceList(),
        client.homeRooms().catch(() => []),
      ]);

      // Stage 1: Instant synthesis with cached/fallback specs so user sees their real devices immediately
      const stage1Specs = this.specResolver.exportCachedSpecs();
      const stage1Home = MiotSynthesizer.synthesize(
        rawDevices,
        rooms,
        stage1Specs,
        new Map<string, unknown>(),
      );
      if (stage1Home.devices.length > 0 && this.devices.length === 0) {
        this.devices = stage1Home.devices;
        this.render();
      }

      // Stage 2: Resolve exact MIoT specs + fetch live device properties
      const specs = await this.specResolver.resolveForDevices(rawDevices);
      const propKeys: MiotPropKey[] = [];
      for (const dev of rawDevices) {
        const spec = specs[dev.model];
        if (spec) {
          propKeys.push(...MiotSynthesizer.requiredProps(dev, spec));
        }
      }

      const values =
        propKeys.length > 0
          ? await client.getProps(propKeys).catch(() => new Map<string, unknown>())
          : new Map<string, unknown>();

      const home = MiotSynthesizer.synthesize(rawDevices, rooms, specs, values);
      this.devices = home.devices;
      this.environmentReadings = [...home.environmentReadings];

      this.settings.cachedXiaomiDevices = home.devices;
      this.settings.cachedModelTypes = this.specResolver.exportKnownModelTypes(
        rawDevices.map((d) => d.model),
      );
      saveSettings(this.settings);

      if (!silent) {
        this.replyBanner = {
          text:
            home.devices.length > 0
              ? `已同步 ${home.devices.length} 台真实米家设备`
              : "当前小米账号下暂未发现米家设备",
          source: "米家云直连",
        };
      }
    } catch (err) {
      if (!silent) {
        const msg = err instanceof Error ? err.message : String(err);
        this.replyBanner = {
          text: `米家云同步失败：${msg}`,
          source: "连接异常",
          isError: true,
        };
      }
    } finally {
      this.isSyncingCloud = false;
      this.render();
    }
  }

  private async turnAllOff(): Promise<void> {
    const activeDevices = this.devices.filter((d) => isDeviceActiveOn(d));
    if (activeDevices.length === 0) return;
    const intents: DeviceIntent[] = activeDevices.map((d) => ({
      targetId: d.id,
      operation: { kind: "power", isOn: false },
    }));
    await this.executeIntents(intents, `已关闭 ${activeDevices.length} 台开启中的设备`, "一键全关");
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
            isError: true,
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
        isError: true,
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
      source: "实时控制",
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
      source: "已恢复",
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

    try {
      const spec = await this.specResolver.resolve({
        did: dev.id,
        name: dev.name,
        model: dev.model,
        isOnline: dev.isOnline,
        specType: null,
      });
      const mapped = MiotCommandMapper.map(command, spec);
      const client = new MiCloudClient(this.settings.miSession, this.transport);
      if (mapped.kind === "setProps") {
        await client.setProps(mapped.writes);
      } else {
        await client.action(mapped.call);
      }
    } catch {
      // keep optimistic UI state
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
      this.isShowingAssistantBar = true;
      this.replyBanner = {
        text: "当前系统环境不支持离线语音识别，请直接输入文字指令。",
        source: "语音提示",
      };
      this.render();
      this.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      return;
    }

    this.isShowingAssistantBar = true;
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
    this.qrStatusText = "正在获取小米安全登录二维码...";
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();

    try {
      const login = new MiAccountLogin(this.transport);
      const ticket = await login.start();
      this.qrTicket = ticket;
      this.qrStatusText = "请打开手机「米家 App → 我的 → 右上角扫一扫」确认登录";
      this.render();

      const session = await login.waitForScan(ticket);
      this.settings.miSession = session;
      this.settings.connectionMode = "xiaomiCloud";
      this.settings.hasCompletedOnboarding = true;
      // Clear fake demo devices immediately upon real Xiaomi login
      this.devices = [];
      this.scenes = [];
      this.selectedRoom = "全部";
      this.activeSheet = "none";
      this.qrTicket = null;
      saveSettings(this.settings);

      this.qrStatusText = `已连接小米账号 ${maskedMiUserId(session.userId)}`;
      this.replyBanner = {
        text: `已登录小米账号 ${maskedMiUserId(session.userId)}，正在拉取真实设备...`,
        source: "扫码成功",
      };
      this.render();

      await this.refreshXiaomiDevices(false);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.qrStatusText = `扫码未完成：${msg}`;
    } finally {
      this.isPollingQR = false;
      invokeTauriVoid("set_pin_popover", { pin: false });
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

  private get statusSummaryText(): string {
    if (this.settings.connectionMode === "xiaomiCloud") {
      if (this.isSyncingCloud && this.devices.length === 0) {
        return "正在从小米云端同步真实设备...";
      }
      if (this.activeDeviceCount > 0) {
        return `${this.activeDeviceCount} 台开启中 · 共 ${this.onlineDeviceCount} 台在线`;
      }
      return `全屋待机 · ${this.onlineDeviceCount} 台实时在线`;
    }
    return `演示预览 · 点击下方「扫码直连」同步你的真机`;
  }

  private render(): void {
    const isDemo = this.settings.connectionMode === "demo";
    const activeUndo =
      this.lastUndoAction && this.lastUndoAction.expiresAtMs > Date.now()
        ? this.lastUndoAction
        : null;
    const envChips = this.computedEnvironmentReadings;
    const watts = this.totalPowerWatts;

    this.root.innerHTML = `
      <div class="cc-popover">
        <header class="cc-header">
          <div class="cc-header-top">
            <div class="cc-title-group">
              <div class="cc-home-badge ${this.activeDeviceCount > 0 ? "is-active" : ""}">
                ${SF_ICONS.houseFill}
              </div>
              <div class="cc-title-stack">
                <div class="cc-title-row">
                  <span class="cc-home-title">我的米家</span>
                  <span class="cc-mode-pill ${isDemo ? "is-demo" : "is-cloud"}">
                    ${isDemo ? "演示预览" : "Miot 直连"}
                  </span>
                </div>
                <div class="cc-subtitle">${this.escapeHtml(this.statusSummaryText)}</div>
              </div>
            </div>

            <div class="cc-header-controls">
              <button
                class="cc-circle-btn ${this.isListeningVoice ? "is-recording" : ""}"
                id="btn-mic"
                title="语音控制"
              >
                ${SF_ICONS.micFill}
              </button>
              <button
                class="cc-circle-btn ${this.isShowingAssistantBar ? "is-selected" : ""}"
                id="btn-toggle-assistant"
                title="AI 自然语言指令栏 (/)"
              >
                ${SF_ICONS.sparkles}
              </button>
              ${
                this.activeDeviceCount > 0
                  ? `<button class="cc-all-off-pill" id="btn-all-off" title="一键关闭所有开启中的设备">
                      ${SF_ICONS.power}
                      <span>全关 (${this.activeDeviceCount})</span>
                    </button>`
                  : ""
              }
              <button
                class="cc-circle-btn"
                id="btn-hide-panel"
                title="收起面板到右下角托盘 (Esc)"
              >
                ${SF_ICONS.chevronDown}
              </button>
            </div>
          </div>

          ${
            envChips.length > 0 || watts >= 1
              ? `
            <div class="cc-env-strip">
              ${envChips
                .map(
                  (env) => `
                <div class="cc-env-chip">
                  <span class="cc-env-icon">${SF_ICONS.sensorFill}</span>
                  <span class="cc-env-label">${this.escapeHtml(env.label)}</span>
                  ${env.temperature !== null ? `<strong class="cc-env-val">${env.temperature.toFixed(1)}°</strong>` : ""}
                  ${env.humidity !== null ? `<span class="cc-env-hum">· ${Math.round(env.humidity)}%</span>` : ""}
                </div>
              `,
                )
                .join("")}
              ${
                watts >= 1
                  ? `
                <div class="cc-env-chip is-power">
                  <span class="cc-env-icon">${SF_ICONS.boltFill}</span>
                  <strong class="cc-env-val">${Math.round(watts)}W</strong>
                </div>
              `
                  : ""
              }
            </div>
          `
              : ""
          }
        </header>

        ${
          this.isShowingAssistantBar
            ? `
          <section class="cc-assistant-section">
            <div class="cc-spotlight-bar">
              <span class="cc-spotlight-icon">${SF_ICONS.sparkles}</span>
              <input
                id="command-input"
                class="cc-spotlight-input"
                type="text"
                placeholder="说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销..."
                ${this.isResolvingIntent ? "disabled" : ""}
              />
              <button
                id="btn-send"
                class="cc-spotlight-send"
                title="执行指令 (Enter)"
                ${this.isResolvingIntent ? "disabled" : ""}
              >
                ${SF_ICONS.arrowUpCircle}
              </button>
            </div>

            ${
              this.replyBanner || this.scheduledCommands.length > 0 || activeUndo
                ? `
              <div class="cc-feedback-card ${this.replyBanner?.isError ? "is-error" : ""}">
                ${
                  this.replyBanner
                    ? `
                  <div class="cc-feedback-row">
                    <span class="cc-feedback-badge">${this.escapeHtml(this.replyBanner.source)}</span>
                    <span class="cc-feedback-text">${this.escapeHtml(this.replyBanner.text)}</span>
                    ${
                      activeUndo
                        ? `<button class="cc-inline-pill" id="btn-undo">撤销</button>`
                        : ""
                    }
                  </div>
                `
                    : ""
                }
                ${
                  this.scheduledCommands.length > 0
                    ? `
                  <div class="cc-timers-stack">
                    ${this.scheduledCommands
                      .map(
                        (item) => `
                      <div class="cc-timer-row">
                        <span>${this.escapeHtml(item.command)} · 剩余 ${this.formatRemainingMs(item.fireTimestampMs - Date.now())}</span>
                        <button class="cc-inline-pill" data-cancel-timer="${item.id}">取消</button>
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
        `
            : ""
        }

        <section class="cc-quick-strip">
          ${QUICK_ACTIONS.map(
            (act) => `
            <button class="cc-quick-pill tint-${act.tint}" data-scene-cmd="${this.escapeHtml(act.command)}">
              <span class="cc-quick-icon">${act.icon}</span>
              <span>${this.escapeHtml(act.title)}</span>
            </button>
          `,
          ).join("")}
        </section>

        <div class="cc-room-bar">
          <div class="cc-room-scroll">
            ${this.rooms
              .map(
                (room) => `
              <button
                class="cc-room-pill ${this.selectedRoom === room ? "is-active" : ""}"
                data-room="${this.escapeHtml(room)}"
              >
                ${this.escapeHtml(room)}
              </button>
            `,
              )
              .join("")}
          </div>
          <button
            class="cc-circle-btn is-small"
            id="btn-toggle-grid"
            title="${this.settings.isCompactGridMode ? "切换为单列详情视图" : "切换为双列控制中心磁贴"}"
          >
            ${this.settings.isCompactGridMode ? SF_ICONS.grid2x2 : SF_ICONS.grid1x2}
          </button>
        </div>

        <div class="cc-divider"></div>

        <main class="cc-scroll-area">
          ${this.renderDeviceGrid()}
        </main>

        <div class="cc-divider"></div>

        <footer class="cc-footer">
          <div class="cc-footer-status">
            <span class="cc-status-dot ${this.isSyncingCloud ? "is-syncing" : isDemo ? "is-demo" : "is-online"}"></span>
            <span class="cc-footer-label">
              ${
                this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession
                  ? `米家账号 ${maskedMiUserId(this.settings.miSession.userId)} · ${this.devices.length} 台设备`
                  : "演示模式 · 未连接米家云"
              }
            </span>
          </div>

          <div class="cc-footer-actions">
            ${
              !this.settings.miSession || isDemo
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-qr" title="用手机米家 App 扫码直连真实设备">
                    ${SF_ICONS.qrcode}
                    <span>扫码直连</span>
                  </button>`
                : ""
            }
            <button
              class="cc-footer-icon-btn ${this.isSyncingCloud ? "is-spinning" : ""}"
              id="btn-refresh"
              title="立即同步最新设备状态"
            >
              ${SF_ICONS.arrowClockwise}
            </button>
            <button
              class="cc-footer-icon-btn"
              id="btn-settings"
              title="连接设置与 AI 决策配置"
            >
              ${SF_ICONS.sliderHorizontal}
            </button>
            <button
              class="cc-footer-pill is-danger"
              id="btn-quit-app"
              title="完全退出 MenuMijia"
            >
              ${SF_ICONS.power}
              <span>退出</span>
            </button>
          </div>
        </footer>

        ${this.activeSheet === "onboarding" ? this.renderOnboardingModal() : ""}
        ${this.activeSheet === "settings" ? this.renderSettingsModal() : ""}
      </div>
    `;

    this.bindEvents();
  }

  private renderDeviceGrid(): string {
    if (this.settings.connectionMode === "xiaomiCloud" && this.devices.length === 0) {
      if (this.isSyncingCloud) {
        return `
          <div class="cc-empty-state">
            <div class="cc-empty-icon is-pulsing">${SF_ICONS.sparkles}</div>
            <div class="cc-empty-title">正在同步你的真实米家设备…</div>
            <div class="cc-empty-subtitle">正在从小米云端拉取房间、MIoT 规格与实时状态</div>
          </div>
        `;
      }
      return `
        <div class="cc-empty-state">
          <div class="cc-empty-icon">${SF_ICONS.houseFill}</div>
          <div class="cc-empty-title">尚未同步到米家设备</div>
          <div class="cc-empty-subtitle">请确认当前小米账号在米家 App 中中国大陆区有绑定的智能设备</div>
          <div class="cc-empty-actions">
            <button class="cc-btn-primary" id="btn-empty-resync">重新同步设备</button>
            <button class="cc-btn-secondary" id="btn-empty-settings">切换账号 / 设置</button>
          </div>
        </div>
      `;
    }

    const list = this.filteredDevices;
    const gridClass = this.settings.isCompactGridMode ? "cc-devices-grid is-compact" : "cc-devices-grid is-single";
    return `
      <div class="${gridClass}">
        ${list.map((dev) => this.renderDeviceTile(dev)).join("")}
      </div>
    `;
  }

  private devicePaletteClass(dev: SmartDevice): string {
    switch (dev.kind.kind) {
      case "light":
        return "palette-amber";
      case "climate":
        return "palette-blue";
      case "fan":
        return "palette-mint";
      case "plug":
        return "palette-green";
      case "vacuum":
        return "palette-indigo";
      case "sensor":
        return "palette-teal";
    }
  }

  private deviceSvgIcon(dev: SmartDevice): string {
    switch (dev.kind.kind) {
      case "light":
        return SF_ICONS.lightbulbFill;
      case "climate":
        return SF_ICONS.snowflake;
      case "fan":
        return SF_ICONS.fanbladesFill;
      case "plug":
        return SF_ICONS.powerplugFill;
      case "vacuum":
        return SF_ICONS.sparkles;
      case "sensor":
        return SF_ICONS.sensorFill;
    }
  }

  private renderDeviceTile(dev: SmartDevice): string {
    const isExpanded = this.expandedDeviceId === dev.id;
    const isOn = isDeviceActiveOn(dev);
    const kind = dev.kind.kind;
    const palette = this.devicePaletteClass(dev);
    const svg = this.deviceSvgIcon(dev);
    const hasDrawer = kind === "light" || kind === "climate" || kind === "fan";
    const subtitle =
      this.selectedRoom === "全部"
        ? `${dev.roomName} · ${deviceStatusSummary(dev)}`
        : deviceStatusSummary(dev);

    return `
      <div class="cc-tile ${palette} ${isOn ? "is-active" : ""} ${isExpanded ? "is-expanded" : ""} ${dev.isOnline ? "" : "is-offline"}">
        <div class="cc-tile-header">
          <button
            class="cc-tile-orb"
            data-toggle-device="${this.escapeHtml(dev.id)}"
            title="${kind === "sensor" ? dev.name : "点击直接切换开关"}"
          >
            ${svg}
          </button>

          <button
            class="cc-tile-body"
            data-body-device="${this.escapeHtml(dev.id)}"
            title="${hasDrawer ? "点击展开精细调节" : "点击切换开关"}"
          >
            <div class="cc-tile-name">${this.escapeHtml(dev.name)}</div>
            <div class="cc-tile-status">${this.escapeHtml(subtitle)}</div>
          </button>

          ${
            hasDrawer
              ? `<button
                  class="cc-tile-chevron ${isExpanded ? "is-open" : ""}"
                  data-expand-device="${this.escapeHtml(dev.id)}"
                  title="${isExpanded ? "收起详细控制" : "展开详细控制"}"
                >
                  ${SF_ICONS.chevronRight}
                </button>`
              : ""
          }
        </div>
        ${isExpanded && hasDrawer ? this.renderDeviceDrawer(dev) : ""}
      </div>
    `;
  }

  private renderDeviceDrawer(dev: SmartDevice): string {
    const k = dev.kind;
    if (k.kind === "light") {
      const bri = k.brightnessPercent ?? 80;
      const ct = k.colorTempKelvin ?? 4000;
      return `
        <div class="cc-tile-drawer">
          <div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>亮度</span>
              <strong>${bri}%</strong>
            </div>
            <input class="cc-range is-amber" type="range" min="1" max="100" value="${bri}" data-brightness="${this.escapeHtml(dev.id)}" />
          </div>
          <div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>色温</span>
              <strong>${ct}K</strong>
            </div>
            <input class="cc-range is-kelvin" type="range" min="${k.minKelvin}" max="${k.maxKelvin}" step="100" value="${ct}" data-colortemp="${this.escapeHtml(dev.id)}" />
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
        <div class="cc-tile-drawer">
          <div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>目标温度</span>
              <strong>${k.targetTemperature}°C</strong>
            </div>
            <input class="cc-range is-blue" type="range" min="${k.minTemp}" max="${k.maxTemp}" step="${k.step}" value="${k.targetTemperature}" data-actemp="${this.escapeHtml(dev.id)}" />
          </div>
          <div class="cc-segmented-pills">
            ${modes
              .map(
                (m) => `
              <button class="cc-seg-pill ${k.hvacMode === m.code ? "is-active" : ""}" data-acmode="${this.escapeHtml(dev.id)}:${m.code}">
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
      const modes =
        k.availablePresetModes.length > 0
          ? k.availablePresetModes
          : ["Level 1", "Level 2", "Level 3", "Level 4"];
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            ${modes
              .map(
                (preset) => `
              <button class="cc-seg-pill ${k.presetMode === preset ? "is-active" : ""}" data-fanpreset="${this.escapeHtml(dev.id)}:${this.escapeHtml(preset)}">
                ${this.escapeHtml(IntentReply.fanSpeedLabel(preset))}
              </button>
            `,
              )
              .join("")}
            <button class="cc-seg-pill ${k.isOscillating ? "is-active" : ""}" data-fanosc="${this.escapeHtml(dev.id)}">
              摇头 ${k.isOscillating ? "开" : "关"}
            </button>
          </div>
        </div>
      `;
    }
    return "";
  }

  private renderOnboardingModal(): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet">
          <div class="cc-sheet-header">
            <div class="cc-sheet-badge">MenuMijia 控制中心</div>
            <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="关闭引导">
              ${SF_ICONS.xmark}
            </button>
          </div>

          <h2 class="cc-sheet-title">扫码直连你的真实米家设备</h2>
          <p class="cc-sheet-desc">
            手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。
          </p>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${this.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>${this.isPollingQR ? "正在等待手机米家扫码确认..." : "获取米家登录二维码"}</span>
            </button>
            <div class="cc-qr-status">${this.escapeHtml(this.qrStatusText)}</div>
            ${
              this.qrTicket
                ? `<div class="cc-qr-frame">
                    <img src="${this.escapeHtml(this.qrTicket.qrImageURL)}" alt="Xiaomi QR" />
                  </div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）</label>
            <input
              id="onboarding-api-key"
              class="cc-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${this.escapeHtml(this.settings.openRouterApiKey)}"
            />
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-secondary" id="btn-close-onboarding-alt">先看演示预览</button>
            <button class="cc-btn-primary" id="btn-finish-onboarding">进入控制中心</button>
          </div>
        </div>
      </div>
    `;
  }

  private renderSettingsModal(): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet">
          <div class="cc-sheet-header">
            <strong>偏好设置与米家连接</strong>
            <button class="cc-circle-btn is-small" id="btn-close-settings" title="返回控制中心">
              ${SF_ICONS.xmark}
            </button>
          </div>

          <div class="cc-field">
            <label>设备数据源</label>
            <div class="cc-segmented-pills">
              <button
                class="cc-seg-pill ${this.settings.connectionMode === "xiaomiCloud" ? "is-active" : ""}"
                data-conn-mode="xiaomiCloud"
              >
                米家云真实设备
              </button>
              <button
                class="cc-seg-pill ${this.settings.connectionMode === "demo" ? "is-active" : ""}"
                data-conn-mode="demo"
              >
                演示设备预览
              </button>
            </div>
          </div>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${this.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>
                ${
                  this.settings.miSession
                    ? `切换/重新扫码 (已登录 ${maskedMiUserId(this.settings.miSession.userId)})`
                    : "获取米家登录二维码"
                }
              </span>
            </button>
            <div class="cc-qr-status">${this.escapeHtml(this.qrStatusText)}</div>
            ${
              this.qrTicket
                ? `<div class="cc-qr-frame"><img src="${this.escapeHtml(this.qrTicket.qrImageURL)}" alt="Xiaomi QR" /></div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>OpenRouter API Key（驱动 Jev /v1/systemone 毫秒级意图决策）</label>
            <input
              id="settings-api-key"
              class="cc-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${this.escapeHtml(this.settings.openRouterApiKey)}"
            />
          </div>

          <div class="cc-field">
            <label>决策模型（默认 ~typesafe/jev-latest）</label>
            <input
              id="settings-model"
              class="cc-input"
              type="text"
              value="${this.escapeHtml(this.settings.assistantModel)}"
            />
          </div>

          <div class="cc-field">
            <label class="cc-checkbox">
              <input type="checkbox" id="settings-habit" ${this.settings.habitLearningEnabled ? "checked" : ""} />
              <span>自动记住自然语言习惯（相同表达下次 0ms 本地直达）</span>
            </label>
            ${
              this.settings.learnedShortcuts.length > 0
                ? `<div class="cc-timers-stack">
                    ${this.settings.learnedShortcuts
                      .map(
                        (s, idx) => `
                      <div class="cc-timer-row">
                        <span>「${this.escapeHtml(s.phrase)}」→ ${this.escapeHtml(s.reply)}</span>
                        <button class="cc-inline-pill" data-del-habit="${idx}">删除</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>`
                : ""
            }
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-danger" id="btn-settings-quit">退出 MenuMijia</button>
            <button class="cc-btn-primary" id="btn-save-settings">完成并保存</button>
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

    this.root.querySelector("#btn-toggle-assistant")?.addEventListener("click", () => {
      this.isShowingAssistantBar = !this.isShowingAssistantBar;
      this.render();
      if (this.isShowingAssistantBar) {
        this.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });

    this.root.querySelector("#btn-all-off")?.addEventListener("click", () => {
      void this.turnAllOff();
    });

    this.root.querySelector("#btn-hide-panel")?.addEventListener("click", () => {
      invokeTauriVoid("set_pin_popover", { pin: false });
      invokeTauriVoid("hide_panel");
    });

    this.root.querySelector("#btn-quit-app")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    this.root.querySelector("#btn-settings-quit")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    this.root.querySelector("#btn-toggle-grid")?.addEventListener("click", () => {
      this.settings.isCompactGridMode = !this.settings.isCompactGridMode;
      saveSettings(this.settings);
      this.render();
    });

    this.root.querySelector("#btn-refresh")?.addEventListener("click", () => {
      if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
        void this.refreshXiaomiDevices(false);
      } else {
        this.render();
      }
    });

    this.root.querySelector("#btn-footer-qr")?.addEventListener("click", () => {
      this.activeSheet = "settings";
      this.render();
      void this.startXiaomiQRLogin();
    });

    this.root.querySelector("#btn-empty-resync")?.addEventListener("click", () => {
      void this.refreshXiaomiDevices(false);
    });

    this.root.querySelector("#btn-empty-settings")?.addEventListener("click", () => {
      this.activeSheet = "settings";
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

    const toggleDeviceById = (id: string) => {
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
    };

    this.root.querySelectorAll<HTMLElement>("[data-toggle-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.toggleDevice;
        if (id) toggleDeviceById(id);
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-body-device]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.bodyDevice;
        if (!id) return;
        const dev = this.devices.find((d) => d.id === id);
        if (!dev) return;
        const k = dev.kind.kind;
        if (k === "light" || k === "climate" || k === "fan") {
          this.expandedDeviceId = this.expandedDeviceId === id ? null : id;
          this.render();
        } else {
          toggleDeviceById(id);
        }
      });
    });

    this.root.querySelectorAll<HTMLElement>("[data-expand-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
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

    const closeOnboarding = () => {
      const keyInput = this.root.querySelector<HTMLInputElement>("#onboarding-api-key");
      if (keyInput && keyInput.value.trim()) {
        this.settings.openRouterApiKey = keyInput.value.trim();
      }
      this.settings.hasCompletedOnboarding = true;
      saveSettings(this.settings);
      this.activeSheet = "none";
      invokeTauriVoid("set_pin_popover", { pin: false });
      this.render();
    };

    this.root.querySelector("#btn-close-onboarding")?.addEventListener("click", closeOnboarding);
    this.root.querySelector("#btn-close-onboarding-alt")?.addEventListener("click", closeOnboarding);
    this.root.querySelector("#btn-finish-onboarding")?.addEventListener("click", closeOnboarding);

    this.root.querySelector("#btn-close-settings")?.addEventListener("click", () => {
      this.activeSheet = "none";
      invokeTauriVoid("set_pin_popover", { pin: false });
      this.render();
    });

    this.root.querySelectorAll<HTMLElement>("[data-conn-mode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const mode = btn.dataset.connMode as ConnectionMode | undefined;
        if (!mode) return;
        this.settings.connectionMode = mode;
        this.selectedRoom = "全部";
        if (mode === "demo") {
          this.devices = structuredClone(DEMO_DEVICES);
          this.scenes = structuredClone(DEMO_SCENES);
        } else if (mode === "xiaomiCloud") {
          this.devices = structuredClone(this.settings.cachedXiaomiDevices);
          this.scenes = [];
          if (this.settings.miSession) {
            void this.refreshXiaomiDevices(false);
          }
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
      invokeTauriVoid("set_pin_popover", { pin: false });
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
