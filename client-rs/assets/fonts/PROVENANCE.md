# Fonts

## alegreya-sans-ao.ttf

Copied verbatim from this repository's own asset tree:
`resources/raw/OUTPUT/Alegreya Sans AO.ttf`. It is the face the existing
BabelUI client already renders the game's interface with, so using it here keeps
the two clients visually consistent and introduces no new third-party asset.

Alegreya Sans is released under the SIL Open Font License; "AO" is this
project's own build of it.

**Why it is embedded rather than fetched.** Bevy's built-in font is a small
subset covering little more than ASCII. The game's first language is Spanish, so
`año`, `¿`, `Mago` and every accented item name rendered as empty boxes — as did
the em dash, the middle dot and the multiplication sign the interface uses as
separators. A font that arrives over the network would leave the first frames
unreadable, and the boot screen is exactly when a player is most likely to be
told something important.

At 388 KB against a ~19 MB WASM payload the cost is not worth deferring.
