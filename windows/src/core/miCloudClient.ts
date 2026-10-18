import { MiCloudCrypto } from "./miCloudCrypto.js";
import type {
  DeviceCommand,
  DeviceKind,
  EnvironmentReading,
  RoomCategory,
  SmartDevice,
  SynthesizedHome,
} from "./models.js";

export interface HttpRequest {
  readonly url: string;
  readonly method?: "GET" | "POST";
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string;
  readonly followRedirects?: boolean;
  readonly timeoutMs?: number;
}

export interface HttpResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string;
}

export type HttpTransport = (req: HttpRequest) => Promise<HttpResponse>;

export interface QRLoginTicket {
  readonly qrImageURL: string;
  readonly loginURL: string;
  readonly longPollURL: string;
  readonly timeout: number;
}

export interface MiSession {
  readonly userId: string;
  readonly cUserId: string;
  readonly ssecurity: string;
  readonly serviceToken: string;
  readonly passToken: string;
  readonly region: string;
}

export function maskedMiUserId(userId: string): string {
  if (userId.length <= 4) return "*".repeat(userId.length);
  return `${userId.slice(0, 2)}****${userId.slice(-2)}`;
}

export function miApiBaseURL(region = "cn"): string {
  const r = region.trim().toLowerCase();
  return r === "" || r === "cn" ? "https://api.io.mi.com/app" : `https://${r}.api.io.mi.com/app`;
}

export class MiCloudError extends Error {
  readonly kind: "notLoggedIn" | "sessionExpired" | "http" | "api" | "badResponse";
  readonly code?: number;

  constructor(
    kind: "notLoggedIn" | "sessionExpired" | "http" | "api" | "badResponse",
    message: string,
    code?: number
  ) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

function stripStartPrefix(raw: string): string {
  const trimmed = raw.trim();
  const marker = "&&&START&&&";
  const idx = trimmed.indexOf(marker);
  return idx >= 0 ? trimmed.slice(idx + marker.length).trim() : trimmed;
}

function parseJsonObject(raw: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(stripStartPrefix(raw));
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return null;
  } catch {
    return null;
  }
}

function asIdString(v: unknown): string | null {
  if (typeof v === "string" && v.length > 0) return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(Math.trunc(v));
  return null;
}

export class MiAccountLogin {
  private readonly transport: HttpTransport;
  private readonly region: string;

  constructor(transport: HttpTransport, region = "cn") {
    this.transport = transport;
    this.region = region;
  }

  async start(nowMs = Date.now()): Promise<QRLoginTicket> {
    const query = MiCloudCrypto.formURLEncode([
      ["_qrsize", "480"],
      ["qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"],
      ["callback", "https://sts.api.io.mi.com/sts"],
      ["_hasLogo", "false"],
      ["sid", "xiaomiio"],
      ["serviceParam", ""],
      ["_locale", "zh_CN"],
      ["_dc", String(nowMs)],
    ]);
    const resp = await this.transport({
      url: `https://account.xiaomi.com/longPolling/loginUrl?${query}`,
      method: "GET",
    });
    if (resp.status !== 200) {
      throw new MiCloudError("http", `小米账号服务返回 HTTP ${resp.status}`, resp.status);
    }
    return MiAccountLogin.parseTicket(resp.body);
  }

  static parseTicket(body: string): QRLoginTicket {
    const json = parseJsonObject(body);
    if (!json) throw new MiCloudError("badResponse", "小米账号服务响应非 JSON");
    const qr = typeof json["qr"] === "string" ? json["qr"] : null;
    const loginUrl = typeof json["loginUrl"] === "string" ? json["loginUrl"] : null;
    const lp = typeof json["lp"] === "string" ? json["lp"] : null;
    if (!qr || !loginUrl || !lp) {
      const code = asIdString(json["code"]) ?? "?";
      throw new MiCloudError("badResponse", `缺少二维码字段 (code ${code})`);
    }
    const timeoutRaw = json["timeout"];
    const timeout =
      typeof timeoutRaw === "number"
        ? timeoutRaw
        : typeof timeoutRaw === "string"
          ? Number(timeoutRaw) || 300
          : 300;
    return { qrImageURL: qr, loginURL: loginUrl, longPollURL: lp, timeout };
  }

  static parseScanResult(body: string): {
    userId: string;
    cUserId: string;
    ssecurity: string;
    passToken: string;
    location: string;
  } {
    const json = parseJsonObject(body);
    if (!json) throw new MiCloudError("badResponse", "扫码结果非 JSON");
    const userId = asIdString(json["userId"]);
    const ssecurity = typeof json["ssecurity"] === "string" ? json["ssecurity"] : null;
    const location = typeof json["location"] === "string" ? json["location"] : null;
    if (!userId || !ssecurity || !location) {
      const code = asIdString(json["code"]) ?? "?";
      throw new MiCloudError("badResponse", `扫码结果缺少字段 (code ${code})`);
    }
    return {
      userId,
      cUserId: asIdString(json["cUserId"]) ?? "",
      ssecurity,
      passToken: typeof json["passToken"] === "string" ? json["passToken"] : "",
      location,
    };
  }

