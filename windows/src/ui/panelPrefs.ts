import type { MiRoom } from "../core/miCloudClient.js";
import type { SmartDevice } from "../core/models.js";
import { t } from "../core/i18n.js";

// Panel personalisation shared with the macOS app: skins, per-page card sizes, custom order,
// user groups and local device names. Pure functions only, so they can be unit tested.

export type AppSkin = "classic" | "frost" | "night" | "glass" | "soft" | "bento" | "neon" | "capsule" | "dawn";

/**
 * Skin ids stay stable (they are persisted); `title` is a getter so it is translated in whatever
 * language is active when the panel renders, not at module load (#52).
 */
export const SKINS: ReadonlyArray<{ readonly id: AppSkin; readonly title: string }> = [
  { id: "classic", get title() { return t("经典"); } },
  { id: "frost", get title() { return t("霜白"); } },
  { id: "night", get title() { return t("夜航"); } },
  { id: "glass", get title() { return t("液态玻璃"); } },
  { id: "soft", get title() { return t("柔雾"); } },
  { id: "bento", get title() { return t("便当格"); } },
  { id: "neon", get title() { return t("霓虹夜"); } },
  { id: "capsule", get title() { return t("胶囊"); } },
  { id: "dawn", get title() { return t("晨光"); } },
];

export type PanelHeight = "compact" | "standard" | "tall" | "max";

export const PANEL_HEIGHTS: ReadonlyArray<{ readonly id: PanelHeight; readonly title: string; readonly px: number }> = [
  { id: "compact", get title() { return t("紧凑"); }, px: 520 },
  { id: "standard", get title() { return t("标准"); }, px: 620 },
  { id: "tall", get title() { return t("加高"); }, px: 740 },
  { id: "max", get title() { return t("最大"); }, px: 0 },
];

export type TileSize = "auto" | "half" | "full" | "panel";

export const TILE_SIZES: ReadonlyArray<{ readonly id: TileSize; readonly title: string }> = [
  { id: "auto", get title() { return t("自动"); } },
  { id: "half", get title() { return t("半行"); } },
  { id: "full", get title() { return t("整行"); } },
  { id: "panel", get title() { return t("展开面板"); } },
];

export interface DeviceGroup {
  readonly id: string;
  readonly name: string;
}

export interface LayoutPrefs {
  /** Keys are `deviceId` (all pages) or `<page>|<deviceId>` (one page). */
  tileSizes: Record<string, TileSize>;
  order: string[];
  groups: DeviceGroup[];
  groupMap: Record<string, string>;
  /** `<page>|<sectionId>` of folded sections. */
  collapsed: string[];
  aliases: Record<string, string>;
}

export const emptyLayoutPrefs = (): LayoutPrefs => ({
  tileSizes: {},
  order: [],
  groups: [],
  groupMap: {},
  collapsed: [],
  aliases: {},
});

export function scopedKey(page: string, id: string): string {
  return `${page}|${id}`;
}

/** Size for a device on one page, falling back to the all-pages default. */
export function chosenSize(prefs: LayoutPrefs, page: string, id: string): TileSize {
  return prefs.tileSizes[scopedKey(page, id)] ?? prefs.tileSizes[id] ?? "auto";
}

/** Resolves `auto` for the current grid mode; climate defaults to the full-row strip when enabled. */
export function resolvedSize(size: TileSize, device: SmartDevice, compactGrid: boolean, climatePanel: boolean): Exclude<TileSize, "auto"> {
  if (size !== "auto") return size;
  if (device.kind.kind === "climate" && climatePanel) return "full";
  return compactGrid ? "half" : "full";
}

export function nextSize(size: Exclude<TileSize, "auto">): Exclude<TileSize, "auto"> {
  return size === "half" ? "full" : size === "full" ? "panel" : "half";
}

/** Sorts by the saved order; devices not in it keep their incoming order after the known ones. */
export function applyOrder<T extends { readonly id: string }>(order: readonly string[], devices: readonly T[]): T[] {
  if (order.length === 0) return [...devices];
  const rank = new Map<string, number>();
  order.forEach((id, i) => { if (!rank.has(id)) rank.set(id, i); });
  return devices
    .map((d, i) => ({ d, r: rank.get(d.id) ?? order.length + i }))
    .sort((a, b) => a.r - b.r)
    .map((x) => x.d);
}

/** Moves `dragged` before/after `target`, seeding the order from `allIds` so unknown ids keep their place. */
export function moveInOrder(order: readonly string[], allIds: readonly string[], dragged: string, target: string, after: boolean): string[] {
  const next = [...order];
  for (const id of allIds) if (!next.includes(id)) next.push(id);
  if (!next.includes(dragged) || !next.includes(target) || dragged === target) return next;
  const without = next.filter((id) => id !== dragged);
  const t = without.indexOf(target);
  without.splice(after ? t + 1 : t, 0, dragged);
  return without;
}

