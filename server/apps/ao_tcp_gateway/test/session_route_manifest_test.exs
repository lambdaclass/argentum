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

    assert info.dispatch == {Arena.Map.MapServer, :information}
    assert info.vb6_ref == "Protocol.bas:HandleInformation"
    assert info.parity_status == :exact

    assert quest.dispatch == {Arena.Map.MapServer, :quest}
    assert quest.vb6_ref == "Protocol.bas:HandleQuest"
    assert quest.parity_status == :exact

    assert support.dispatch == {AoTcpGateway.SessionLogic, :handle_command}
    assert support.parity_status == :simplified
  end

  test "intentional divergences and unimplemented routes stay explicit" do
    assert SessionLogic.route_metadata(:train).parity_status == :unimplemented

    assert SessionLogic.route_metadata(:guild_accept_peace) == %{
             group: :guild,
             dispatch: {SessionCommands.Guild, :handle_command},
             vb6_ref: "Protocol.bas:guild peace accept flow",
             parity_status: :intentional_divergence
           }
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