  async waitForScan(ticket: QRLoginTicket, signal?: AbortSignal): Promise<MiSession> {
    const deadline = Date.now() + ticket.timeout * 1000;
    let scanned: ReturnType<typeof MiAccountLogin.parseScanResult> | null = null;
    while (!scanned) {
      if (signal?.aborted) throw new Error("Cancelled");
      if (Date.now() >= deadline) {
        throw new MiCloudError("badResponse", "二维码已过期，请重新获取");
      }
      try {
        const resp = await this.transport({
          url: ticket.longPollURL,
          method: "GET",
          timeoutMs: 15_000,
        });
        if (resp.status === 200 && resp.body.trim().length > 0) {
          scanned = MiAccountLogin.parseScanResult(resp.body);
        } else {
          await new Promise((r) => setTimeout(r, 800));
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message.toLowerCase() : "";
        if (msg.includes("timeout") || msg.includes("timed out")) {
          continue;
        }
        throw err;
      }
    }

    const serviceToken = await this.fetchServiceToken(scanned.location);
    return {
      userId: scanned.userId,
      cUserId: scanned.cUserId,
      ssecurity: scanned.ssecurity,
      serviceToken,
      passToken: scanned.passToken,
      region: this.region,
    };
  }

  private async fetchServiceToken(initialLocation: string): Promise<string> {
    let url = initialLocation;
    for (let i = 0; i < 5; i++) {
      const resp = await this.transport({
        url,
        method: "GET",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        followRedirects: false,
      });
      const cookieHeader =
        resp.headers["set-cookie"] ?? resp.headers["Set-Cookie"] ?? "";
      const match = /(?:^|[;,\s])serviceToken=([^;\s,]+)/.exec(cookieHeader);
      if (match?.[1]) {
        return match[1];
      }
      const nextLoc = resp.headers["location"] ?? resp.headers["Location"];
      if (resp.status >= 300 && resp.status < 400 && nextLoc) {
        url = new URL(nextLoc, url).toString();
        continue;
      }
      break;
    }
    throw new MiCloudError("badResponse", "登录成功但未拿到 serviceToken，请重试");
  }
}

export interface MiDeviceRecord {
  readonly did: string;
  readonly name: string;
  readonly model: string;
  readonly isOnline: boolean;
  readonly specType: string | null;
}

export interface MiRoom {
  readonly id: string;
  readonly name: string;
  readonly dids: readonly string[];
}

export interface MiotPropKey {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
}

export function propKeyString(k: MiotPropKey): string {
  return `${k.did}.${k.siid}.${k.piid}`;
}

export interface MiotPropWrite {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
  readonly value: unknown;
}

export interface MiotActionCall {
  readonly did: string;
  readonly siid: number;
  readonly aiid: number;
  readonly inputs: readonly unknown[];
}

export class MiCloudClient {
  private readonly session: MiSession;
  private readonly transport: HttpTransport;
  private readonly userAgent: string;

  constructor(session: MiSession, transport: HttpTransport) {
    this.session = session;
    this.transport = transport;
    this.userAgent = "abcdefghijklmnoqrs-ABCDEABCDEABC APP/com.xiaomi.mihome APPV/10.5.201";
  }