/** Column span out of 6: half = 3, full/panel = 6; Bento alternates 4+2 and 2+2+2. */
export function spans(
  devices: readonly SmartDevice[],
  sizeOf: (d: SmartDevice) => Exclude<TileSize, "auto">,
  bento: boolean,
): Map<string, number> {
  const out = new Map<string, number>();
  if (bento) {
    let pattern: number[] = [];
    let rows = 0;
    for (const d of devices) {
      if (sizeOf(d) !== "half") { out.set(d.id, 6); pattern = []; continue; }
      if (pattern.length === 0) { pattern = rows % 2 === 0 ? [4, 2] : [2, 2, 2]; rows++; }
      out.set(d.id, pattern.shift() ?? 2);
    }
    return out;
  }
  for (const d of devices) out.set(d.id, sizeOf(d) === "half" ? 3 : 6);
  return out;
}

export interface PageSection {
  readonly id: string;
  readonly title: string | null;
  readonly devices: SmartDevice[];
  /** Set for user groups (rename / reorder / delete). */
  readonly groupId: string | null;
}

/** User groups first, then the ungrouped rest. A page without any grouped device is one untitled section. */
export function pageSections(prefs: LayoutPrefs, devices: readonly SmartDevice[], isAllPage: boolean): PageSection[] {
  const known = new Set(prefs.groups.map((g) => g.id));
  const groupOf = (id: string): string | null => {
    const g = prefs.groupMap[id];
    return g && known.has(g) ? g : null;
  };
  const sections: PageSection[] = [];
  for (const g of prefs.groups) {
    const members = devices.filter((d) => groupOf(d.id) === g.id);
    if (members.length > 0) sections.push({ id: g.id, title: g.name, devices: members, groupId: g.id });
  }
  const rest = devices.filter((d) => groupOf(d.id) === null);
  if (rest.length > 0) {
    const title = sections.length === 0 ? null : isAllPage ? t("更多设备") : t("其他");
    sections.push({ id: "rest", title, devices: rest, groupId: null });
  }
  return sections;
}

export function withAliases(prefs: LayoutPrefs, devices: readonly SmartDevice[]): SmartDevice[] {
  return devices.map((d) => (prefs.aliases[d.id] ? { ...d, name: prefs.aliases[d.id] as string } : d));
}

export interface HomeOption {
  readonly id: string;
  readonly name: string;
  readonly deviceCount: number;
}

/** One entry per Mi Home, in cloud order, counting unique dids. */
export function homeOptions(rooms: readonly MiRoom[]): HomeOption[] {
  const order: string[] = [];
  const names = new Map<string, string>();
  const dids = new Map<string, Set<string>>();
  for (const r of rooms) {
    const hid = r.homeId ?? "";
    if (!hid) continue;
    if (!names.has(hid)) { order.push(hid); names.set(hid, r.homeName ?? ""); dids.set(hid, new Set()); }
    for (const d of r.dids) dids.get(hid)?.add(d);
  }
  return order.map((id) => ({ id, name: names.get(id) ?? "", deviceCount: dids.get(id)?.size ?? 0 }));
}

export type ComfortLevel = "warm" | "cool" | "dry" | "humid" | "comfy";

export function comfort(temperature: number | null, humidity: number | null): { level: ComfortLevel; label: string } {
  const t0 = temperature ?? 24;
  const h = humidity ?? 50;
  if (t0 >= 28) return { level: "warm", label: t("偏热") };
  if (t0 <= 16) return { level: "cool", label: t("偏冷") };
  if (h < 35) return { level: "dry", label: t("偏干") };
  if (h > 70) return { level: "humid", label: t("偏湿") };
  return { level: "comfy", label: t("舒适") };
}

const EFFECT_NAMES: Record<string, string> = {
  Day: "日光", Night: "月光", None: "无", Warmth: "温馨", Tv: "观影", TV: "观影", Reading: "阅读",
  Computer: "电脑", Hospitality: "会客", Entertainment: "娱乐", Wakeup: "起床", Dusk: "黄昏", Sleep: "睡眠",
};

export function localizeEffect(effect: string): string {
  const key = EFFECT_NAMES[effect];
  return key === undefined ? effect : t(key);
}

const FAN_NAMES: Record<string, string> = { auto: "自动", low: "低", silent: "低", quiet: "低", medium: "中", middle: "中", high: "高" };

export function localizeFanMode(raw: string): string {
  const lower = raw.toLowerCase();
  const key = FAN_NAMES[lower];
  if (key !== undefined) return t(key);
  const m = /^level\s*(\d+)$/.exec(lower);
  return m ? t("{level} 档", { level: m[1] ?? "" }) : raw;
}
