/**
 * Pure TypeScript RC4 + SHA-1 + SHA-256 signing used by the Mi Home app's
 * `MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4` API.
 * Matches `Sources/MijiaCore/MiCloud/MiCloudCrypto.swift` byte-for-byte.
 */

export class RC4 {
  private readonly s: Uint8Array = new Uint8Array(256);
  private i = 0;
  private j = 0;

  constructor(key: Uint8Array, drop = 1024) {
    if (key.length === 0) {
      throw new Error("RC4 key must not be empty");
    }
    for (let idx = 0; idx < 256; idx++) {
      this.s[idx] = idx;
    }
    let j = 0;
    for (let i = 0; i < 256; i++) {
      const si = this.s[i] ?? 0;
      const ki = key[i % key.length] ?? 0;
      j = (j + si + ki) & 0xff;
      this.s[i] = this.s[j] ?? 0;
      this.s[j] = si;
    }
    if (drop > 0) {
      this.process(new Uint8Array(drop));
    }
  }

  process(input: Uint8Array): Uint8Array {
    const out = new Uint8Array(input.length);
    for (let idx = 0; idx < input.length; idx++) {
      this.i = (this.i + 1) & 0xff;
      const si = this.s[this.i] ?? 0;
      this.j = (this.j + si) & 0xff;
      const sj = this.s[this.j] ?? 0;
      this.s[this.i] = sj;
      this.s[this.j] = si;
      const k = this.s[(si + sj) & 0xff] ?? 0;
      out[idx] = (input[idx] ?? 0) ^ k;
    }
    return out;
  }
}

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function bytesToBase64(bytes: Uint8Array): string {
  let result = "";
  const len = bytes.length;
  for (let i = 0; i < len; i += 3) {
    const b0 = bytes[i] ?? 0;
    const b1 = i + 1 < len ? (bytes[i + 1] ?? 0) : 0;
    const b2 = i + 2 < len ? (bytes[i + 2] ?? 0) : 0;
    const triplet = (b0 << 16) | (b1 << 8) | b2;
    result += B64_CHARS[(triplet >>> 18) & 0x3f];
    result += B64_CHARS[(triplet >>> 12) & 0x3f];
    result += i + 1 < len ? B64_CHARS[(triplet >>> 6) & 0x3f] : "=";
    result += i + 2 < len ? B64_CHARS[triplet & 0x3f] : "=";
  }
  return result;
}

export function base64ToBytes(b64: string): Uint8Array {
  const clean = b64.trim();
  if (clean.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(clean)) {
    throw new Error(`Invalid base64: ${clean.slice(0, 8)}`);
  }
  const pad = clean.endsWith("==") ? 2 : clean.endsWith("=") ? 1 : 0;
  const outLen = (clean.length / 4) * 3 - pad;
  const out = new Uint8Array(outLen);
  let outIdx = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const c0 = B64_CHARS.indexOf(clean[i] ?? "");
    const c1 = B64_CHARS.indexOf(clean[i + 1] ?? "");
    const c2 = clean[i + 2] === "=" ? 0 : B64_CHARS.indexOf(clean[i + 2] ?? "");
    const c3 = clean[i + 3] === "=" ? 0 : B64_CHARS.indexOf(clean[i + 3] ?? "");
    if (c0 < 0 || c1 < 0 || c2 < 0 || c3 < 0) {
      throw new Error(`Invalid base64: ${clean.slice(0, 8)}`);
    }
    const triplet = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    if (outIdx < outLen) out[outIdx++] = (triplet >>> 16) & 0xff;
    if (outIdx < outLen) out[outIdx++] = (triplet >>> 8) & 0xff;
    if (outIdx < outLen) out[outIdx++] = triplet & 0xff;
  }
  return out;
}

function rotr32(x: number, n: number): number {
  return (x >>> n) | (x << (32 - n));
}

function rotl32(x: number, n: number): number {
  return (x << n) | (x >>> (32 - n));
}

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

export function sha256(msg: Uint8Array): Uint8Array {
  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const bitLen = msg.length * 8;
  const padLen = ((msg.length + 9 + 63) & ~63);
  const padded = new Uint8Array(padLen);
  padded.set(msg);
  padded[msg.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padLen - 8, Math.floor(bitLen / 0x100000000), false);
  view.setUint32(padLen - 4, bitLen >>> 0, false);

  const w = new Uint32Array(64);
  for (let offset = 0; offset < padLen; offset += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4, false);
    }
    for (let i = 16; i < 64; i++) {
      const w15 = w[i - 15] ?? 0;
      const w2 = w[i - 2] ?? 0;
      const s0 = rotr32(w15, 7) ^ rotr32(w15, 18) ^ (w15 >>> 3);
      const s1 = rotr32(w2, 17) ^ rotr32(w2, 19) ^ (w2 >>> 10);
      w[i] = ((w[i - 16] ?? 0) + s0 + (w[i - 7] ?? 0) + s1) >>> 0;
    }

    let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + (SHA256_K[i] ?? 0) + (w[i] ?? 0)) >>> 0;
      const S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  outView.setUint32(0, h0, false);
  outView.setUint32(4, h1, false);
  outView.setUint32(8, h2, false);
  outView.setUint32(12, h3, false);
  outView.setUint32(16, h4, false);
  outView.setUint32(20, h5, false);
  outView.setUint32(24, h6, false);
  outView.setUint32(28, h7, false);
  return out;
}