  async request(api: string, data: unknown): Promise<unknown> {
    const cleanPath = "/" + api.replace(/^\/+|\/+$/g, "");
    const url = `${miApiBaseURL(this.session.region)}${cleanPath}`;
    const nonce = MiCloudCrypto.makeNonce();
    const signed = MiCloudCrypto.signedNonce(this.session.ssecurity, nonce);
    const dataStr = MiCloudCrypto.compactJSONString(data);
    const fields = MiCloudCrypto.encryptParams(cleanPath, dataStr, this.session.ssecurity, nonce);

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "User-Agent": this.userAgent,
        "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2",
        "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4",
        "Accept-Encoding": "identity",
        "Content-Type": "application/x-www-form-urlencoded",
        Cookie: [
          `userId=${this.session.userId}`,
          `serviceToken=${this.session.serviceToken}`,
          `yetAnotherServiceToken=${this.session.serviceToken}`,
          "locale=zh_CN",
          "timezone=GMT+08:00",
          "is_daylight=0",
          "dst_offset=0",
          "channel=MI_APP_STORE",
        ].join("; "),
      },
      body: MiCloudCrypto.formURLEncode(fields),
    });

    return MiCloudClient.decodeResponse(resp.body, resp.status, signed);
  }

  static decodeResponse(body: string, statusCode: number, signedNonce: string): unknown {
    if (statusCode === 401 || statusCode === 403) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码");
    }
    const plain = parseJsonObject(body);
    if (plain) {
      return MiCloudClient.unwrapResult(plain);
    }
    if (statusCode !== 200) {
      throw new MiCloudError("http", `米家云服务 HTTP ${statusCode}`, statusCode);
    }
    let decryptedText: string;
    try {
      decryptedText = MiCloudCrypto.decryptResponse(body, signedNonce);
    } catch {
      throw new MiCloudError("badResponse", "米家云响应无法解密");
    }
    const json = parseJsonObject(decryptedText);
    if (!json) {
      throw new MiCloudError("badResponse", "米家云解密后非 JSON");
    }
    return MiCloudClient.unwrapResult(json);
  }

  static unwrapResult(json: Record<string, unknown>): unknown {
    const code = typeof json["code"] === "number" ? Math.trunc(json["code"]) : 0;
    const message =
      typeof json["message"] === "string"
        ? json["message"]
        : typeof json["desc"] === "string"
          ? json["desc"]
          : "";
    if (code === 0) return json["result"] ?? null;
    const lower = message.toLowerCase();
    if (
      code === 2 ||
      code === 3 ||
      lower.includes("auth err") ||
      lower.includes("servicetoken_expired") ||
      lower.includes("token expired") ||
      lower.includes("invalid signature")
    ) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码", code);
    }
    throw new MiCloudError("api", `米家云指令失败 (${code})：${message}`, code);
  }

  static parseDeviceList(result: unknown): MiDeviceRecord[] {
    if (!result || typeof result !== "object") return [];
    const list = (result as Record<string, unknown>)["list"];
    if (!Array.isArray(list)) return [];
    const out: MiDeviceRecord[] = [];
    for (const item of list) {
      if (!item || typeof item !== "object") continue;
      const rec = item as Record<string, unknown>;
      const did = asIdString(rec["did"]);
      const model = typeof rec["model"] === "string" ? rec["model"] : null;
      if (!did || !model) continue;
      out.push({
        did,
        name: typeof rec["name"] === "string" ? rec["name"] : model,
        model,
        isOnline: typeof rec["isOnline"] === "boolean" ? rec["isOnline"] : true,
        specType: typeof rec["spec_type"] === "string" ? rec["spec_type"] : null,
      });
    }
    return out;
  }

  static parseRooms(result: unknown): MiRoom[] {
    if (!result || typeof result !== "object") return [];
    const homelist = (result as Record<string, unknown>)["homelist"];
    if (!Array.isArray(homelist)) return [];
    const rooms: MiRoom[] = [];
    for (const home of homelist) {
      if (!home || typeof home !== "object") continue;
      const roomlist = (home as Record<string, unknown>)["roomlist"];
      if (!Array.isArray(roomlist)) continue;
      for (const rm of roomlist) {
        if (!rm || typeof rm !== "object") continue;
        const r = rm as Record<string, unknown>;
        const id = asIdString(r["id"]);
        if (!id) continue;
        const rawDids = Array.isArray(r["dids"]) ? r["dids"] : [];
        const dids = rawDids.map(asIdString).filter((d): d is string => d !== null);
        rooms.push({
          id,
          name: typeof r["name"] === "string" ? r["name"] : "",
          dids,
        });
      }
    }
    return rooms;
  }

  async deviceList(): Promise<MiDeviceRecord[]> {
    const res = await this.request("home/device_list", {
      getVirtualModel: true,
      getHuamiDevices: 1,
      get_split_device: false,
      support_smart_home: true,
    });
    return MiCloudClient.parseDeviceList(res);
  }

  async homeRooms(): Promise<MiRoom[]> {
    try {
      const merged = await this.request("v2/homeroom/gethome_merged", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 7,
        plat_form: 0,
      });
      return MiCloudClient.parseRooms(merged);
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      const fallback = await this.request("v2/homeroom/gethome", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 7,
      });
      return MiCloudClient.parseRooms(fallback);
    }
  }

  async getProps(keys: readonly MiotPropKey[]): Promise<Map<string, unknown>> {
    const values = new Map<string, unknown>();
    const chunkSize = 100;
    for (let start = 0; start < keys.length; start += chunkSize) {
      const chunk = keys.slice(start, start + chunkSize);
      const params = chunk.map((k) => ({ did: k.did, siid: k.siid, piid: k.piid }));
      const result = await this.request("miotspec/prop/get", { params });
      if (Array.isArray(result)) {
        for (const item of result) {
          if (!item || typeof item !== "object") continue;
          const obj = item as Record<string, unknown>;
          const did = asIdString(obj["did"]);
          const siid = typeof obj["siid"] === "number" ? Math.trunc(obj["siid"]) : null;
          const piid = typeof obj["piid"] === "number" ? Math.trunc(obj["piid"]) : null;
          const code = typeof obj["code"] === "number" ? Math.trunc(obj["code"]) : 0;
          if (did && siid !== null && piid !== null && code === 0 && "value" in obj) {
            values.set(propKeyString({ did, siid, piid }), obj["value"]);
          }
        }
      }
    }
    return values;
  }

  async setProps(writes: readonly MiotPropWrite[]): Promise<void> {
    const params = writes.map((w) => ({
      did: w.did,
      siid: w.siid,
      piid: w.piid,
      value: w.value,
    }));
    const result = await this.request("miotspec/prop/set", { params });
    if (Array.isArray(result)) {
      for (const item of result) {
        if (item && typeof item === "object") {
          const code = typeof (item as Record<string, unknown>)["code"] === "number"
            ? Math.trunc((item as Record<string, unknown>)["code"] as number)
            : 0;
          if (code < 0) {
            throw new MiCloudError("api", "设备未响应或离线", code);
          }
        }
      }
    }
  }

  async action(call: MiotActionCall): Promise<void> {
    const result = await this.request("miotspec/action", {
      params: {
        did: call.did,
        siid: call.siid,
        aiid: call.aiid,
        in: call.inputs,
      },
    });
    if (result && typeof result === "object") {
      const code = typeof (result as Record<string, unknown>)["code"] === "number"
        ? Math.trunc((result as Record<string, unknown>)["code"] as number)
        : 0;
      if (code < 0) {
        throw new MiCloudError("api", "设备未响应或离线", code);
      }
    }
  }
}

// MARK: - MIoT Spec & Synthesis

export interface MiotValueListItem {
  readonly value: number;
  readonly description: string;
}

export interface MiotProperty {
  readonly iid: number;
  readonly type: string;
  readonly format: string;
  readonly access: readonly string[];
  readonly valueRange?: readonly number[];
  readonly valueList?: readonly MiotValueListItem[];
}

export interface MiotAction {
  readonly iid: number;
  readonly type: string;
}

export interface MiotService {
  readonly iid: number;
  readonly type: string;
  readonly properties: readonly MiotProperty[];
  readonly actions: readonly MiotAction[];
}

export interface MiotDeviceSpec {
  readonly type: string;
  readonly services: readonly MiotService[];
}

export function miotShortName(urn: string): string {
  const parts = urn.split(":");
  return parts[3] ?? urn;
}

export function makeMiotAddress(did: string, siid: number): string {
  return `miot:${did}:${siid}`;
}

export function parseMiotAddress(entityId: string): { did: string; siid: number } | null {
  if (!entityId.startsWith("miot:")) return null;
  const rest = entityId.slice("miot:".length);
  const sep = rest.lastIndexOf(":");
  if (sep <= 0) return null;
  const did = rest.slice(0, sep);
  const siid = Number(rest.slice(sep + 1));
  if (!Number.isInteger(siid)) return null;
  return { did, siid };
}

