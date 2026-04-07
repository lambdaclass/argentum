defmodule Arena.AuditLog do
  @moduledoc """
  Structured gameplay event logging.

  All audit entries use a consistent `[AUDIT]` prefix with key=value pairs
  for easy grepping and log aggregation.
  """

  require Logger

  @doc "Log a player entering a map."
  def log_login(char_id, name, map_id) do
    Logger.info("[AUDIT] login char_id=#{char_id} name=#{name} map_id=#{map_id}")
  end

  @doc "Log a player leaving a map."
  def log_logout(char_id, name, map_id) do
    Logger.info("[AUDIT] logout char_id=#{char_id} name=#{name} map_id=#{map_id}")
  end

  @doc "Log a completed trade between two players."
  def log_trade(from_id, to_id, item_count, gold) do
    Logger.info("[AUDIT] trade from=#{from_id} to=#{to_id} items=#{item_count} gold=#{gold}")
  end

  @doc "Log a player kill."
  def log_kill(killer_id, victim_id, map_id) do
    Logger.info("[AUDIT] kill killer=#{killer_id} victim=#{victim_id} map_id=#{map_id}")
  end

  @doc "Log a GM action."
  def log_gm_action(gm_id, action, target) do
    Logger.warning("[AUDIT] gm_action gm=#{gm_id} action=#{action} target=#{target}")
  end

  @doc "Log an anti-cheat detection event."
  def log_anticheat(char_id, type, details) do
    Logger.warning("[ANTICHEAT] #{type} char_id=#{char_id} #{details}")
  end

  @doc "Log a player report (/DENUNCIAR)."
  def log_report(char_id, target_name, reason) do
    Logger.info("[REPORT] char_id=#{char_id} reported '#{target_name}': #{reason}")
  end
end
