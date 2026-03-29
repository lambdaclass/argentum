# Arena

Game logic for the Argentum Online Elixir server. Handles MapServer (one GenServer per active map), entity state, gameplay, combat formulas, NPC AI, and static data loading from VB6 .dat files.

Uses a Rust NIF (`TileGrid`) for tile collision only — all gameplay logic is pure Elixir.
