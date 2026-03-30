import { BinaryReader } from "./BinaryReader";
import type { CharacterCreatePacket, ServerPacket } from "../app/types";

function decodeCharacterCreate(reader: BinaryReader): CharacterCreatePacket {
  const charIndex = reader.readInt16();
  const bodyId = reader.readInt16();
  const headId = reader.readInt16();
  const heading = reader.readUint8();
  const x = reader.readUint8();
  const y = reader.readUint8();

  reader.readInt16();
  reader.readInt16();
  reader.readInt16();
  reader.readInt16();
  reader.readInt16();
  reader.readInt16();
  reader.readInt16();

  const name = reader.readString8();

  reader.readUint8();
  reader.readUint8();
  reader.readUint8();

  for (let index = 0; index < 7; index += 1) {
    reader.readString8();
  }

  const speed = reader.readFloat32();

  reader.readUint8();
  reader.readUint8();
  reader.readInt16();
  reader.readInt16();
  reader.readUint8();

  const minHp = reader.readInt32();
  const maxHp = reader.readInt32();
  const minMana = reader.readInt32();
  const maxMana = reader.readInt32();

  reader.readUint8();
  reader.readUint8();
  reader.readUint8();
  reader.readUint8();
  reader.readUint8();
  reader.readInt16();

  return {
    charIndex,
    bodyId,
    headId,
    heading,
    x,
    y,
    name,
    speed,
    minHp,
    maxHp,
    minMana,
    maxMana
  };
}

function decodePacket(packetId: number, reader: BinaryReader): ServerPacket {
  switch (packetId) {
    case 2:
      return { type: "logged", newUser: reader.readBool() };

    case 25:
      return { type: "update_stamina", current: reader.readInt16() };

    case 26:
      return { type: "update_mana", current: reader.readInt16() };

    case 27:
      return {
        type: "update_hp",
        current: reader.readInt16(),
        shield: reader.readInt32()
      };

    case 28:
      return {
        type: "update_gold",
        gold: reader.readInt32(),
        walletGoldByLevel: reader.readInt32()
      };

    case 29:
      return {
        type: "update_exp",
        currentXp: reader.readInt32(),
        nextXp: reader.readInt32()
      };

    case 30:
      return {
        type: "change_map",
        mapId: reader.readInt16(),
        version: reader.readInt16()
      };

    case 31:
      return { type: "pos_update", x: reader.readUint8(), y: reader.readUint8() };

    case 35:
    {
      const message = reader.readString8();
      const charIndex = reader.readInt16();
      reader.readInt32();
      reader.readBool();
      const x = reader.readUint8();
      const y = reader.readUint8();
      reader.readInt16();
      reader.readInt16();

      return {
        type: "chat_over_head",
        message,
        charIndex,
        x,
        y
      };
    }

    case 37:
      return {
        type: "console_msg",
        message: reader.readString8(),
        fontIndex: reader.readUint8()
      };

    case 42:
      return {
        type: "character_create",
        character: decodeCharacterCreate(reader)
      };

    case 43:
      return { type: "character_remove", charIndex: reader.readInt16() };

    case 44:
      return {
        type: "character_move",
        charIndex: reader.readInt16(),
        x: reader.readUint8(),
        y: reader.readUint8()
      };

    case 46:
      return { type: "user_index_in_server", userIndex: reader.readInt16() };

    case 47:
      return { type: "user_char_index_in_server", charIndex: reader.readInt16() };

    case 49:
      return {
        type: "character_change_heading",
        charIndex: reader.readInt16(),
        heading: reader.readUint8()
      };

    case 50:
    {
      const packet = {
        type: "object_create",
        x: reader.readUint8(),
        y: reader.readUint8(),
        objIndex: reader.readInt16(),
        amount: reader.readInt16()
      } as const;
      reader.readInt32();
      return packet;
    }

    case 52:
      return { type: "object_delete", x: reader.readUint8(), y: reader.readUint8() };

    case 63: {
      const slotIndex = reader.readUint8() - 1;
      const itemId = reader.readInt16();
      const amount = reader.readInt16();
      const equipped = reader.readBool();
      const value = reader.readFloat32();
      const canUse = reader.readUint8();
      reader.readInt32();
      reader.readBool();

      return {
        type: "change_inventory_slot",
        slotIndex,
        slot:
          itemId === 0 || amount === 0
            ? null
            : {
                itemId,
                amount,
                equipped,
                value,
                canUse
              }
      };
    }

    case 66: {
      const slotIndex = reader.readUint8() - 1;
      const spellId = reader.readInt16();
      const name = reader.readString8();

      return {
        type: "change_spell_slot",
        slotIndex,
        slot: spellId <= 0 ? null : { spellId, name }
      };
    }

    case 73:
      return { type: "error_msg", message: reader.readString8() };

    case 78: {
      reader.readUint8();
      const thirst = reader.readUint8();
      reader.readUint8();
      const hunger = reader.readUint8();

      return { type: "update_hunger_and_thirst", hunger, thirst };
    }

    case 80:
      return { type: "level_up", level: reader.readInt16() };

    case 158:
    {
      reader.readInt32();
      const walk = reader.readInt32();
      for (let index = 0; index < 10; index += 1) {
        reader.readInt32();
      }
      return { type: "intervals", walk };
    }

    case 200:
      return {
        type: "session_token",
        credentials: {
          charId: reader.readInt32(),
          token: reader.readString8()
        }
      };

    default:
      return { type: "unknown", packetId };
  }
}

export function decodeServerPackets(buffer: ArrayBuffer): ServerPacket[] {
  const reader = new BinaryReader(buffer);
  const packets: ServerPacket[] = [];

  while (reader.remaining() >= 2) {
    const packetId = reader.readInt16();
    const packet = decodePacket(packetId, reader);
    packets.push(packet);

    if (packet.type === "unknown") {
      break;
    }
  }

  return packets;
}
