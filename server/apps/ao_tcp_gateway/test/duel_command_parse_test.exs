defmodule AoTcpGateway.DuelCommandParseTest do
  @moduledoc """
  Tests for duel (reto) command parsing in session_logic.

  VB6 commands: /RETAR <name> <bet>, /ACEPTAR <name>, /CANCELAR, /ABANDONAR
  """

  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic

  describe "parse_duel_command/1 — /RETAR" do
    test "parses valid /RETAR with name and bet" do
      assert {:retar, "Gandalf", 5000} = SessionLogic.parse_duel_command("/RETAR Gandalf 5000")
    end

    test "parses /retar case-insensitively" do
      assert {:retar, "Player1", 100} = SessionLogic.parse_duel_command("/retar Player1 100")
    end

    test "rejects /RETAR without bet" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/RETAR Gandalf")
    end

    test "rejects /RETAR with non-numeric bet" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/RETAR Gandalf abc")
    end

    test "rejects /RETAR with zero bet" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/RETAR Gandalf 0")
    end

    test "rejects /RETAR with negative bet" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/RETAR Gandalf -100")
    end
  end

  describe "parse_duel_command/1 — /ACEPTAR" do
    test "parses valid /ACEPTAR with name" do
      assert {:aceptar, "Gandalf"} = SessionLogic.parse_duel_command("/ACEPTAR Gandalf")
    end

    test "parses /aceptar case-insensitively" do
      assert {:aceptar, "Player1"} = SessionLogic.parse_duel_command("/aceptar Player1")
    end

    test "rejects /ACEPTAR without name" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/ACEPTAR ")
    end
  end

  describe "parse_duel_command/1 — /CANCELAR" do
    test "parses /CANCELAR" do
      assert :cancelar_reto = SessionLogic.parse_duel_command("/CANCELAR")
    end

    test "parses /cancelar case-insensitively" do
      assert :cancelar_reto = SessionLogic.parse_duel_command("/cancelar")
    end
  end

  describe "parse_duel_command/1 — /ABANDONAR" do
    test "parses /ABANDONAR" do
      assert :abandonar_reto = SessionLogic.parse_duel_command("/ABANDONAR")
    end

    test "parses /abandonar case-insensitively" do
      assert :abandonar_reto = SessionLogic.parse_duel_command("/abandonar")
    end
  end

  describe "parse_duel_command/1 — non-duel commands" do
    test "returns :not_duel_command for regular chat" do
      assert :not_duel_command = SessionLogic.parse_duel_command("hello world")
    end

    test "returns :not_duel_command for other slash commands" do
      assert :not_duel_command = SessionLogic.parse_duel_command("/GRUPO invite Player1")
    end
  end
end
