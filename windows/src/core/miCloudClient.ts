import { MiCloudCrypto } from "./miCloudCrypto.js";
import {
  deviceEnvironmentReading,
  environmentReadingPriority,
  type DeviceCommand,
  type DeviceKind,
  type EnvironmentReading,
  type RoomCategory,
  type SmartDevice,
  type SynthesizedHome,
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

export interface MiCloudRegionOption {
  /** Xiaomi cloud region code, used as the API subdomain (`<code>.api.io.mi.com`). */
  readonly code: string;
  /** Label shown in the region dropdown. */
  readonly label: string;
}

/**
 * Xiaomi cloud regions offered by both apps (#37). Order and membership are shared with
 * macOS: Tests/Fixtures/region_golden.json is the single source of truth and both ends'
 * tests assert against it (macOS `MiCloudRegion.allCases`, Windows `MI_CLOUD_REGIONS`).
 */
export const MI_CLOUD_REGIONS: ReadonlyArray<MiCloudRegionOption> = [
  { code: "cn", label: "中国大陆 (cn)" },
  { code: "de", label: "欧洲 (de)" },
  { code: "i2", label: "印度 (i2)" },
  { code: "ru", label: "俄罗斯 (ru)" },
  { code: "sg", label: "新加坡 / 国际 (sg)" },
  { code: "us", label: "美区 (us)" },
];

/** Falls back to China Mainland for unknown/missing values coming from older settings. */
export function normalizeMiCloudRegion(raw: unknown): string {
  if (typeof raw !== "string") return "cn";
  const code = raw.trim().toLowerCase();
  return MI_CLOUD_REGIONS.some((region) => region.code === code) ? code : "cn";
}

export function miCloudRegionLabel(code: string): string {
  const normalized = normalizeMiCloudRegion(code);
  return MI_CLOUD_REGIONS.find((region) => region.code === normalized)?.label ?? normalized;
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
  /** Split key of a multi-key panel (did like `<parent>.s2`): MIoT calls go to the parent did, switch service `splitSiid`. */
  readonly splitParentDid?: string | null;
  readonly splitSiid?: number | null;
}

/** The did MIoT property and action calls address. */
export function miotDid(record: MiDeviceRecord): string {
  return record.splitParentDid ?? record.did;
}

/** Narrows a panel spec to the switch service a split key controls. */
function specForRecord(record: MiDeviceRecord, spec: MiotDeviceSpec): MiotDeviceSpec {
  if (!record.splitParentDid || record.splitSiid == null) return spec;
  return { ...spec, services: spec.services.filter((s) => s.iid === record.splitSiid) };
}

export interface MiRoom {
  readonly id: string;
  readonly name: string;
  readonly dids: readonly string[];
  readonly homeId?: string;
  readonly homeName?: string;
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
      const extra = rec["extra"] && typeof rec["extra"] === "object" ? (rec["extra"] as Record<string, unknown>) : {};
      const split = extra["split"] && typeof extra["split"] === "object" ? (extra["split"] as Record<string, unknown>) : null;
      const splitParentDid = split ? asIdString(split["parentId"]) : null;
      const splitSiid = split && typeof split["moduleId"] === "number" ? Math.trunc(split["moduleId"]) : null;
      out.push({
        did,
        name: typeof rec["name"] === "string" ? rec["name"] : model,
        model,
        isOnline: typeof rec["isOnline"] === "boolean" ? rec["isOnline"] : true,
        specType: typeof rec["spec_type"] === "string" ? rec["spec_type"] : null,
        ...(splitParentDid && splitSiid !== null ? { splitParentDid, splitSiid } : {}),
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
      const h = home as Record<string, unknown>;
      const homeId = asIdString(h["id"]) ?? "";
      const homeName = typeof h["name"] === "string" ? h["name"] : "";
      const roomlist = h["roomlist"];
      if (Array.isArray(roomlist)) {
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
            homeId,
            homeName,
          });
        }
      }
      const homeDids = Array.isArray(h["dids"])
        ? h["dids"].map(asIdString).filter((d): d is string => d !== null)
        : [];
      if (homeId && homeDids.length > 0) {
        rooms.push({ id: `home_${homeId}`, name: "", dids: homeDids, homeId, homeName });
      }
    }
    return rooms;
  }

  /**
   * `v2/home/device_list_page` also returns the split keys of multi-key Mesh panels, which
   * `home/device_list` omits even with `get_split_device`; fall back to the latter on failure.
   */
  async deviceList(): Promise<MiDeviceRecord[]> {
    try {
      return await this.deviceListPaged();
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      return this.legacyDeviceList();
    }
  }

  private async deviceListPaged(): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    let startDid = "";
    for (let page = 0; page < 20; page++) {
      const data: Record<string, unknown> = { get_split_device: true, support_smart_home: true, limit: 200 };
      if (startDid) data["start_did"] = startDid;
      const res = await this.request("v2/home/device_list_page", data);
      records.push(...MiCloudClient.parseDeviceList(res));
      const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
      const next = asIdString(obj["next_start_did"]) ?? "";
      if (obj["has_more"] !== true || !next || next === startDid) break;
      startDid = next;
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  private async legacyDeviceList(): Promise<MiDeviceRecord[]> {
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
    await this.callAction(call);
  }

  async callAction(call: MiotActionCall): Promise<unknown> {
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
    return result;
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
  readonly unit?: string;
  readonly comment?: string;
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

      const unit = typeof pObj["unit"] === "string" ? pObj["unit"] : undefined;
      const comment = typeof pObj["comment"] === "string" ? pObj["comment"] : undefined;

      properties.push({
        iid: pIid,
        type: pType,
        format,
        access,
        ...(valueRange ? { valueRange } : {}),
        ...(valueList ? { valueList } : {}),
        ...(unit !== undefined ? { unit } : {}),
        ...(comment !== undefined ? { comment } : {}),
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

  if (
    m.includes("airp") ||
    m.includes("airpurifier") ||
    n.includes("净化器") ||
    n.includes("空净")
  ) {
    return {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read", "write"] },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:mode:00000008:fallback:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Auto" },
                { value: 1, description: "Sleep" },
                { value: 2, description: "Favorite" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:fallback:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
            { iid: 4, type: "urn:miot-spec-v2:property:pm2.5-density:00000034:fallback:1", format: "uint16", access: ["read"], valueRange: [0, 1000, 1] },
            { iid: 7, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "float", access: ["read"], valueRange: [-30, 100, 1] },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:filter:0000780B:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:filter-life-level:0000001E:fallback:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
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
    m.includes("camera") ||
    m.includes("cateye") ||
    m.includes("doorbell") ||
    n.includes("摄像") ||
    n.includes("监控") ||
    n.includes("猫眼")
  ) {
    return {
      type: "urn:miot-spec-v2:device:camera:0000A01C:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:fallback:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:on:00000006:fallback:1",
              format: "bool",
              access: ["read", "write"],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:night-shot:00000057:fallback:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Off" },
                { value: 1, description: "On" },
                { value: 2, description: "Auto" },
              ],
            },
          ],
          actions: [],
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

function miotBool(val: unknown): boolean | null {
  if (typeof val === "boolean") return val;
  if (typeof val === "number") return val !== 0;
  return null;
}

function hasScaleToken(comment: string, token: string): boolean {
  let idx = comment.indexOf(token);
  while (idx !== -1) {
    const prev = idx > 0 ? comment[idx - 1]! : "";
    if (!((prev >= "0" && prev <= "9") || prev === ".")) {
      return true;
    }
    idx = comment.indexOf(token, idx + token.length);
  }
  return false;
}

/**
 * Scale factor that converts a MIoT `power-consumption` reading into kWh (#62).
 * Returns `null` when an integer property has neither a recognized `unit` nor an explicit
 * scale in `comment` (e.g. "0.01kwh"), so ambiguous raw integers are never guessed.
 */
function energyScale(prop: MiotProperty): number | null {
  const unit = (prop.unit ?? "")
    .trim()
    .toLowerCase()
    .replaceAll(",", ".")
    .replaceAll(" ", "");
  const comment = (prop.comment ?? "")
    .toLowerCase()
    .replaceAll(",", ".")
    .replaceAll(" ", "");
  if (unit === "wh" || unit === "watt-hour" || unit === "0.001kwh" || hasScaleToken(comment, "0.001kwh")) {
    return 0.001;
  }
  if (unit === "0.01kwh" || hasScaleToken(comment, "0.01kwh")) {
    return 0.01;
  }
  if (unit === "kwh" || unit === "kilowatt-hour" || unit === "1kwh" || hasScaleToken(comment, "1kwh")) {
    return 1.0;
  }
  if (prop.format === "float" && (unit === "" || unit === "none")) {
    return 1.0;
  }
  return null;
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

    // A panel whose keys are listed as split devices is shown through those keys only.
    const splitParents = new Set(devices.map((d) => d.splitParentDid).filter((d): d is string => !!d));

    const smartDevices: SmartDevice[] = [];
    const readings: EnvironmentReading[] = [];

    for (const record of devices) {
      if (splitParents.has(record.did)) continue;
      // A real spec that yields no builder means the category is unsupported — drop the
      // device (macOS parity). The offline fallback spec applies only when no real spec
      // was fetched at all; re-falling back here would re-admit devices the guard rejected.
      const spec = specs[record.model] ?? inferFallbackSpec(record);
      const built = record.splitParentDid
        ? this.buildDeviceKind(miotDid(record), specForRecord(record, spec), values)
        : this.buildDeviceKind(record.did, spec, values);
      if (!built) continue;

      const room =
        roomByDid.get(record.did) ??
        (record.splitParentDid ? roomByDid.get(record.splitParentDid) : undefined);
      const roomName = room?.name.trim() || "全屋";
      const roomId = room ? `room_${room.id}` : "other";

      const smartDevice: SmartDevice = {
        id: record.did,
        name: record.name,
        roomId,
        roomName,
        model: record.model,
        isOnline: record.isOnline,
        kind: built,
      };
      smartDevices.push(smartDevice);

      const reading = deviceEnvironmentReading(smartDevice);
      if (reading) {
        readings.push(reading);
      }
    }

    const roomOrderByName = new Map<string, number>();
    rooms.forEach((r, idx) => {
      const name = r.name.trim() || "全屋";
      if (!roomOrderByName.has(name)) roomOrderByName.set(name, idx);
    });
    const firstSeenRoom = new Map<string, number>();
    for (const d of smartDevices) {
      if (!firstSeenRoom.has(d.roomName)) firstSeenRoom.set(d.roomName, firstSeenRoom.size);
    }
    const fallbackBase = roomOrderByName.size + 1;
    const roomOrder = (name: string): number =>
      roomOrderByName.get(name) ?? fallbackBase + (firstSeenRoom.get(name) ?? 999);
    const priorityById = new Map<string, number>(
      smartDevices.map((d) => [d.id, environmentReadingPriority(d.kind)])
    );
    readings.sort((a, b) => {
      const pa = priorityById.get(a.id) ?? 0;
      const pb = priorityById.get(b.id) ?? 0;
      if (pa !== pb) return pa - pb;
      const ra = roomOrder(a.roomName);
      const rb = roomOrder(b.roomName);
      if (ra !== rb) return ra - rb;
      return a.label < b.label ? -1 : a.label > b.label ? 1 : 0;
    });

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
    this.buildDeviceKind(miotDid(device), specForRecord(device, spec), proxyValues);
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
      "air-purifier",
      "video-doorbell",
      "vacuum",
      "camera-control",
      "outlet",
      "switch",
      "temperature-humidity-sensor",
    ];
    const devShort = miotShortName(spec.type);
    const preferredServices =
      devShort === "outlet"
        ? ["outlet", "switch"]
        : devShort === "camera" || devShort === "cateye" || devShort === "video-doorbell"
          ? ["camera-control", "video-doorbell"]
          : [devShort];
    let primaryService: MiotService | undefined = spec.services.find((s) => {
      const sShort = miotShortName(s.type);
      return preferredServices.includes(sShort) && priority.includes(sShort);
    });
    if (!primaryService) {
      for (const p of priority) {
        // A secondary `light` service must not claim devices whose own type is something
        // else (hood / airer / bath-heater / ceiling-fan / gateway), or those cards become
        // bare lamps that only toggle their lamp while the primary function stays hidden.
        if (p === "light" && devShort !== "light" && !devShort.includes("light") && !devShort.includes("lamp")) {
          continue;
        }
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
    if (
      !primaryService &&
      // If the spec names a service of its own device type we simply do not support that
      // category yet — claiming the first writable `on` as a plug would fake a device
      // (hood/airer would show up as an outlet).
      !spec.services.some((s) => miotShortName(s.type) === devShort)
    ) {
      // Only genuine plug-like services may fall back to a plug card. macOS has no
      // generic-on fallback at all, so accepting e.g. a bath-heater's `ptc-bath-heater`
      // or `light` service here would fake a device the other platform drops (#98).
      primaryService = spec.services.find(
        (s) =>
          ["outlet", "switch"].includes(miotShortName(s.type)) &&
          s.properties.some((p) => miotShortName(p.type) === "on" && p.access.includes("write"))
      );
    }
    if (!primaryService) return null;

    const readProp = (s: MiotService, short: string, predicate?: (p: MiotProperty) => boolean) => {
      const prop = s.properties.find(
        (p) => miotShortName(p.type) === short && p.access.includes("read") && (!predicate || predicate(p))
      );
      if (!prop) return null;
      const val = values.get(propKeyString({ did, siid: s.iid, piid: prop.iid }));
      return { service: s, prop, val };
    };

    const readProps = (s: MiotService, short: string) =>
      s.properties
        .filter((p) => miotShortName(p.type) === short && p.access.includes("read"))
        .map((prop) => ({
          service: s,
          prop,
          val: values.get(propKeyString({ did, siid: s.iid, piid: prop.iid })),
        }));

    const readFirst = (services: readonly MiotService[], short: string, predicate?: (p: MiotProperty) => boolean) => {
      const seen = new Set<number>();
      for (const s of services) {
        if (seen.has(s.iid)) continue;
        seen.add(s.iid);
        const found = readProp(s, short, predicate);
        if (found) return found;
      }
      return null;
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

      const isLightGroup = did.startsWith("group.");
      return {
        kind: "light",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        brightnessPercent: briPct,
        colorTempKelvin: typeof ct?.val === "number" ? Math.round(ct.val) : null,
        minKelvin: Math.round(ct?.prop.valueRange?.[0] ?? 2700),
        maxKelvin: Math.round(ct?.prop.valueRange?.[1] ?? 6500),
        currentEffect: isLightGroup ? null : currentEffect,
        availableEffects: isLightGroup ? [] : (mode?.prop.valueList?.map((i) => i.description) ?? []),
      };
    }

    if (sName === "air-conditioner" || sName === "heater" || sName === "thermostat") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const target = readProp(primaryService, "target-temperature");
      const current = readFirst(
        [
          primaryService,
          ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
          ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
        ],
        "temperature"
      );
      const fanLevel = readFirst(
        [...spec.services.filter((s) => miotShortName(s.type) === "fan-control"), primaryService],
        "fan-level"
      );

      const isOn = miotBool(on?.val) ?? false;
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
      const levels = readProps(primaryService, "fan-level");
      const swing = readProp(primaryService, "horizontal-swing");
      const percentRef = levels.find((r) => r.prop.valueRange !== undefined);
      const presetRef =
        (mode?.prop.valueList?.length ?? 0) > 0
          ? mode
          : levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);
      const pctNum = typeof percentRef?.val === "number" ? percentRef.val : null;
      const maxPct = percentRef?.prop.valueRange?.[1] ?? 100;
      const percentage =
        pctNum !== null
          ? Math.max(
              0,
              Math.min(100, Math.round(maxPct > 0 && maxPct !== 100 ? (pctNum / maxPct) * 100 : pctNum))
            )
          : null;
      const presetVal = typeof presetRef?.val === "number" ? Math.trunc(presetRef.val) : null;
      const presetDesc =
        presetVal !== null
          ? (presetRef?.prop.valueList?.find((i) => i.value === presetVal)?.description ?? null)
          : null;

      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        percentage,
        presetMode: presetDesc,
        availablePresetModes: presetRef?.prop.valueList?.map((i) => i.description) ?? [],
        isOscillating: miotBool(swing?.val),
      };
    }

    if (sName === "air-purifier") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const levels = readProps(primaryService, "fan-level");
      const favServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
        ...spec.services.filter((s) => miotShortName(s.type) === "motor-speed"),
        ...spec.services.filter((s) => miotShortName(s.type) === "custom-service"),
        ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
      ];
      const favSpeed =
        readFirst(favServices, "fan-level") ??
        readFirst(favServices, "favorite-fan-level") ??
        readFirst(favServices, "favorite-level") ??
        readFirst(favServices, "favorite-speed");
      const speedRef =
        favSpeed ??
        levels.find((r) => r.prop.valueRange !== undefined) ??
        levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);
      const presetRef =
        (mode?.prop.valueList?.length ?? 0) > 0
          ? mode
          : levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);

      let percentage: number | null = null;
      if (speedRef && typeof speedRef.val === "number") {
        const raw = speedRef.val;
        const range = speedRef.prop.valueRange;
        const list = speedRef.prop.valueList;
        let scaled = raw;
        if (range && range.length >= 2 && (range[1] ?? 0) > (range[0] ?? 0)) {
          const lo = range[0] ?? 0;
          const hi = range[1] ?? 100;
          scaled = lo > 1 ? ((raw - lo) / (hi - lo)) * 100 : hi !== 100 ? (raw / hi) * 100 : raw;
        } else if (list && list.length > 0) {
          const vals = list.map((i) => i.value);
          const lo = Math.min(...vals);
          const hi = Math.max(...vals);
          if (hi > lo) {
            scaled = lo > 1 ? ((raw - lo) / (hi - lo)) * 100 : (raw / hi) * 100;
          }
        }
        percentage = Math.max(0, Math.min(100, Math.round(scaled)));
      }

      const presetVal = typeof presetRef?.val === "number" ? Math.trunc(presetRef.val) : null;
      const presetDesc =
        presetVal !== null
          ? (presetRef?.prop.valueList?.find((i) => i.value === presetVal)?.description ?? null)
          : null;

      const envServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
        ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
        primaryService,
      ];
      const pm25 = readFirst(envServices, "pm2.5-density");
      const aq = readFirst(envServices, "air-quality");
      const temp = readFirst(envServices, "temperature");
      const hum = readFirst(envServices, "relative-humidity");
      const filterServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "filter"),
        primaryService,
      ];
      const filterLife = readFirst(filterServices, "filter-life-level");

      const pm25Density = typeof pm25?.val === "number" ? Math.round(pm25.val) : null;
      const aqVal = typeof aq?.val === "number" ? Math.trunc(aq.val) : null;
      const airQuality =
        aqVal !== null
          ? (aq?.prop.valueList?.find((i) => i.value === aqVal)?.description ?? null)
          : null;
      const temperature = typeof temp?.val === "number" ? temp.val : null;
      const humidity = typeof hum?.val === "number" ? hum.val : null;
      const filterLifePercent = typeof filterLife?.val === "number" ? Math.round(filterLife.val) : null;

      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        percentage,
        presetMode: presetDesc,
        availablePresetModes: presetRef?.prop.valueList?.map((i) => i.description) ?? [],
        isOscillating: null,
        ...(pm25Density !== null ? { pm25Density } : {}),
        ...(airQuality !== null ? { airQuality } : {}),
        ...(temperature !== null ? { temperature } : {}),
        ...(humidity !== null ? { humidity } : {}),
        ...(filterLifePercent !== null ? { filterLifePercent } : {}),
      };
    }

    if (sName === "vacuum") {
      const status = readProp(primaryService, "status");
      const mode = readProp(primaryService, "mode");
      const battery = readFirst(
        [...spec.services.filter((s) => miotShortName(s.type) === "battery"), primaryService],
        "battery-level"
      );
      const statusVal = typeof status?.val === "number" ? Math.trunc(status.val) : null;
      const statusDesc =
        statusVal !== null
          ? (status?.prop.valueList?.find((i) => i.value === statusVal)?.description?.toLowerCase() ?? "")
          : "";
      let normalizedStatus = "idle";
      if (
        statusDesc.includes("go charging") ||
        statusDesc.includes("returning") ||
        statusDesc.includes("go home") ||
        statusDesc.includes("back to") ||
        statusDesc.includes("recharge")
      ) {
        normalizedStatus = "returning";
      } else if (statusDesc.includes("paus")) {
        normalizedStatus = "paused";
      } else if (
        statusDesc.includes("sweep") ||
        statusDesc.includes("clean") ||
        statusDesc.includes("mop") ||
        statusDesc.includes("working") ||
        statusDesc.includes("busy")
      ) {
        normalizedStatus = "cleaning";
      } else if (statusDesc.includes("charg") || statusDesc.includes("dock") || statusDesc.includes("full")) {
        normalizedStatus = "docked";
      }

      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const currentMode =
        modeVal !== null
          ? (mode?.prop.valueList?.find((i) => i.value === modeVal)?.description ?? null)
          : null;

      return {
        kind: "vacuum",
        entityId: makeMiotAddress(did, primaryService.iid),
        status: normalizedStatus,
        battery: typeof battery?.val === "number" ? Math.round(battery.val) : null,
        modeEntityId: mode ? makeMiotAddress(did, mode.service.iid) : null,
        currentMode,
        availableModes: mode?.prop.valueList?.map((i) => i.description) ?? [],
      };
    }

    if (sName === "camera-control" || sName === "video-doorbell") {
      const on = readProp(primaryService, "on");
      const nightShot = readProp(primaryService, "night-shot");
      const motionSvc = spec.services.find((s) => miotShortName(s.type) === "motion-detection");
      const motion = motionSvc ? readProp(motionSvc, "motion-detection") : null;
      const streamSvc = spec.services.find(
        (s) =>
          miotShortName(s.type) === "camera-stream-for-google-home" &&
          s.actions.some((a) => miotShortName(a.type) === "start-hls-stream")
      );
      const nightVal = typeof nightShot?.val === "number" ? Math.trunc(nightShot.val) : null;
      const currentNightShot =
        nightVal !== null
          ? (nightShot?.prop.valueList?.find((i) => i.value === nightVal)?.description ?? null)
          : null;

      return {
        kind: "camera",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        nightShot: currentNightShot,
        availableNightShots: nightShot?.prop.valueList?.map((i) => i.description) ?? [],
        motionDetectionEntityId: motion ? makeMiotAddress(did, motion.service.iid) : null,
        isMotionDetectionOn: miotBool(motion?.val),
        streamEntityId: streamSvc ? makeMiotAddress(did, streamSvc.iid) : null,
      };
    }

    if (sName === "temperature-humidity-sensor" || sName === "environment") {
      const readingServices = [
        primaryService,
        ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
        ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
      ];
      const temp = readFirst(readingServices, "temperature");
      const hum = readFirst(readingServices, "relative-humidity");
      const battery = readFirst(
        spec.services.filter((s) => miotShortName(s.type) === "battery"),
        "battery-level"
      );
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
      const consumptionServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "power-consumption"),
        ...spec.services,
      ];
      const power = readFirst(consumptionServices, "electric-power");
      const energy = readFirst(consumptionServices, "power-consumption", (p) => energyScale(p) !== null);
      const energyScaleVal = energy ? energyScale(energy.prop) : null;
      const energyKwh =
        energy && typeof energy.val === "number" && Number.isFinite(energy.val) && energy.val >= 0 && energyScaleVal !== null
          ? Math.round(energy.val * energyScaleVal * 1000) / 1000
          : null;
      const lockSvc = spec.services.find((s) => miotShortName(s.type) === "physical-controls-locked");
      const lock = lockSvc ? readProp(lockSvc, "physical-controls-locked") : null;

      return {
        kind: "plug",
        switchEntityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        powerWatts: typeof power?.val === "number" ? power.val : null,
        ...(energyKwh !== null ? { energyKwh } : {}),
        childLockEntityId: lock ? makeMiotAddress(did, lock.service.iid) : null,
        isChildLocked: miotBool(lock?.val) ?? false,
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
        const others = [
          ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
          ...spec.services.filter((s) => s.iid !== service.iid),
        ];
        for (const s of others) {
          const p = s.properties.find((pr) => miotShortName(pr.type) === short && pr.access.includes("write"));
          if (p) return { service: s, prop: p };
        }
      }
      throw new Error(`Unsupported property: ${short}`);
    };

    const findListProp = (short: string, description: string, searchAll = false) => {
      const services = [
        service,
        ...(searchAll
          ? [
              ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
              ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
              ...spec.services.filter((s) => s.iid !== service.iid),
            ]
          : []),
      ];
      for (const s of services) {
        for (const p of s.properties) {
          if (miotShortName(p.type) === short && p.access.includes("write")) {
            const item = p.valueList?.find(
              (i) => i.description.toLowerCase() === description.toLowerCase()
            );
            if (item) return { service: s, prop: p, item };
          }
        }
      }
      return null;
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
        const found = findListProp("mode", command.effect);
        if (!found) throw new Error(`Unsupported effect: ${command.effect}`);
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value },
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
        const found = findListProp("fan-level", command.fanMode, true);
        if (!found) throw new Error(`Unsupported fan mode: ${command.fanMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
        };
      }
      case "setFanPercentage": {
        if (command.percent <= 0) {
          const { prop } = findProp("on");
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: false }],
          };
        }
        let speedFound: { service: MiotService; prop: MiotProperty } | null = null;
        const directRange = service.properties.find(
          (p) => miotShortName(p.type) === "fan-level" && p.access.includes("write") && p.valueRange !== undefined
        );
        if (directRange) {
          speedFound = { service, prop: directRange };
        }
        if (!speedFound) {
          const favServices = [
            ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
            ...spec.services.filter((s) => miotShortName(s.type) === "motor-speed"),
            ...spec.services.filter((s) => miotShortName(s.type) === "custom-service"),
            ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
          ];
          const candidates = ["fan-level", "favorite-fan-level", "favorite-level", "favorite-speed"];
          for (const name of candidates) {
            if (speedFound) break;
            for (const s of favServices) {
              const p = s.properties.find((pr) => miotShortName(pr.type) === name && pr.access.includes("write"));
              if (p) {
                speedFound = { service: s, prop: p };
                break;
              }
            }
          }
        }
        if (!speedFound) {
          const directList = service.properties.find(
            (p) => miotShortName(p.type) === "fan-level" && p.access.includes("write")
          );
          if (directList) speedFound = { service, prop: directList };
        }
        if (!speedFound) throw new Error("Unsupported property: fan-level");

        const clamped = Math.max(0, Math.min(100, command.percent));
        let writeVal: number;
        const range = speedFound.prop.valueRange;
        const list = speedFound.prop.valueList;
        if (range && range.length >= 2 && (range[1] ?? 0) > (range[0] ?? 0)) {
          const lo = range[0] ?? 0;
          const hi = range[1] ?? 100;
          const raw = lo > 1 ? lo + (clamped / 100) * (hi - lo) : hi !== 100 ? (clamped / 100) * hi : clamped;
          writeVal = coerce(speedFound.prop, raw);
        } else if (list && list.length > 0) {
          const vals = list.map((i) => i.value);
          const lo = Math.min(...vals);
          const hi = Math.max(...vals);
          const target = lo === 0 && hi > 0 ? (clamped / 100) * hi : hi > lo ? lo + (clamped / 100) * (hi - lo) : lo;
          let best = list[0]!;
          for (const item of list) {
            if (Math.abs(item.value - target) < Math.abs(best.value - target)) {
              best = item;
            }
          }
          writeVal = best.value;
        } else {
          writeVal = coerce(speedFound.prop, clamped);
        }

        const prefix = [...powerOnPrefix()];
        if (speedFound.service.iid !== service.iid) {
          const favMode = findListProp("mode", "Favorite");
          if (favMode) {
            prefix.push({ did: addr.did, siid: favMode.service.iid, piid: favMode.prop.iid, value: favMode.item.value });
          }
        }
        return {
          kind: "setProps",
          writes: [
            ...prefix,
            { did: addr.did, siid: speedFound.service.iid, piid: speedFound.prop.iid, value: writeVal },
          ],
        };
      }
      case "setFanPresetMode": {
        const found = findListProp("mode", command.presetMode) ?? findListProp("fan-level", command.presetMode, true);
        if (!found) throw new Error(`Unsupported preset: ${command.presetMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
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
        const onProp =
          service.properties.find(
            (p) => miotShortName(p.type) === "on" && p.access.includes("write")
          ) ??
          service.properties.find(
            (p) => miotShortName(p.type) === "motion-detection" && p.access.includes("write")
          );
        const targetProp = onProp ?? findProp("physical-controls-locked").prop;
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: targetProp.iid, value: command.isOn }],
        };
      }
      case "setSelectOption": {
        const found = findListProp("mode", command.option) ?? findListProp("night-shot", command.option);
        if (!found) throw new Error(`Unsupported select option: ${command.option}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
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
