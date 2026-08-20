# World-map overview

The overlay behind Tab draws a whole-world view. This is the entry for the one
asset it is allowed to load, kept separate from the gameplay world pack on
purpose: the pack is per-map tile data streamed while you play, and decoding or
retaining all of it to draw a picture of the world would cost hundreds of
megabytes to produce something that fits in sixteen.

The art does not exist yet. This entry exists anyway, because it is the budget
the art has to fit and the thing the client is checked against — a manifest
written after the asset is a description of whatever was made.

The client draws a vector outline from the marker data until the asset arrives,
which is also what a device too small for the reduced profile gets permanently.
The outline is a fallback, not a degraded mode: nothing about it is a black
rectangle with a spinner in it.

    id: world-map.overview
    path: world-map/overview.png
    source: project-owned, generated offline from the map data the server publishes
    licence: this repository's own
    format: png
    max-dimension: 2048
    reduced-dimension: 1024
    bytes-per-pixel: 4
    max-compressed-bytes: 2097152
    decoded-bytes: 16777216
    reduced-decoded-bytes: 4194304
    below-reduced: outline
    retained: while the overlay is open

**Maximum dimension** is 2048 because that is the smallest `max_texture_dimension_2d`
any WebGL2 device in the support matrix guarantees. The full profile therefore
works everywhere the client runs at all, and the reduced profile exists for
devices that report less than they promise.

**Compressed cost** is a ceiling, not a measurement. A world overview is flat
colour and hard edges, which is what PNG is good at; if the produced art does not
fit 2 MiB it is too detailed for what this overlay is for.

**Which profile a device gets** is decided from the device's own reported texture
limit — the same number the world render target is bounded by — and never from
the user agent. Guessing from the user agent is how a client ends up asking a
phone for sixteen megabytes.

The numbers here are the ones `ui::worldmap` compiles in, and a test fails if the
two disagree. Two copies of a budget that can drift are one budget and one
comment.
