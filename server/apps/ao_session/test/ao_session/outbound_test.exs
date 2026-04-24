defmodule AoSession.OutboundTest do
  use ExUnit.Case, async: true

  alias AoSession.Outbound

  describe "critical/1" do
    test "wraps payload and records byte size" do
      out = Outbound.critical(<<1, 2, 3, 4>>)
      assert %Outbound{class: :critical, payload: <<1, 2, 3, 4>>, bytes: 4} = out
      assert out.coalesce_key == nil
    end
  end

  describe "lossy/1" do
    test "wraps payload as lossy" do
      out = Outbound.lossy(<<0, 0>>)
      assert %Outbound{class: :lossy, bytes: 2, coalesce_key: nil} = out
    end
  end

  describe "coalesce/2" do
    test "wraps payload with a key" do
      out = Outbound.coalesce(<<9>>, {:hp, 42})
      assert %Outbound{class: :coalesce, payload: <<9>>, coalesce_key: {:hp, 42}, bytes: 1} = out
    end

    test "accepts any term as a key" do
      assert %Outbound{coalesce_key: :weather} = Outbound.coalesce(<<0>>, :weather)
      assert %Outbound{coalesce_key: "map-1"} = Outbound.coalesce(<<0>>, "map-1")
    end
  end
end
