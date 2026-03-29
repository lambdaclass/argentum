import type { Direction } from "../app/types";

const CLIENT_PACKET = {
  loginExisting: 73,
  loginNewChar: 74,
  talk: 75,
  walk: 78,
  requestPositionUpdate: 79,
  pickUp: 81,
  drop: 93,
  changeHeading: 6,
  equipItem: 5,
  useItem: 99,
  quit: 39
} as const;

function writeInt8(bytes: number[], value: number) {
  bytes.push(value & 0xff);
}

function writeInt16(bytes: number[], value: number) {
  bytes.push(value & 0xff, (value >> 8) & 0xff);
}

function writeInt32(bytes: number[], value: number) {
  bytes.push(
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff
  );
}

function writeString8(bytes: number[], value: string) {
  writeInt16(bytes, value.length);

  for (let index = 0; index < value.length; index += 1) {
    bytes.push(value.charCodeAt(index) & 0xff);
  }
}

function buildPacket(packetId: number, writer?: (bytes: number[]) => void) {
  const bytes: number[] = [];
  writeInt16(bytes, packetId);
  writer?.(bytes);
  return new Uint8Array(bytes);
}

function headingToInt(direction: Direction) {
  switch (direction) {
    case "north":
      return 1;
    case "east":
      return 2;
    case "south":
      return 3;
    case "west":
      return 4;
  }
}

export function encodeLoginExisting(charId: number, token: string) {
  return buildPacket(CLIENT_PACKET.loginExisting, (bytes) => {
    writeString8(bytes, token);
    writeInt32(bytes, charId);
    writeInt8(bytes, 1);
    writeInt8(bytes, 0);
    writeInt8(bytes, 0);
    writeString8(bytes, "abcdef1234567890abcdef1234567890");
  });
}

export function encodeCreateCharacter(characterName: string) {
  return buildPacket(CLIENT_PACKET.loginNewChar, (bytes) => {
    writeString8(bytes, "browser_bootstrap_token");
    writeString8(bytes, characterName);
    writeInt8(bytes, 1);
    writeInt8(bytes, 0);
    writeInt8(bytes, 0);
    writeString8(bytes, "abcdef1234567890abcdef1234567890");
    writeInt8(bytes, 1);
    writeInt8(bytes, 1);
    writeInt8(bytes, 6);
    writeInt16(bytes, 1);
    writeInt8(bytes, 1);
  });
}

export function encodeWalk(direction: Direction) {
  return buildPacket(CLIENT_PACKET.walk, (bytes) => {
    writeInt8(bytes, headingToInt(direction));
    writeInt32(bytes, 1);
  });
}

export function encodeTalk(message: string) {
  return buildPacket(CLIENT_PACKET.talk, (bytes) => {
    writeString8(bytes, message);
  });
}

export function encodePickUp() {
  return buildPacket(CLIENT_PACKET.pickUp);
}

export function encodeDrop(slotIndex: number, amount: number) {
  return buildPacket(CLIENT_PACKET.drop, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt16(bytes, amount);
  });
}

export function encodeEquipItem(slotIndex: number) {
  return buildPacket(CLIENT_PACKET.equipItem, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
  });
}

export function encodeUseItem(slotIndex: number) {
  return buildPacket(CLIENT_PACKET.useItem, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
  });
}

export function encodeChangeHeading(direction: Direction) {
  return buildPacket(CLIENT_PACKET.changeHeading, (bytes) => {
    writeInt8(bytes, headingToInt(direction));
  });
}

export function encodeRequestPositionUpdate() {
  return buildPacket(CLIENT_PACKET.requestPositionUpdate);
}

export function encodeQuit() {
  return buildPacket(CLIENT_PACKET.quit);
}
