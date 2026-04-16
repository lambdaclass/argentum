defmodule AoTcpGateway.SessionSplitTest do
  @moduledoc """
  Characterization tests to verify the SessionLogic module split.
  These tests verify that the new sub-modules exist and export the expected functions,
  and that SessionLogic still delegates correctly.
  """
  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogin
  alias AoTcpGateway.SessionWorld
  alias AoTcpGateway.SessionTransfer
  alias AoTcpGateway.SessionPersistence
  alias AoTcpGateway.SessionLogic

  describe "SessionLogin module" do
    test "exists and exports login_new/2" do
      assert function_exported?(SessionLogin, :login_new, 2)
    end

    test "exists and exports login_existing/3" do
      assert function_exported?(SessionLogin, :login_existing, 3)
    end
  end

  describe "SessionWorld module" do
    test "exists and exports enter_world/3" do
      assert function_exported?(SessionWorld, :enter_world, 3)
    end

    test "exists and exports ensure_map_started/1" do
      assert function_exported?(SessionWorld, :ensure_map_started, 1)
    end

    test "exports inventory_login_packets/1" do
      assert function_exported?(SessionWorld, :inventory_login_packets, 1)
    end

    test "exports exp_login_packets/1" do
      assert function_exported?(SessionWorld, :exp_login_packets, 1)
    end

    test "exports spell_login_packets/1" do
      assert function_exported?(SessionWorld, :spell_login_packets, 1)
    end

    test "exports skill_login_packets/1" do
      assert function_exported?(SessionWorld, :skill_login_packets, 1)
    end
  end

  describe "SessionTransfer module" do
    test "exists and exports transfer/5" do
      assert function_exported?(SessionTransfer, :transfer, 5)
    end

    test "exports handle_hogar_check/2" do
      assert function_exported?(SessionTransfer, :handle_hogar_check, 2)
    end

    test "exports handle_hogar_check/3" do
      assert function_exported?(SessionTransfer, :handle_hogar_check, 3)
    end

    test "exports cancel_hogar/1" do
      assert function_exported?(SessionTransfer, :cancel_hogar, 1)
    end

    test "exports maybe_cancel_hogar/1" do
      assert function_exported?(SessionTransfer, :maybe_cancel_hogar, 1)
    end

    test "exports handle_hogar_arrive/2" do
      assert function_exported?(SessionTransfer, :handle_hogar_arrive, 2)
    end
  end

  describe "SessionPersistence module" do
    test "exists and exports cleanup/1" do
      assert function_exported?(SessionPersistence, :cleanup, 1)
    end

    test "exists and exports autosave/1" do
      assert function_exported?(SessionPersistence, :autosave, 1)
    end
  end

  describe "SessionLogic delegates correctly" do
    test "handle_command/2 still exported" do
      assert function_exported?(SessionLogic, :handle_command, 2)
    end

    test "login_new/2 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :login_new, 2)
    end

    test "login_existing/3 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :login_existing, 3)
    end

    test "cleanup/1 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :cleanup, 1)
    end

    test "autosave/1 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :autosave, 1)
    end

    test "transfer/5 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :transfer, 5)
    end

    test "enter_world/3 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :enter_world, 3)
    end

    test "handle_hogar_check/2 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :handle_hogar_check, 2)
    end

    test "handle_hogar_arrive/2 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :handle_hogar_arrive, 2)
    end

    test "cancel_hogar/1 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :cancel_hogar, 1)
    end

    test "maybe_cancel_hogar/1 still exported on SessionLogic (public API)" do
      assert function_exported?(SessionLogic, :maybe_cancel_hogar, 1)
    end
  end
end