export function hvacModeFromDescription(desc: string): string | null {
  switch (desc.trim().toLowerCase()) {
    case "cool":
    case "cooling":
    case "cold":
      return "cool";
    case "heat":
    case "heating":
    case "warm":
      return "heat";
    case "dry":
    case "dehumidify":
    case "dehumidification":
    case "dehumidifier":
      return "dry";
    case "fan":
    case "fan only":
    case "fan-only":
    case "fan_only":
    case "wind":
    case "ventilate":
      return "fan_only";
    case "auto":
    case "automatic":
    case "smart":
      return "auto";
    default:
      return null;
  }
}

export function parseMiotDeviceSpec(raw: unknown): MiotDeviceSpec | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const type = typeof obj["type"] === "string" ? obj["type"] : "";
  const rawServices = Array.isArray(obj["services"]) ? obj["services"] : null;
  if (!type || !rawServices) return null;

  const services: MiotService[] = [];
  for (const s of rawServices) {
    if (!s || typeof s !== "object") continue;
    const sObj = s as Record<string, unknown>;
    const sIid = typeof sObj["iid"] === "number" ? Math.trunc(sObj["iid"]) : NaN;
    const sType = typeof sObj["type"] === "string" ? sObj["type"] : "";
    if (!Number.isInteger(sIid) || !sType) continue;

    const rawProps = Array.isArray(sObj["properties"]) ? sObj["properties"] : [];
    const properties: MiotProperty[] = [];
    for (const p of rawProps) {
      if (!p || typeof p !== "object") continue;
      const pObj = p as Record<string, unknown>;
      const pIid = typeof pObj["iid"] === "number" ? Math.trunc(pObj["iid"]) : NaN;
      const pType = typeof pObj["type"] === "string" ? pObj["type"] : "";
      if (!Number.isInteger(pIid) || !pType) continue;
      const format = typeof pObj["format"] === "string" ? pObj["format"] : "string";
      const access = Array.isArray(pObj["access"])
        ? pObj["access"].filter((a): a is string => typeof a === "string")
        : [];
      const rawRange = pObj["value-range"] ?? pObj["valueRange"];
      const valueRange = Array.isArray(rawRange)
        ? rawRange.map((v) => Number(v)).filter((v) => Number.isFinite(v))
        : undefined;
      const rawList = pObj["value-list"] ?? pObj["valueList"];
      const valueList: MiotValueListItem[] | undefined = Array.isArray(rawList)
        ? rawList
            .filter((item): item is Record<string, unknown> => Boolean(item && typeof item === "object"))
            .map((item) => ({
              value: Math.trunc(Number(item["value"] ?? 0)),
              description: typeof item["description"] === "string" ? item["description"] : "",
            }))
        : undefined;

      properties.push({
        iid: pIid,
        type: pType,
        format,
        access,
        ...(valueRange ? { valueRange } : {}),
        ...(valueList ? { valueList } : {}),
      });
    }

    const rawActions = Array.isArray(sObj["actions"]) ? sObj["actions"] : [];
    const actions: MiotAction[] = [];
    for (const a of rawActions) {
      if (!a || typeof a !== "object") continue;
      const aObj = a as Record<string, unknown>;
      const aIid = typeof aObj["iid"] === "number" ? Math.trunc(aObj["iid"]) : NaN;
      const aType = typeof aObj["type"] === "string" ? aObj["type"] : "";
      if (Number.isInteger(aIid) && aType) {
        actions.push({ iid: aIid, type: aType });
      }
    }

    services.push({
      iid: sIid,
      type: sType,
      properties,
      actions,
    });
  }

  return { type, services };
}

export function parseMiotInstanceIndex(raw: unknown): Record<string, string> {
  if (!raw || typeof raw !== "object") return {};
  const instances = (raw as Record<string, unknown>)["instances"];
  if (!Array.isArray(instances)) return {};

  const bestVersion = new Map<string, { version: number; type: string }>();
  for (const item of instances) {
    if (!item || typeof item !== "object") continue;
    const rec = item as Record<string, unknown>;
    const model = typeof rec["model"] === "string" ? rec["model"] : "";
    const type = typeof rec["type"] === "string" ? rec["type"] : "";
    const version = typeof rec["version"] === "number" ? rec["version"] : 0;
    if (!model || !type) continue;
    const prev = bestVersion.get(model);
    if (!prev || version > prev.version) {
      bestVersion.set(model, { version, type });
    }
  }

  const out: Record<string, string> = {};
  for (const [model, info] of bestVersion.entries()) {
    out[model] = info.type;
  }
  return out;
}

