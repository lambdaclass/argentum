defmodule Arena.AoiClientContractTest do
  @moduledoc """
  The area of interest is duplicated in the Rust client, and this pins the two
  together.

  `client-rs/crates/ao-client/src/ui/layout.rs` declares `AOI_RADIUS_X`/
  `AOI_RADIUS_Y` and refuses to draw an entity outside them, so that no window
  size can turn a wide monitor into a spyglass. That bound is only meaningful
  if it matches the range the server actually broadcasts within.

  Drift in either direction is a real fault and neither is loud:

    * client radius **smaller** than the server's — entities the server sent are
      never drawn, so a player is attacked from an apparently empty tile;
    * client radius **larger** — the client reserves space for entities that
      never arrive, and the extra area reads as suspiciously empty.

  The value is read from the client source rather than copied here, so this
  fails when either side moves.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Helpers

  @client_layout Path.expand(
                   "../../../../client-rs/crates/ao-client/src/ui/layout.rs",
                   __DIR__
                 )

  defp client_constant(source, name) do
    case Regex.run(~r/pub const #{name}: i32 = (\d+);/, source) do
      [_, value] -> String.to_integer(value)
      nil -> flunk("#{name} is not declared in #{@client_layout}")
    end
  end

  test "the Rust client's area of interest matches the server's broadcast range" do
    source = File.read!(@client_layout)

    assert client_constant(source, "AOI_RADIUS_X") == Helpers.aoi_range_x()
    assert client_constant(source, "AOI_RADIUS_Y") == Helpers.aoi_range_y()
  end

  test "the client source still enforces the bound it declares" do
    # A constant nothing reads is a comment. This checks the guard function
    # exists, so deleting the enforcement fails here rather than silently
    # widening what the client will draw.
    source = File.read!(@client_layout)

    assert source =~ "pub fn within_area_of_interest",
           "the client declares an AoI radius but no longer enforces it"

    world = Path.expand("../../../../client-rs/crates/ao-client/src/world.rs", __DIR__)

    assert File.read!(world) =~ "within_area_of_interest",
           "world rendering no longer applies the area-of-interest bound"
  end
end
