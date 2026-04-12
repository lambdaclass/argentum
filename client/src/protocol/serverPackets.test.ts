import { describe, expect, it } from "vitest";
import { decodeServerPackets } from "./serverPackets";

function int16(value: number) {
  return [value & 0xff, (value >> 8) & 0xff];
}

function int32(value: number) {
  return [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff
  ];
}

function string8(value: string) {
  const bytes = Array.from(value, (char) => char.charCodeAt(0));
  return [...int16(bytes.length), ...bytes];
}

function packet(packetId: number, payload: number[]) {
  return [...int16(packetId), ...payload];
}

function bufferFromBytes(bytes: number[]) {
  return Uint8Array.from(bytes).buffer;
}

describe("decodeServerPackets", () => {
  it("decodes weather toggle packets from AO protocol bytes", () => {
    const buffer = bufferFromBytes([
      ...packet(59, [1]),
      ...packet(76, [0])
    ]);

    expect(decodeServerPackets(buffer)).toEqual([
      { type: "rain_toggle", raining: true },
      { type: "snow_toggle", snowing: false }
    ]);
  });

  it("decodes session token packets with string8 payloads", () => {
    const buffer = bufferFromBytes(packet(200, [...int32(4701), ...string8("token-abc")]));

    expect(decodeServerPackets(buffer)).toEqual([
      {
        type: "session_token",
        credentials: {
          charId: 4701,
          token: "token-abc"
        }
      }
    ]);
  });

  it("stops decoding after an unknown packet id", () => {
    const buffer = bufferFromBytes([
      ...packet(59, [1]),
      ...packet(999, []),
      ...packet(76, [1])
    ]);

    expect(decodeServerPackets(buffer)).toEqual([
      { type: "rain_toggle", raining: true },
      { type: "unknown", packetId: 999 }
    ]);
  });
});
