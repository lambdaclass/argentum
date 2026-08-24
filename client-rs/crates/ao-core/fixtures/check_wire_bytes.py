#!/usr/bin/env python3
"""Re-derive `wire_contract.txt`'s bytes with a third implementation and compare.

    python3 check_wire_bytes.py [path/to/wire_contract.txt]

The fixture is the specification for `ao_core::wire` and `Arena.World.Wire`. Its hexadecimal
column was produced here, by Python `struct`, precisely so that neither codec under test wrote
the answers it is checked against: a fixture generated from one implementation proves that
implementation is consistent with itself and nothing more.

This script only *verifies*. It never writes the fixture, because a generator committed beside
its output invites the next person to regenerate rather than hand-author, and at that moment the
independence this file exists for is gone.

What it attests, and what it cannot:

  - Field order, width, signedness and endianness, independently. Python's `struct` packs by a
    different route than Rust's byte writes and Elixir's bit syntax, so a transposed pair, a
    wrong width, or a big-endian slip shows up as a diff here.
  - That every `reject` line is refused *for the reason the fixture states*, by an independent
    decoder written here. An earlier version only checked that rejected bytes were not among the
    valid records listed in the same file, which is far weaker: it could not tell a truncated
    record from an oversized one, said nothing about a rejection whose bytes appear nowhere else,
    and would have accepted a fixture that named the wrong reason. A decoder that refuses for the
    wrong reason cannot distinguish a framing bug from an unknown field, which is the whole point
    of having four separate reasons.
  - It cannot check the layout is the *right* layout. If the wire specification itself is wrong,
    this file is wrong in the same way. Three implementations agreeing is evidence against
    slips, not against a bad decision.

Exits 0 when every record's bytes match, every record decodes back to the value that produced
it, every rejection is refused for the stated reason, and all four reasons are exercised.
"""

import pathlib
import struct
import sys

KINDS = {"seam": 1, "door": 2, "portal": 3, "teleport": 4, "instance": 5}


def position(version, space, x, y):
    return b"\x01" + struct.pack("<Q", version) + space.to_bytes(16, "little") + struct.pack("<ii", x, y)


def ownership(entity, region, epoch):
    return b"\x02" + struct.pack("<QIQ", entity, region, epoch)


def transfer(transfer_id, kind, source, destination):
    return b"\x03" + struct.pack("<QBII", transfer_id, KINDS[kind], source, destination)


def encode(fields):
    kind, *rest = fields
    if kind == "position":
        version, space, x, y = (int(value) for value in rest)
        return position(version, space, x, y)
    if kind == "ownership":
        entity, region, epoch = (int(value) for value in rest)
        return ownership(entity, region, epoch)
    if kind == "transfer":
        transfer_id, transition, source, destination = rest
        return transfer(int(transfer_id), transition, int(source), int(destination))
    raise SystemExit(f"unknown record kind {kind!r}")


def read_hex(text):
    return bytes(int(byte, 16) for byte in text.split())


# An independent decoder. Deliberately written from the contract's field table rather than
# translated from either codec, because a decoder that mirrors the implementation it checks can
# only agree with it.
SIZES = {1: 33, 2: 21, 3: 18}


def decode(raw):
    """Decode, or return ("reject", reason) naming why -- the fixture's four reasons exactly."""
    if not raw:
        return ("reject", "truncated")

    discriminant = raw[0]
    if discriminant not in SIZES:
        return ("reject", "unknown-record")

    expected = SIZES[discriminant]
    # Length is checked against the record the discriminant names *before* any field is read, so
    # a truncated record is never reported as a malformed one.
    if len(raw) < expected:
        return ("reject", "truncated")
    if len(raw) > expected:
        return ("reject", "oversized")

    if discriminant == 1:
        version, = struct.unpack("<Q", raw[1:9])
        space = int.from_bytes(raw[9:25], "little")
        x, y = struct.unpack("<ii", raw[25:33])
        return ("position", version, space, x, y)

    if discriminant == 2:
        entity, region, epoch = struct.unpack("<QIQ", raw[1:21])
        return ("ownership", entity, region, epoch)

    transfer_id, transition, source, destination = struct.unpack("<QBII", raw[1:18])
    for name, byte in KINDS.items():
        if byte == transition:
            return ("transfer", transfer_id, name, source, destination)
    # Zero included: an uninitialised byte must not decode as the most permissive kind.
    return ("reject", "unknown-transition")


def main():
    default = pathlib.Path(__file__).with_name("wire_contract.txt")
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default

    semantic = 0
    rejections = 0
    reasons = set()
    failures = []

    for number, line in enumerate(path.read_text().splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("reject"):
            rejections += 1
            *hex_bytes, reason = line.removeprefix("reject").split()
            raw = read_hex(" ".join(hex_bytes))
            reasons.add(reason)
            verdict = decode(raw)

            if verdict[0] != "reject":
                failures.append(
                    f"{path.name}:{number}: these bytes decode to a valid record\n"
                    f"  fixture says: {reason}\n"
                    f"  python read:  {verdict}"
                )
            elif verdict[1] != reason:
                failures.append(
                    f"{path.name}:{number}: refused for the wrong reason\n"
                    f"  fixture says: {reason}\n"
                    f"  python says:  {verdict[1]}"
                )
            continue

        semantic += 1
        fields, _, hex_column = line.partition("=")
        expected = read_hex(hex_column)
        found = encode(fields.split())

        if found != expected:
            failures.append(
                f"{path.name}:{number}: {fields.strip()}\n"
                f"  fixture: {' '.join(f'{b:02x}' for b in expected)}\n"
                f"  python:  {' '.join(f'{b:02x}' for b in found)}"
            )
            continue

        # And the bytes must read back as the value that produced them. An encoder and a
        # decoder can share a transposition and round-trip it, but not while both are checked
        # against a hand-authored hex column.
        recovered = decode(expected)
        stated = tuple(fields.split())
        recovered_text = (recovered[0],) + tuple(str(part) for part in recovered[1:])
        if recovered_text != stated:
            failures.append(
                f"{path.name}:{number}: decodes to something else\n"
                f"  fixture says: {' '.join(stated)}\n"
                f"  python read:  {' '.join(recovered_text)}"
            )

    # Every reason the contract can state must actually appear, or a reason could be silently
    # untested while the file looks thorough.
    missing = {"truncated", "oversized", "unknown-record", "unknown-transition"} - reasons
    if missing:
        failures.append(f"{path.name}: no rejection exercises {', '.join(sorted(missing))}")

    if failures:
        print("\n\n".join(failures))
        print(f"\n{len(failures)} disagreement(s) between the fixture and this implementation.")
        return 1

    print(
        f"{semantic} records encode and decode as stated; "
        f"{rejections} rejections refused for the stated reason."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
