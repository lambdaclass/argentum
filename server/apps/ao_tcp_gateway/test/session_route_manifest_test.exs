defmodule AoTcpGateway.SessionRouteManifestTest do
  use ExUnit.Case, async: true

  alias AoTcpGateway.{SessionLogic, SessionRouteManifest}
  alias AoTcpGateway.SessionCommands

  test "route groups remain centralized in the manifest" do
    assert :sos_show_list in SessionRouteManifest.group(:gm)
    assert :guild_offer_peace in SessionRouteManifest.group(:guild)
    assert :talk in SessionRouteManifest.group(:chat)
    assert :bank_deposit in SessionRouteManifest.group(:commerce)
  end

  test "parity-sensitive routes include vb6 refs and parity status" do
    info = SessionLogic.route_metadata(:information)
    quest = SessionLogic.route_metadata(:quest)
    support = SessionLogic.route_metadata(:question_gm)

    assert info.vb6_ref =~ "HandleInformation"
    assert info.parity_status == :exact

    assert quest.vb6_ref =~ "HandleQuest"
    assert quest.parity_status == :exact

    assert support.dispatch == {AoTcpGateway.SessionLogic, :handle_command}
    assert support.parity_status == :simplified
  end

  test "intentional divergences and exact routes stay explicit" do
    # train was previously unimplemented, now exact
    assert SessionLogic.route_metadata(:train).parity_status == :exact

    peace = SessionLogic.route_metadata(:guild_accept_peace)
    assert peace.group == :guild
    assert peace.dispatch == {SessionCommands.Guild, :handle_command}
    assert peace.vb6_ref =~ "HandleGuildAcceptPeace"
    assert peace.parity_status == :intentional_divergence
  end

  test "manifest covers all group-dispatched commands" do
    routes = SessionRouteManifest.routes()

    for {_group_name, commands} <- SessionRouteManifest.groups(),
        cmd <- commands do
      assert Map.has_key?(routes, cmd),
             "Command :#{cmd} is in a group but missing from @routes"
    end
  end

  test "all routes have required keys" do
    for {cmd, meta} <- SessionRouteManifest.routes() do
      assert Map.has_key?(meta, :group), ":#{cmd} missing :group"
      assert Map.has_key?(meta, :dispatch), ":#{cmd} missing :dispatch"
      assert Map.has_key?(meta, :vb6_ref), ":#{cmd} missing :vb6_ref"
      assert Map.has_key?(meta, :parity_status), ":#{cmd} missing :parity_status"
      assert meta.parity_status in SessionRouteManifest.parity_statuses(),
             ":#{cmd} has invalid parity_status: #{meta.parity_status}"
    end
  end

  test "manifest exposes the supported parity statuses" do
    assert SessionRouteManifest.parity_statuses() == [
             :exact,
             :simplified,
             :intentional_divergence,
             :unimplemented
           ]
  end
end
