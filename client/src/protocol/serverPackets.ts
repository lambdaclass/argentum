import { BinaryReader } from "./BinaryReader";
import type { CharacterCreatePacket, ServerPacket, SkillEntry, TradeOfferSlot } from "../app/types";
import { getSpellMetadata } from "../data/gameData";

function splitDashList(value: string) {
  return value
    .split("-")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function parsePartyMemberLabel(value: string) {
  const leader = value.endsWith("(Lider)");
  return {
    leader,
    name: leader ? value.replace(/\(Lider\)$/, "").trim() : value.trim()
  };
}

function decodeCharacterCreate(reader: BinaryReader): CharacterCreatePacket {
  const charIndex = reader.readInt16();
  const bodyId = reader.readInt16();
  const headId = reader.readInt16();
  const heading = reader.readUint8();
  const x = reader.readUint8();
  const y = reader.readUint8();

  const weaponId = reader.readInt16();
  const shieldId = reader.readInt16();
  const helmetId = reader.readInt16();
  const cartId = reader.readInt16();
  const backpackId = reader.readInt16();
  const effectId = reader.readInt16();
  const effectLoops = reader.readInt16();

  const name = reader.readString8();

  reader.readUint8();
  reader.readUint8();
  reader.readUint8();

  for (let index = 0; index < 7; index += 1) {
    reader.readString8();
  }

  const speed = reader.readFloat32();

  const isNpc = reader.readUint8() !== 0;
  reader.readUint8(); // appear
  reader.readInt16(); // group_index
  const clanIndex = reader.readInt16();
  const clanLevel = reader.readUint8();

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
    weaponId,
    shieldId,
    helmetId,
    cartId,
    backpackId,
    effectId,
    effectLoops,
    heading,
    x,
    y,
    name,
    speed,
    minHp,
    maxHp,
    minMana,
    maxMana,
    isNpc,
    clanIndex,
    clanLevel
  };
}