export function inferFallbackSpec(record: Pick<MiDeviceRecord, "model" | "name">): MiotDeviceSpec {
  const m = record.model.toLowerCase();
  const n = record.name.toLowerCase();

  if (m.includes("light") || m.includes("lamp") || m.includes("bulb") || n.includes("灯")) {
    return {
      type: "urn:miot-spec-v2:device:light:0000A001:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read", "write"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:brightness:0000000D:fallback:1",
              format: "uint8",
              access: ["read", "write"],
              valueRange: [1, 100, 1],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:color-temperature:0000000F:fallback:1",
              format: "uint32",
              access: ["read", "write"],
              valueRange: [2700, 6500, 100],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (
    m.includes("aircondition") ||
    m.includes("acpartner") ||
    m.includes("heater") ||
    n.includes("空调") ||
    n.includes("取暖") ||
    n.includes("地暖")
  ) {
    return {
      type: "urn:miot-spec-v2:device:air-conditioner:0000A004:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-conditioner:0000780F:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read", "write"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:mode:00000008:fallback:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 2, description: "Cool" },
                { value: 5, description: "Heat" },
                { value: 3, description: "Dry" },
                { value: 4, description: "Fan" },
                { value: 1, description: "Auto" },
              ],
            },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:target-temperature:00000021:fallback:1",
              format: "float",
              access: ["read", "write"],
              valueRange: [16, 30, 0.5],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes(".fan.") || m.endsWith(".fan") || n.includes("风扇") || n.includes("循环扇")) {
    return {
      type: "urn:miot-spec-v2:device:fan:0000A005:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:fan:00007808:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read", "write"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:fan-level:00000016:fallback:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 1, description: "Level 1" },
                { value: 2, description: "Level 2" },
                { value: 3, description: "Level 3" },
                { value: 4, description: "Level 4" },
              ],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:horizontal-swing:00000017:fallback:1",
              format: "bool",
              access: ["read", "write"],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes("vacuum") || n.includes("扫地") || n.includes("扫拖")) {
    return {
      type: "urn:miot-spec-v2:device:vacuum:0000A006:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:vacuum:00007810:fallback:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:status:00000007:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 1, description: "Idle" },
                { value: 2, description: "Sweeping" },
                { value: 3, description: "Charging" },
                { value: 4, description: "Paused" },
                { value: 5, description: "Go Charging" },
              ],
            },
          ],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:start-sweep:00002804:fallback:1" },
            { iid: 2, type: "urn:miot-spec-v2:action:stop-sweeping:00002805:fallback:1" },
          ],
        },
      ],
    };
  }

  if (
    m.includes("sensor_ht") ||
    m.includes("temphum") ||
    m.includes("weather") ||
    n.includes("温湿度") ||
    n.includes("温度计")
  ) {
    return {
      type: "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "float", access: ["read"] },
            { iid: 2, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:fallback:1", format: "uint8", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
  }

  return {
    type: "urn:miot-spec-v2:device:outlet:0000A002:fallback:1",
    services: [
      {
        iid: 2,
        type: "urn:miot-spec-v2:service:switch:0000780C:fallback:1",
        properties: [
          { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read", "write"] },
        ],
        actions: [],
      },
    ],
  };
}

export class MiotSpecResolver {
  private readonly specByModel = new Map<string, MiotDeviceSpec>();
  private readonly specByType = new Map<string, MiotDeviceSpec>();
  private typeIndex: Record<string, string> | null = null;
  private indexPromise: Promise<Record<string, string>> | null = null;

  constructor(
    private readonly transport: HttpTransport,
    initialModelSpecs?: Readonly<Record<string, MiotDeviceSpec>>,
    initialModelTypes?: Readonly<Record<string, string>>,
  ) {
    if (initialModelSpecs) {
      for (const [m, s] of Object.entries(initialModelSpecs)) {
        this.specByModel.set(m, s);
      }
    }
    if (initialModelTypes && Object.keys(initialModelTypes).length > 0) {
      this.typeIndex = { ...initialModelTypes };
    }
  }

  exportCachedSpecs(): Record<string, MiotDeviceSpec> {
    const out: Record<string, MiotDeviceSpec> = {};
    for (const [k, v] of this.specByModel.entries()) {
      out[k] = v;
    }
    return out;
  }

  exportKnownModelTypes(models: readonly string[]): Record<string, string> {
    if (!this.typeIndex) return {};
    const out: Record<string, string> = {};
    for (const m of models) {
      const t = this.typeIndex[m];
      if (t) out[m] = t;
    }
    return out;
  }

  async resolveForDevices(devices: readonly MiDeviceRecord[]): Promise<Record<string, MiotDeviceSpec>> {
    const needsIndex = devices.some(
      (d) => !this.specByModel.has(d.model) && (!d.specType || d.specType.trim() === ""),
    );
    if (needsIndex) {
      await this.loadTypeIndex().catch(() => ({}));
    }

    await Promise.all(
      devices.map(async (dev) => {
        await this.resolve(dev);
      }),
    );

    return this.exportCachedSpecs();
  }

  async resolve(device: MiDeviceRecord): Promise<MiotDeviceSpec> {
    const existing = this.specByModel.get(device.model);
    if (existing) return existing;

    let urn = device.specType && device.specType.trim() !== "" ? device.specType.trim() : null;
    if (!urn) {
      const idx = await this.loadTypeIndex().catch(() => ({} as Record<string, string>));
      urn = idx[device.model] ?? null;
    }

    if (urn) {
      const fetched = await this.fetchInstance(urn);
      if (fetched) {
        this.specByModel.set(device.model, fetched);
        return fetched;
      }
    }

    const fallback = inferFallbackSpec(device);
    this.specByModel.set(device.model, fallback);
    return fallback;
  }

  private async loadTypeIndex(): Promise<Record<string, string>> {
    if (this.typeIndex && Object.keys(this.typeIndex).length > 100) {
      return this.typeIndex;
    }
    if (this.indexPromise) {
      return this.indexPromise;
    }
    this.indexPromise = (async () => {
      try {
        const resp = await this.transport({
          url: "https://miot-spec.org/miot-spec-v2/instances?status=released",
          method: "GET",
          timeoutMs: 45000,
        });
        if (resp.status === 200) {
          const parsed = parseMiotInstanceIndex(JSON.parse(resp.body));
          this.typeIndex = { ...(this.typeIndex ?? {}), ...parsed };
          return this.typeIndex;
        }
      } catch {
        // network fallback
      }
      return this.typeIndex ?? {};
    })();
    return this.indexPromise;
  }

  private async fetchInstance(urn: string): Promise<MiotDeviceSpec | null> {
    const cached = this.specByType.get(urn);
    if (cached) return cached;
    try {
      const resp = await this.transport({
        url: `https://miot-spec.org/miot-spec-v2/instance?type=${encodeURIComponent(urn)}`,
        method: "GET",
        timeoutMs: 15000,
      });
      if (resp.status !== 200) return null;
      const spec = parseMiotDeviceSpec(JSON.parse(resp.body));
      if (spec && spec.services.length > 0) {
        this.specByType.set(urn, spec);
        return spec;
      }
    } catch {
      // ignore instance fetch failure
    }
    return null;
  }
}

export const MiotSynthesizer = {
  synthesize(
    devices: readonly MiDeviceRecord[],
    rooms: readonly MiRoom[],
    specs: Readonly<Record<string, MiotDeviceSpec>>,
    values: ReadonlyMap<string, unknown>
  ): SynthesizedHome {
    const roomByDid = new Map<string, MiRoom>();
    for (const room of rooms) {
      for (const did of room.dids) {
        if (!roomByDid.has(did)) roomByDid.set(did, room);
      }
    }

    const smartDevices: SmartDevice[] = [];
    const readings: EnvironmentReading[] = [];

    for (const record of devices) {
      const spec = specs[record.model] ?? inferFallbackSpec(record);
      const built =
        this.buildDeviceKind(record.did, spec, values) ??
        this.buildDeviceKind(record.did, inferFallbackSpec(record), values);
      if (!built) continue;

      const room = roomByDid.get(record.did);
      const roomName = room?.name.trim() || "全屋";
      const roomId = room ? `room_${room.id}` : "other";

      smartDevices.push({
        id: record.did,
        name: record.name,
        roomId,
        roomName,
        model: record.model,
        isOnline: record.isOnline,
        kind: built,
      });

      if (built.kind === "sensor" && (built.temperature !== null || built.humidity !== null)) {
        readings.push({
          id: record.did,
          label: record.name.replace("温湿度计", "").trim() || roomName,
          roomName,
          temperature: built.temperature,
          humidity: built.humidity,
          battery: built.battery,
        });
      }
    }

    const roomCounts = new Map<string, { name: string; count: number }>();
    for (const dev of smartDevices) {
      const prev = roomCounts.get(dev.roomId);
      roomCounts.set(dev.roomId, {
        name: dev.roomName,
        count: (prev?.count ?? 0) + 1,
      });
    }
    const roomCategories: RoomCategory[] = Array.from(roomCounts.entries()).map(([id, info]) => ({
      id,
      name: info.name,
      deviceCount: info.count,
    }));

    return {
      devices: smartDevices,
      rooms: roomCategories,
      environmentReadings: readings,
      scenes: [],
    };
  },

  requiredProps(device: MiDeviceRecord, spec: MiotDeviceSpec): MiotPropKey[] {
    const touched: MiotPropKey[] = [];
    const seen = new Set<string>();
    const proxyValues = new Proxy(new Map<string, unknown>(), {
      get(target, prop) {
        if (prop === "get") {
          return (keyStr: string) => {
            if (!seen.has(keyStr)) {
              seen.add(keyStr);
              const parts = keyStr.split(".");
              const siid = Number(parts[parts.length - 2]);
              const piid = Number(parts[parts.length - 1]);
              const did = parts.slice(0, -2).join(".");
              touched.push({ did, siid, piid });
            }
            return target.get(keyStr);
          };
        }
        return Reflect.get(target, prop);
      },
    });
    this.buildDeviceKind(device.did, spec, proxyValues);
    return touched;
  },

  buildDeviceKind(
    did: string,
    spec: MiotDeviceSpec,
    values: ReadonlyMap<string, unknown>
  ): DeviceKind | null {
    const priority = [
      "air-conditioner",
      "heater",
      "thermostat",
      "light",
      "fan",
      "vacuum",
      "outlet",
      "switch",
      "temperature-humidity-sensor",
    ];
    const devShort = miotShortName(spec.type);
    let primaryService: MiotService | undefined = spec.services.find(
      (s) => miotShortName(s.type) === devShort && priority.includes(devShort)
    );
    if (!primaryService) {
      for (const p of priority) {
        const found = spec.services.find((s) => miotShortName(s.type) === p);
        if (found) {
          primaryService = found;
          break;
        }
      }
    }
    if (!primaryService && devShort.endsWith("sensor")) {
      primaryService = spec.services.find((s) => miotShortName(s.type) === "environment");
    }
    if (!primaryService) {
      primaryService = spec.services.find((s) =>
        s.properties.some((p) => miotShortName(p.type) === "on" && p.access.includes("write"))
      );
    }
    if (!primaryService) return null;

    const readProp = (s: MiotService, short: string) => {
      const prop = s.properties.find((p) => miotShortName(p.type) === short && p.access.includes("read"));
      if (!prop) return null;
      const val = values.get(propKeyString({ did, siid: s.iid, piid: prop.iid }));
      return { prop, val };
    };

    const sName = miotShortName(primaryService.type);
    if (sName === "light") {
      const on = readProp(primaryService, "on");
      const bri = readProp(primaryService, "brightness");
      const ct = readProp(primaryService, "color-temperature");
      const mode = readProp(primaryService, "mode");
      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const currentEffect =
        modeVal !== null
          ? (mode?.prop.valueList?.find((i) => i.value === modeVal)?.description ?? null)
          : null;
      const briNum = typeof bri?.val === "number" ? bri.val : null;
      const maxBri = bri?.prop.valueRange?.[1] ?? 100;
      const briPct =
        briNum !== null
          ? Math.max(0, Math.min(100, Math.round(maxBri > 0 && maxBri !== 100 ? (briNum / maxBri) * 100 : briNum)))
          : null;

      return {
        kind: "light",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: Boolean(on?.val),
        brightnessPercent: briPct,
        colorTempKelvin: typeof ct?.val === "number" ? Math.round(ct.val) : null,
        minKelvin: Math.round(ct?.prop.valueRange?.[0] ?? 2700),
        maxKelvin: Math.round(ct?.prop.valueRange?.[1] ?? 6500),
        currentEffect,
        availableEffects: mode?.prop.valueList?.map((i) => i.description) ?? [],
      };
    }

    if (sName === "air-conditioner" || sName === "heater" || sName === "thermostat") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const target = readProp(primaryService, "target-temperature");
      const envSvc = spec.services.find(
        (s) => miotShortName(s.type) === "environment" || miotShortName(s.type) === "temperature-humidity-sensor"
      );
      const current = readProp(primaryService, "temperature") ?? (envSvc ? readProp(envSvc, "temperature") : null);
      const fanSvc = spec.services.find((s) => miotShortName(s.type) === "fan-control");
      const fanLevel = (fanSvc ? readProp(fanSvc, "fan-level") : null) ?? readProp(primaryService, "fan-level");

      const isOn = Boolean(on?.val);
      const haModes: string[] = [];
      for (const item of mode?.prop.valueList ?? []) {
        const mapped = hvacModeFromDescription(item.description);
        if (mapped && !haModes.includes(mapped)) haModes.push(mapped);
      }
      if (haModes.length === 0) haModes.push(sName === "air-conditioner" ? "cool" : "heat");
      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const rawDesc = modeVal !== null ? mode?.prop.valueList?.find((i) => i.value === modeVal)?.description : null;
      const activeMode = (rawDesc ? hvacModeFromDescription(rawDesc) : null) ?? haModes[0] ?? "cool";
      const fanVal = typeof fanLevel?.val === "number" ? Math.trunc(fanLevel.val) : null;
      const fanDesc =
        fanVal !== null ? (fanLevel?.prop.valueList?.find((i) => i.value === fanVal)?.description ?? null) : null;

      return {
        kind: "climate",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn,
        hvacMode: isOn ? activeMode : "off",
        availableModes: [...haModes, "off"],
        targetTemperature: typeof target?.val === "number" ? target.val : 26,
        currentTemperature: typeof current?.val === "number" ? current.val : null,
        minTemp: target?.prop.valueRange?.[0] ?? 16,
        maxTemp: target?.prop.valueRange?.[1] ?? 30,
        step: target?.prop.valueRange?.[2] ?? 1,
        fanMode: fanDesc,
        availableFanModes: fanLevel?.prop.valueList?.map((i) => i.description) ?? [],
      };
    }

    if (sName === "fan") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const level = readProp(primaryService, "fan-level");
      const swing = readProp(primaryService, "horizontal-swing");
      const presetRef = (mode?.prop.valueList?.length ?? 0) > 0 ? mode : level;
      const presetVal = typeof presetRef?.val === "number" ? Math.trunc(presetRef.val) : null;
      const presetDesc =
        presetVal !== null
          ? (presetRef?.prop.valueList?.find((i) => i.value === presetVal)?.description ?? null)
          : null;

      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: Boolean(on?.val),
        percentage: null,
        presetMode: presetDesc,
        availablePresetModes: presetRef?.prop.valueList?.map((i) => i.description) ?? [],
        isOscillating: typeof swing?.val === "boolean" ? swing.val : null,
      };
    }

    if (sName === "vacuum") {
      const status = readProp(primaryService, "status");
      const batSvc = spec.services.find((s) => miotShortName(s.type) === "battery") ?? primaryService;
      const battery = readProp(batSvc, "battery-level");
      const statusVal = typeof status?.val === "number" ? Math.trunc(status.val) : null;
      const statusDesc =
        statusVal !== null
          ? (status?.prop.valueList?.find((i) => i.value === statusVal)?.description?.toLowerCase() ?? "")
          : "";
      let normalizedStatus = "idle";
      if (statusDesc.includes("return") || statusDesc.includes("go charging")) normalizedStatus = "returning";
      else if (statusDesc.includes("paus")) normalizedStatus = "paused";
      else if (statusDesc.includes("sweep") || statusDesc.includes("clean") || statusDesc.includes("working"))
        normalizedStatus = "cleaning";
      else if (statusDesc.includes("charg") || statusDesc.includes("dock")) normalizedStatus = "docked";

      return {
        kind: "vacuum",
        entityId: makeMiotAddress(did, primaryService.iid),
        status: normalizedStatus,
        battery: typeof battery?.val === "number" ? Math.round(battery.val) : null,
        modeEntityId: null,
        currentMode: null,
        availableModes: [],
      };
    }

    if (sName === "temperature-humidity-sensor" || sName === "environment") {
      const temp = readProp(primaryService, "temperature");
      const hum = readProp(primaryService, "relative-humidity");
      const batSvc = spec.services.find((s) => miotShortName(s.type) === "battery");
      const battery = batSvc ? readProp(batSvc, "battery-level") : null;
      return {
        kind: "sensor",
        temperature: typeof temp?.val === "number" ? temp.val : null,
        humidity: typeof hum?.val === "number" ? hum.val : null,
        battery: typeof battery?.val === "number" ? Math.round(battery.val) : null,
      };
    }

    if (
      sName === "outlet" ||
      sName === "switch" ||
      primaryService.properties.some((p) => miotShortName(p.type) === "on")
    ) {
      const on = readProp(primaryService, "on");
      const pwrSvc = spec.services.find((s) => miotShortName(s.type) === "power-consumption") ?? primaryService;
      const power = readProp(pwrSvc, "electric-power");
      const lockSvc = spec.services.find((s) => miotShortName(s.type) === "physical-controls-locked");
      const lock = lockSvc ? readProp(lockSvc, "physical-controls-locked") : null;

      return {
        kind: "plug",
        switchEntityId: makeMiotAddress(did, primaryService.iid),
        isOn: Boolean(on?.val),
        powerWatts: typeof power?.val === "number" ? power.val : null,
        childLockEntityId: lockSvc ? makeMiotAddress(did, lockSvc.iid) : null,
        isChildLocked: Boolean(lock?.val),
      };
    }

    return null;
  },
};

