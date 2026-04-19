defmodule Mix.Tasks.Parity.AuditTest do
  use ExUnit.Case, async: true

  @moduletag :parity_audit

  test "mix parity.audit runs without error" do
    Mix.Task.rerun("parity.audit", [])
  end

  test "mix parity.audit --verbose runs without error" do
    Mix.Task.rerun("parity.audit", ["--verbose"])
  end

  test "mix parity.audit --status exact filters correctly" do
    Mix.Task.rerun("parity.audit", ["--status", "exact"])
  end
end