function decodePacket(packetId: number, reader: BinaryReader): ServerPacket {
  switch (packetId) {
    case 2:
      return { type: "logged", newUser: reader.readBool() };

    case 5:
      return { type: "navigate_toggle", navigating: reader.readBool() };

    case 8:
      return { type: "commerce_end" };

    case 9:
      return { type: "bank_end" };

    case 10:
      return { type: "commerce_init", npcName: reader.readString8() };

    case 11:
      return { type: "bank_init" };

    case 12:
      return { type: "user_commerce_init", partnerName: reader.readString8() };

    case 16:
      return { type: "npc_kill_user" };

    case 17:
      return { type: "blocked_with_shield_user" };

    case 18:
      return { type: "blocked_with_shield_other", charIndex: reader.readInt16() };

    case 19:
      return { type: "char_swing", charIndex: reader.readInt16() };

    case 20:
      return { type: "safe_mode_on" };

    case 21:
      return { type: "safe_mode_off" };

    case 22:
      return { type: "party_safe_mode_on" };

    case 23:
      return { type: "party_safe_mode_off" };

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

    case 32:
      return {
        type: "npc_hit_user",
        target: reader.readUint8(),
        damage: reader.readInt16()
      };

    case 33:
      return {
        type: "user_hitted_by_user",
        charIndex: reader.readInt16(),
        target: reader.readUint8(),
        damage: reader.readInt16()
      };

    case 34:
      return {
        type: "user_hitted_user",
        charIndex: reader.readInt16(),
        target: reader.readUint8(),
        damage: reader.readInt16()
      };

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

    case 38:
      return {
        type: "console_faction_message",
        message: reader.readString8(),
        fontIndex: reader.readUint8(),
        factionLabel: reader.readString8()
      };

    case 39:
      return {
        type: "guild_chat",
        status: reader.readUint8(),
        message: reader.readString8()
      };

    case 42:
      return {
        type: "character_create",
        character: decodeCharacterCreate(reader)
      };

    case 43: {
      const charIndex = reader.readInt16();
      reader.readBool(); // desvanecido
      reader.readBool(); // fue_warp
      return { type: "character_remove", charIndex };
    }

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

    case 49: {
      const charIndex = reader.readInt16();
      reader.readUint8(); // flags
      const bodyId = reader.readInt16();
      const headId = reader.readInt16();
      const heading = reader.readUint8();
      const weaponId = reader.readInt16();
      const shieldId = reader.readInt16();
      const helmetId = reader.readInt16();
      const cartId = reader.readInt16();
      const backpackId = reader.readInt16();
      const effectId = reader.readInt16();
      const effectLoops = reader.readInt16();
      return {
        type: "character_change",
        charIndex,
        bodyId,
        headId,
        weaponId,
        shieldId,
        helmetId,
        cartId,
        backpackId,
        effectId,
        effectLoops,
        heading
      };
    }

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

    case 55:
      return {
        type: "play_wave",
        wav: reader.readInt16(),
        x: reader.readUint8(),
        y: reader.readUint8(),
        cancelLast: reader.readUint8() !== 0,
        localize: reader.readUint8() !== 0
      };

    case 56:
      return {
        type: "guild_list",
        guildNames: splitDashList(reader.readString8())
      };

    case 59: {
      const raining = reader.readUint8() !== 0;
      return { type: "rain_toggle", raining };
    }

    case 76:
      return { type: "snow_toggle", snowing: reader.readBool() };

    case 60:
      return {
        type: "create_fx",
        charIndex: reader.readInt16(),
        fxId: reader.readInt16(),
        loops: reader.readInt16(),
        x: reader.readUint8(),
        y: reader.readUint8()
      };

    case 61: {
      const hpMax = reader.readInt16();
      const hpCurrent = reader.readInt16();
      reader.readInt32(); // shield
      const manaMax = reader.readInt16();
      const manaCurrent = reader.readInt16();
      const staminaMax = reader.readInt16();
      const staminaCurrent = reader.readInt16();
      const gold = reader.readInt32();
      reader.readInt32(); // gold_cap
      const level = reader.readUint8();
      const nextXp = reader.readInt32();
      const currentXp = reader.readInt32();
      reader.readUint8(); // class

      return {
        type: "update_user_stats",
        hpCurrent,
        hpMax,
        manaCurrent,
        manaMax,
        staminaCurrent,
        staminaMax,
        gold,
        level,
        currentXp,
        nextXp
      };
    }

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

    case 65: {
      const slotIndex = reader.readUint8() - 1;
      const itemId = reader.readInt16();
      const elementalTags = reader.readInt32();
      const amount = reader.readInt16();
      const value = reader.readInt32();
      const canUse = reader.readUint8();

      return {
        type: "change_bank_slot",
        slotIndex,
        slot:
          itemId === 0 || amount === 0
            ? null
            : {
                itemId,
                amount,
                value,
                canUse,
                elementalTags
              }
      };
    }

    case 66: {
      const slotIndex = reader.readUint8() - 1;
      const spellId = reader.readInt16();
      reader.readInt16(); // index (same as spellId or -1)
      reader.readBool(); // is_bindable

      return {
        type: "change_spell_slot",
        slotIndex,
        slot: spellId <= 0 ? null : { spellId, name: getSpellMetadata(spellId)?.name ?? `Spell ${spellId}` }
      };
    }

    case 73:
      return { type: "error_msg", message: reader.readString8() };

    case 77: {
      const slotIndex = reader.readUint8() - 1;
      const itemId = reader.readInt16();
      const amount = reader.readInt16();
      const price = reader.readFloat32();
      const elementalTags = reader.readInt32();
      const canUse = reader.readUint8();

      return {
        type: "change_npc_inventory_slot",
        slotIndex,
        slot:
          itemId === 0 || amount === 0
            ? null
            : {
                itemId,
                amount,
                price,
                elementalTags,
                canUse
              }
      };
    }

    case 100: {
      const myOffer = reader.readBool();
      const gold = reader.readInt32();
      const items: Array<TradeOfferSlot | null> = [];

      for (let index = 0; index < 6; index += 1) {
        const itemId = reader.readInt16();
        const name = reader.readString8();
        const grhIndex = reader.readInt32();
        const amount = reader.readInt32();
        const elementalTags = reader.readInt32();
        items.push(itemId > 0 && amount > 0 ? { itemId, name, grhIndex, amount, elementalTags } : null);
      }

      return {
        type: "change_user_trade_slot",
        myOffer,
        gold,
        items
      };
    }

    case 78: {
      reader.readUint8();
      const thirst = reader.readUint8();
      reader.readUint8();
      const hunger = reader.readUint8();

      return { type: "update_hunger_and_thirst", hunger, thirst };
    }

    case 79: {
      reader.readInt32(); // ciudadanos_matados
      reader.readInt32(); // criminales_matados
      const factionStatus = reader.readUint8();
      reader.readInt32(); // npcs_killed
      const classId = reader.readUint8();
      reader.readInt32(); // penalty
      reader.readInt32(); // deaths
      const genderId = reader.readUint8();
      reader.readInt32(); // fishing_points
      const raceId = reader.readUint8();

      return {
        type: "mini_stats",
        classId,
        raceId,
        genderId,
        factionStatus
      };
    }

    case 80:
      return { type: "level_up", level: reader.readInt16() };

    case 87: {
      const SKILL_NAMES = [
        "magic", "stealing", "combat_tactics", "combat_weapons", "meditation",
        "short_weapons", "hiding", "survival", "trading", "combat_defense",
        "leadership", "ranged_weapons", "wrestling", "navigation", "riding",
        "resistance", "woodcutting", "fishing", "mining", "blacksmithing",
        "carpentry", "alchemy", "tailoring", "taming"
      ];
      const skills: SkillEntry[] = [];
      for (const name of SKILL_NAMES) {
        const level = reader.readUint8();
        if (level > 0) {
          skills.push({ key: name, level });
        }
      }
      return { type: "send_skills", skills };
    }

    case 89:
      return {
        type: "guild_news",
        news: reader.readString8(),
        guildList: splitDashList(reader.readString8()),
        memberList: splitDashList(reader.readString8()),
        level: reader.readUint8(),
        currentExp: reader.readInt16(),
        neededExp: reader.readInt16()
      };

    case 94:
      return {
        type: "guild_leader_info",
        guildList: splitDashList(reader.readString8()),
        memberList: splitDashList(reader.readString8()),
        news: reader.readString8(),
        requests: splitDashList(reader.readString8()),
        level: reader.readUint8(),
        currentExp: reader.readInt16(),
        neededExp: reader.readInt16()
      };

    case 95:
      return {
        type: "guild_details",
        name: reader.readString8(),
        founder: reader.readString8(),
        date: reader.readString8(),
        leader: reader.readString8(),
        memberCount: reader.readInt16(),
        alignment: reader.readString8(),
        description: reader.readString8(),
        level: reader.readUint8()
      };

    case 158:
    {
      reader.readInt32();
      const walk = reader.readInt32();
      for (let index = 0; index < 10; index += 1) {
        reader.readInt32();
      }
      return { type: "intervals", walk };
    }

    case 175:
      return { type: "update_bank_gold", bankGold: reader.readInt32() };

    case 143: {
      const inParty = reader.readBool();
      if (!inParty) {
        return { type: "datos_grupo", inParty, members: [], leaderName: "" };
      }

      const count = reader.readUint8();
      const members: string[] = [];
      let leaderName = "";

      for (let index = 0; index < count; index += 1) {
        const parsed = parsePartyMemberLabel(reader.readString8());
        members.push(parsed.name);
        if (parsed.leader) {
          leaderName = parsed.name;
        }
      }

      return {
        type: "datos_grupo",
        inParty,
        members,
        leaderName: leaderName || members[0] || ""
      };
    }

    case 200:
      return {
        type: "session_token",
        credentials: {
          charId: reader.readInt32(),
          token: reader.readString8()
        }
      };

    case 203:
      return {
        type: "world_pack_signature",
        version: reader.readInt16(),
        hash: reader.readString8()
      };

    case 13:
      return { type: "user_commerce_end" };

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
