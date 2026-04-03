import type { Direction } from "../app/types";

const CLIENT_PACKET = {
  loginExisting: 73,
  loginNewChar: 74,
  talk: 75,
  walk: 78,
  requestPositionUpdate: 79,
  attack: 80,
  castSpell: 94,
  pickUp: 81,
  safeToggle: 82,
  drop: 93,
  commerceStart: 53,
  commerceBuy: 9,
  commerceSell: 11,
  commerceEnd: 88,
  userCommerceOffer: 16,
  userCommerceEnd: 89,
  userCommerceOk: 91,
  userCommerceReject: 92,
  leftClick: 95,
  changeHeading: 6,
  equipItem: 5,
  useItem: 99,
  quit: 39
} as const;

const CLIENT_VERSION = {
  major: 1,
  minor: 0,
  build: 0
} as const;

const CLIENT_MD5 = "abcdef1234567890abcdef1234567890";
let packetCounter = 0;

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

function nextPacketCounter() {
  packetCounter = (packetCounter + 1) >>> 0;
  return packetCounter;
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
    writeInt8(bytes, CLIENT_VERSION.major);
    writeInt8(bytes, CLIENT_VERSION.minor);
    writeInt8(bytes, CLIENT_VERSION.build);
    writeString8(bytes, CLIENT_MD5);
  });
}

export function encodeCreateCharacter(characterName: string, password: string) {
  return buildPacket(CLIENT_PACKET.loginNewChar, (bytes) => {
    writeString8(bytes, password);
    writeString8(bytes, characterName);
    writeInt8(bytes, CLIENT_VERSION.major);
    writeInt8(bytes, CLIENT_VERSION.minor);
    writeInt8(bytes, CLIENT_VERSION.build);
    writeString8(bytes, CLIENT_MD5);
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
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeTalk(message: string) {
  return buildPacket(CLIENT_PACKET.talk, (bytes) => {
    writeString8(bytes, message);
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeAttack() {
  return buildPacket(CLIENT_PACKET.attack, (bytes) => {
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodePickUp() {
  return buildPacket(CLIENT_PACKET.pickUp);
}

export function encodeCastSpell(slotIndex: number) {
  return buildPacket(CLIENT_PACKET.castSpell, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeDrop(slotIndex: number, amount: number) {
  return buildPacket(CLIENT_PACKET.drop, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt32(bytes, amount);
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeEquipItem(slotIndex: number) {
  return buildPacket(CLIENT_PACKET.equipItem, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt8(bytes, 0); // is_skin = false
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeUseItem(slotIndex: number) {
  return buildPacket(CLIENT_PACKET.useItem, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt8(bytes, 1); // is_main_inventory
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeChangeHeading(direction: Direction) {
  return buildPacket(CLIENT_PACKET.changeHeading, (bytes) => {
    writeInt8(bytes, headingToInt(direction));
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeLeftClick(x: number, y: number) {
  return buildPacket(CLIENT_PACKET.leftClick, (bytes) => {
    writeInt8(bytes, x);
    writeInt8(bytes, y);
    writeInt32(bytes, nextPacketCounter());
  });
}

export function encodeSafeToggle() {
  return buildPacket(CLIENT_PACKET.safeToggle);
}

export function encodeCommerceStart() {
  return buildPacket(CLIENT_PACKET.commerceStart);
}

export function encodeCommerceBuy(slotIndex: number, amount: number) {
  return buildPacket(CLIENT_PACKET.commerceBuy, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt16(bytes, Math.max(1, Math.min(32_767, Math.floor(amount))));
  });
}

export function encodeCommerceSell(slotIndex: number, amount: number) {
  return buildPacket(CLIENT_PACKET.commerceSell, (bytes) => {
    writeInt8(bytes, slotIndex + 1);
    writeInt16(bytes, Math.max(1, Math.min(32_767, Math.floor(amount))));
  });
}

export function encodeCommerceEnd() {
  return buildPacket(CLIENT_PACKET.commerceEnd);
}

export function encodeUserTradeOffer(itemId: number, amount: number) {
  return buildPacket(CLIENT_PACKET.userCommerceOffer, (bytes) => {
    writeInt16(bytes, itemId);
    writeInt32(bytes, Math.max(1, Math.floor(amount)));
  });
}

export function encodeUserTradeEnd() {
  return buildPacket(CLIENT_PACKET.userCommerceEnd);
}

export function encodeUserTradeAccept() {
  return buildPacket(CLIENT_PACKET.userCommerceOk);
}

export function encodeUserTradeReject() {
  return buildPacket(CLIENT_PACKET.userCommerceReject);
}

export function encodeRequestPositionUpdate() {
  return buildPacket(CLIENT_PACKET.requestPositionUpdate);
}

export function encodeQuit() {
  return buildPacket(CLIENT_PACKET.quit);
}