export function sha1(msg: Uint8Array): Uint8Array {
  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;

  const bitLen = msg.length * 8;
  const padLen = ((msg.length + 9 + 63) & ~63);
  const padded = new Uint8Array(padLen);
  padded.set(msg);
  padded[msg.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padLen - 8, Math.floor(bitLen / 0x100000000), false);
  view.setUint32(padLen - 4, bitLen >>> 0, false);

  const w = new Uint32Array(80);
  for (let offset = 0; offset < padLen; offset += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4, false);
    }
    for (let i = 16; i < 80; i++) {
      w[i] = rotl32((w[i - 3] ?? 0) ^ (w[i - 8] ?? 0) ^ (w[i - 14] ?? 0) ^ (w[i - 16] ?? 0), 1) >>> 0;
    }

    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i++) {
      let f = 0;
      let k = 0;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (rotl32(a, 5) + f + e + k + (w[i] ?? 0)) >>> 0;
      e = d;
      d = c;
      c = rotl32(b, 30) >>> 0;
      b = a;
      a = temp;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }

  const out = new Uint8Array(20);
  const outView = new DataView(out.buffer);
  outView.setUint32(0, h0, false);
  outView.setUint32(4, h1, false);
  outView.setUint32(8, h2, false);
  outView.setUint32(12, h3, false);
  outView.setUint32(16, h4, false);
  return out;
}

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

export const MiCloudCrypto = {
  RC4,

  makeNonce(nowMs = Date.now(), randomBytes?: readonly number[]): string {
    const out = new Uint8Array(12);
    if (randomBytes && randomBytes.length === 8) {
      for (let i = 0; i < 8; i++) out[i] = (randomBytes[i] ?? 0) & 0xff;
    } else {
      for (let i = 0; i < 8; i++) out[i] = Math.floor(Math.random() * 256);
    }
    const minutes = Math.floor(nowMs / 60_000) >>> 0;
    const view = new DataView(out.buffer);
    view.setUint32(8, minutes, false);
    return bytesToBase64(out);
  },

  signedNonce(ssecurity: string, nonce: string): string {
    const a = base64ToBytes(ssecurity);
    const b = base64ToBytes(nonce);
    const combined = new Uint8Array(a.length + b.length);
    combined.set(a, 0);
    combined.set(b, a.length);
    return bytesToBase64(sha256(combined));
  },

  sha1Signature(
    path: string,
    params: ReadonlyArray<readonly [string, string]>,
    signedNonce: string,
    method = "POST"
  ): string {
    const parts = [method.toUpperCase(), path, ...params.map(([k, v]) => `${k}=${v}`), signedNonce];
    const digest = sha1(utf8Encoder.encode(parts.join("&")));
    return bytesToBase64(digest);
  },

  encrypt(plain: string, signedNonce: string): string {
    const rc4 = new RC4(base64ToBytes(signedNonce));
    return bytesToBase64(rc4.process(utf8Encoder.encode(plain)));
  },

  decryptResponse(body: string, signedNonce: string): string {
    const cipher = base64ToBytes(body.trim());
    const rc4 = new RC4(base64ToBytes(signedNonce));
    return utf8Decoder.decode(rc4.process(cipher));
  },

  encryptParams(
    path: string,
    data: string,
    ssecurity: string,
    nonce: string
  ): Array<readonly [string, string]> {
    const signed = this.signedNonce(ssecurity, nonce);
    const rc4Hash = this.sha1Signature(path, [["data", data]], signed);
    const encrypted: Array<readonly [string, string]> = [
      ["data", this.encrypt(data, signed)],
      ["rc4_hash__", this.encrypt(rc4Hash, signed)],
    ];
    const signature = this.sha1Signature(path, encrypted, signed);
    return [
      ...encrypted,
      ["signature", signature],
      ["ssecurity", ssecurity],
      ["_nonce", nonce],
    ];
  },

  formURLEncode(fields: ReadonlyArray<readonly [string, string]>): string {
    return fields.map(([k, v]) => `${percentEncode(k)}=${percentEncode(v)}`).join("&");
  },

  compactJSONString(value: unknown): string {
    if (value === null || value === undefined) return "null";
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number") {
      return Number.isInteger(value) ? String(Math.trunc(value)) : String(value);
    }
    if (typeof value === "string") return JSON.stringify(value);
    if (Array.isArray(value)) {
      return `[${value.map((v) => this.compactJSONString(v)).join(",")}]`;
    }
    if (typeof value === "object") {
      const obj = value as Record<string, unknown>;
      const keys = Object.keys(obj).sort();
      const entries = keys.map((k) => `${JSON.stringify(k)}:${this.compactJSONString(obj[k])}`);
      return `{${entries.join(",")}}`;
    }
    return "null";
  },
};

function percentEncode(s: string): string {
  const bytes = utf8Encoder.encode(s);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i] ?? 0;
    const isUnreserved =
      (b >= 0x41 && b <= 0x5a) || // A-Z
      (b >= 0x61 && b <= 0x7a) || // a-z
      (b >= 0x30 && b <= 0x39) || // 0-9
      b === 0x2d || // -
      b === 0x2e || // .
      b === 0x5f || // _
      b === 0x7e; // ~
    if (isUnreserved) {
      out += String.fromCharCode(b);
    } else {
      out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
    }
  }
  return out;
}