export type MiotWrite =
  | { readonly kind: "setProps"; readonly writes: readonly MiotPropWrite[] }
  | { readonly kind: "action"; readonly call: MiotActionCall };

export const MiotCommandMapper = {
  map(command: DeviceCommand, spec: MiotDeviceSpec): MiotWrite {
    const addr = parseMiotAddress(command.entityId);
    if (!addr) throw new Error(`Invalid MIoT address: ${command.entityId}`);
    const service = spec.services.find((s) => s.iid === addr.siid);
    if (!service) throw new Error(`Service ${addr.siid} not found`);

    const findProp = (short: string, searchAll = false) => {
      const local = service.properties.find((p) => miotShortName(p.type) === short && p.access.includes("write"));
      if (local) return { service, prop: local };
      if (searchAll) {
        for (const s of spec.services) {
          const p = s.properties.find((pr) => miotShortName(pr.type) === short && pr.access.includes("write"));
          if (p) return { service: s, prop: p };
        }
      }
      throw new Error(`Unsupported property: ${short}`);
    };

    const coerce = (prop: MiotProperty, val: number): number => {
      let n = val;
      if (prop.valueRange && prop.valueRange.length >= 2) {
        const lo = prop.valueRange[0] ?? n;
        const hi = prop.valueRange[1] ?? n;
        n = Math.min(hi, Math.max(lo, n));
      }
      if (prop.format.startsWith("int") || prop.format.startsWith("uint")) {
        return Math.round(n);
      }
      const step = prop.valueRange?.[2];
      if (step && step > 0) {
        const base = prop.valueRange?.[0] ?? 0;
        n = base + Math.round((n - base) / step) * step;
      }
      return n;
    };

    const powerOnPrefix = (): MiotPropWrite[] => {
      const onP = service.properties.find((p) => miotShortName(p.type) === "on" && p.access.includes("write"));
      return onP ? [{ did: addr.did, siid: service.iid, piid: onP.iid, value: true }] : [];
    };

    switch (command.kind) {
      case "setLightPower":
      case "setClimatePower":
      case "setFanPower": {
        const { prop } = findProp("on");
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: command.isOn }],
        };
      }
      case "setLightBrightness": {
        if (command.percent <= 0) {
          const { prop } = findProp("on");
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: false }],
          };
        }
        const { prop } = findProp("brightness");
        const max = prop.valueRange?.[1] ?? 100;
        const raw = max > 0 && max !== 100 ? (command.percent / 100) * max : command.percent;
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, raw) },
          ],
        };
      }
      case "setLightColorTemp": {
        const { prop } = findProp("color-temperature");
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, command.kelvin) },
          ],
        };
      }
      case "setLightEffect": {
        const { prop } = findProp("mode");
        const item = prop.valueList?.find(
          (i) => i.description.toLowerCase() === command.effect.toLowerCase()
        );
        if (!item) throw new Error(`Unsupported effect: ${command.effect}`);
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: service.iid, piid: prop.iid, value: item.value },
          ],
        };
      }
      case "setClimateMode": {
        const { prop: onProp } = findProp("on");
        if (command.hvacMode === "off") {
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: onProp.iid, value: false }],
          };
        }
        const writes: MiotPropWrite[] = [
          { did: addr.did, siid: service.iid, piid: onProp.iid, value: true },
        ];
        const modeProp = service.properties.find(
          (p) => miotShortName(p.type) === "mode" && p.access.includes("write")
        );
        const item = modeProp?.valueList?.find(
          (i) => hvacModeFromDescription(i.description) === command.hvacMode
        );
        if (modeProp && item) {
          writes.push({ did: addr.did, siid: service.iid, piid: modeProp.iid, value: item.value });
        }
        return { kind: "setProps", writes };
      }
      case "setClimateTemperature": {
        const { prop } = findProp("target-temperature");
        return {
          kind: "setProps",
          writes: [
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, command.temperature) },
          ],
        };
      }
      case "setClimateFanMode": {
        const found = findProp("fan-level", true);
        const item = found.prop.valueList?.find(
          (i) => i.description.toLowerCase() === command.fanMode.toLowerCase()
        );
        if (!item) throw new Error(`Unsupported fan mode: ${command.fanMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: item.value }],
        };
      }
      case "setFanPresetMode": {
        const modeProp = service.properties.find(
          (p) => miotShortName(p.type) === "mode" && p.access.includes("write")
        );
        const modeItem = modeProp?.valueList?.find(
          (i) => i.description.toLowerCase() === command.presetMode.toLowerCase()
        );
        if (modeProp && modeItem) {
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: modeProp.iid, value: modeItem.value }],
          };
        }
        const { prop: levelProp } = findProp("fan-level");
        const levelItem = levelProp.valueList?.find(
          (i) => i.description.toLowerCase() === command.presetMode.toLowerCase()
        );
        if (!levelItem) throw new Error(`Unsupported preset: ${command.presetMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: levelProp.iid, value: levelItem.value }],
        };
      }
      case "setFanOscillating": {
        const { prop } = findProp("horizontal-swing");
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: command.oscillating }],
        };
      }
      case "setSwitch": {
        const onProp = service.properties.find(
          (p) => miotShortName(p.type) === "on" && p.access.includes("write")
        );
        const targetProp = onProp ?? findProp("physical-controls-locked").prop;
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: targetProp.iid, value: command.isOn }],
        };
      }
      case "vacuumAction": {
        const candidates =
          command.action === "start"
            ? ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"]
            : command.action === "pause"
              ? ["pause-sweeping", "pause", "stop-sweeping", "stop-clean"]
              : ["start-charge", "stop-and-gocharge", "return-to-charge", "go-charging"];
        for (const name of candidates) {
          for (const s of [service, ...spec.services.filter((sv) => sv.iid !== service.iid)]) {
            const act = s.actions.find((a) => miotShortName(a.type) === name);
            if (act) {
              return {
                kind: "action",
                call: { did: addr.did, siid: s.iid, aiid: act.iid, inputs: [] },
              };
            }
          }
        }
        throw new Error(`Unsupported vacuum action: ${command.action}`);
      }
      case "activateScene":
        throw new Error("Scenes are not Miot device properties");
      default: {
        const _exhaustive: never = command;
        return _exhaustive;
      }
    }
  },
};
