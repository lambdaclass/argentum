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
  - That no `reject` line is a valid encoding of any record the fixture names. A rejection that
    accidentally *was* a valid record would be a fixture bug that both codecs would happily
    agree with.
  - It cannot check the layout is the *right* layout. If the wire specification itself is wrong,
    this file is wrong in the same way. Three implementations agreeing is evidence against
    slips, not against a bad decision.

Exits 0 when every semantic line's bytes match and no rejection is a valid record.
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


def main():
    default = pathlib.Path(__file__).with_name("wire_contract.txt")
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default

    valid = set()
    semantic = 0
    rejections = 0
    failures = []

    for number, line in enumerate(path.read_text().splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("reject"):
            rejections += 1
            *hex_bytes, _reason = line.removeprefix("reject").split()
            valid_bytes = read_hex(" ".join(hex_bytes))
            if valid_bytes in valid:
                failures.append(f"{path.name}:{number}: rejects bytes that are a valid record")
            continue

        semantic += 1
        fields, _, hex_column = line.partition("=")
        expected = read_hex(hex_column)
        found = encode(fields.split())
        valid.add(found)

        if found != expected:
            failures.append(
                f"{path.name}:{number}: {fields.strip()}\n"
                f"  fixture: {' '.join(f'{b:02x}' for b in expected)}\n"
                f"  python:  {' '.join(f'{b:02x}' for b in found)}"
            )

    # A rejection can appear above the record it is a prefix of, so the valid set is only
    # complete once the file has been read. Check them again against the finished set.
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        line = line.strip()
        if not line.startswith("reject"):
            continue
        *hex_bytes, _reason = line.removeprefix("reject").split()
        if read_hex(" ".join(hex_bytes)) in valid:
            message = f"{path.name}:{number}: rejects bytes that are a valid record"
            if message not in failures:
                failures.append(message)

    if failures:
        print("\n".join(failures))
        print(f"\n{len(failures)} disagreement(s) between the fixture and this implementation.")
        return 1

    print(f"{semantic} records and {rejections} rejections agree with Python `struct`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
