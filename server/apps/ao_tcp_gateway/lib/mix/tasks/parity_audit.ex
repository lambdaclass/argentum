defmodule Mix.Tasks.Parity.Audit do
  @moduledoc """
  Reports VB6 parity coverage across the codebase.

  ## Usage

      mix parity.audit [--verbose] [--status STATUS]

  Options:
    --verbose   Show individual route details, not just summary counts
    --status    Filter routes by parity status (exact, simplified,
                intentional_divergence, unimplemented)

  ## What it checks

  1. **Route manifest** — `SessionRouteManifest` routes and their parity status.
  2. **Untracked commands** — `SessionLogic.handle_command` clauses that are NOT
     yet in the route manifest.
  3. **Domain modules** — Scans `@doc` annotations in parity-sensitive arena
     modules for VB6 source references.
  """

  use Mix.Task

  @shortdoc "Report VB6 parity status across route manifest and domain modules"

  @parity_modules [
    {Arena.Map.Social, "social.ex"},
    {Arena.Map.NpcInteraction, "npc_interaction.ex"},
    {Arena.Map.Healing, "healing.ex"},
    {Arena.Map.Crafting, "crafting.ex"},
    {Arena.Map.Faction, "faction.ex"},
    {Arena.Map.CombatHandlers, "combat_handlers.ex"},
    {Arena.Map.Pets, "pets.ex"},
    {Arena.Map.QuestHandlers, "quest_handlers.ex"},
    {Arena.Combat, "combat.ex"}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [verbose: :boolean, status: :string],
        aliases: [v: :verbose, s: :status]
      )

    verbose = Keyword.get(opts, :verbose, false)
    status_filter = parse_status_filter(opts)

    Mix.Task.run("compile", ["--no-start"])

    IO.puts("\n=== VB6 Parity Audit ===\n")

    manifest_report(verbose, status_filter)
    IO.puts("")
    untracked_commands_report()
    IO.puts("")
    domain_vb6_refs_report(verbose)
    IO.puts("")
    summary()
  end

  # ── Route manifest ──────────────────────────────────────────────────

  defp manifest_report(verbose, status_filter) do
    routes = AoTcpGateway.SessionRouteManifest.routes()

    filtered =
      if status_filter do
        Enum.filter(routes, fn {_cmd, meta} -> meta.parity_status == status_filter end)
      else
        Enum.to_list(routes)
      end

    by_status = Enum.group_by(filtered, fn {_cmd, meta} -> meta.parity_status end)

    IO.puts("## Route Manifest (#{map_size(routes)} declared routes)")

    for status <- [:exact, :simplified, :intentional_divergence, :unimplemented] do
      entries = Map.get(by_status, status, [])
      IO.puts("  #{status}: #{length(entries)}")

      if verbose do
        for {cmd, meta} <- Enum.sort_by(entries, fn {cmd, _} -> cmd end) do
          IO.puts("    - :#{cmd} → #{meta.vb6_ref}")
        end
      end
    end
  end

  # ── Untracked commands ─────────────────────────────────────────────

  defp untracked_commands_report do
    manifest_routes = AoTcpGateway.SessionRouteManifest.routes()
    groups = AoTcpGateway.SessionRouteManifest.groups()
    all_group_commands = groups |> Map.values() |> List.flatten() |> MapSet.new()

    # Commands that are in groups (dispatched by group guard) but not in @routes
    grouped_not_routed =
      all_group_commands
      |> MapSet.difference(MapSet.new(Map.keys(manifest_routes)))
      |> MapSet.to_list()
      |> Enum.sort()

    # Known direct-dispatch commands from SessionLogic (hardcoded from source analysis)
    direct_commands = [
      :walk, :change_heading, :left_click, :request_position_update,
      :pick_up, :drop, :move_item, :equip_item, :use_item,
      :attack, :cast_spell, :safe_toggle, :rest, :meditate,
      :heal, :resucitate, :request_atributes, :request_skills,
      :request_mini_stats, :request_stats, :modify_skills,
      :change_description, :spell_info, :move_spell, :double_click,
      :train_list, :request_account_state, :work, :work_left_click,
      :train, :craft_blacksmith, :craft_carpenter, :craft_alchemy,
      :craft_tailor, :pet_stand, :pet_follow, :pet_leave,
      :pet_leave_all, :pet_follow_all, :party_safe_toggle,
      :use_spell_macro, :home, :leave_faction, :online,
      :online_royal_army, :online_chaos_legion, :gamble, :forgive,
      :arena_entry, :reward, :punishments, :denounce, :donate_gold,
      :transfer_gold, :forum_post, :help, :request_motd, :uptime
    ]

    direct_not_routed =
      direct_commands
      |> Enum.reject(&Map.has_key?(manifest_routes, &1))
      |> Enum.sort()

    total_untracked = length(grouped_not_routed) + length(direct_not_routed)

    IO.puts("## Untracked Commands (#{total_untracked} without parity metadata)")

    if grouped_not_routed != [] do
      IO.puts("  Group-dispatched but no @routes entry (#{length(grouped_not_routed)}):")
      for cmd <- grouped_not_routed, do: IO.puts("    - :#{cmd}")
    end

    if direct_not_routed != [] do
      IO.puts("  Direct-dispatched but no @routes entry (#{length(direct_not_routed)}):")
      for cmd <- direct_not_routed, do: IO.puts("    - :#{cmd}")
    end
  end

  # ── Domain VB6 refs ────────────────────────────────────────────────

  defp domain_vb6_refs_report(verbose) do
    IO.puts("## Domain Module VB6 References")

    results =
      for {mod, filename} <- @parity_modules do
        {public_count, vb6_count} = count_vb6_refs(mod)
        {mod, filename, public_count, vb6_count}
      end

    for {_mod, filename, public_count, vb6_count} <- results do
      coverage = if public_count > 0, do: round(vb6_count / public_count * 100), else: 0
      marker = if coverage < 50, do: " ⚠", else: ""

      IO.puts(
        "  #{String.pad_trailing(filename, 28)} #{vb6_count}/#{public_count} public fns with VB6 ref (#{coverage}%)#{marker}"
      )
    end

    if verbose do
      IO.puts("")

      for {mod, filename, _pub, _vb6} <- results do
        missing = functions_missing_vb6_ref(mod)

        if missing != [] do
          IO.puts("  #{filename} — missing VB6 refs:")
          for {name, arity} <- missing, do: IO.puts("    - #{name}/#{arity}")
        end
      end
    end
  end

  # ── Summary ────────────────────────────────────────────────────────

  defp summary do
    routes = AoTcpGateway.SessionRouteManifest.routes()
    by_status = Enum.group_by(routes, fn {_cmd, meta} -> meta.parity_status end)

    exact = length(Map.get(by_status, :exact, []))
    simplified = length(Map.get(by_status, :simplified, []))
    diverged = length(Map.get(by_status, :intentional_divergence, []))
    unimpl = length(Map.get(by_status, :unimplemented, []))

    total_refs =
      Enum.reduce(@parity_modules, 0, fn {mod, _}, acc ->
        {_pub, vb6} = count_vb6_refs(mod)
        acc + vb6
      end)

    total_pub =
      Enum.reduce(@parity_modules, 0, fn {mod, _}, acc ->
        {pub, _vb6} = count_vb6_refs(mod)
        acc + pub
      end)

    IO.puts("## Summary")
    IO.puts("  Routes tracked:  #{map_size(routes)}")
    IO.puts("    exact:         #{exact}")
    IO.puts("    simplified:    #{simplified}")
    IO.puts("    divergence:    #{diverged}")
    IO.puts("    unimplemented: #{unimpl}")
    IO.puts("  Domain VB6 refs: #{total_refs}/#{total_pub} public functions")

    coverage = if total_pub > 0, do: round(total_refs / total_pub * 100), else: 0
    IO.puts("  Overall domain coverage: #{coverage}%")
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp parse_status_filter(opts) do
    case Keyword.get(opts, :status) do
      nil -> nil
      s -> String.to_existing_atom(s)
    end
  rescue
    ArgumentError -> nil
  end

  defp count_vb6_refs(mod) do
    docs = fetch_docs(mod)

    public_fns =
      mod.__info__(:functions)
      |> Enum.reject(fn {name, _} -> String.starts_with?(Atom.to_string(name), "__") end)
      |> Enum.uniq_by(fn {name, _arity} -> name end)

    vb6_fns =
      Enum.count(public_fns, fn {name, arity} ->
        doc = get_fn_doc(docs, name, arity)
        doc != nil and String.contains?(doc, "VB6")
      end)

    {length(public_fns), vb6_fns}
  rescue
    _ -> {0, 0}
  end

  defp functions_missing_vb6_ref(mod) do
    docs = fetch_docs(mod)

    mod.__info__(:functions)
    |> Enum.reject(fn {name, _} -> String.starts_with?(Atom.to_string(name), "__") end)
    |> Enum.uniq_by(fn {name, _arity} -> name end)
    |> Enum.reject(fn {name, arity} ->
      doc = get_fn_doc(docs, name, arity)
      doc != nil and String.contains?(doc, "VB6")
    end)
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp fetch_docs(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, _, _, docs} -> docs
      _ -> []
    end
  rescue
    _ -> []
  end

  defp get_fn_doc(docs, name, arity) do
    Enum.find_value(docs, fn
      {{:function, ^name, a}, _, _, %{"en" => doc}, _} when a == arity -> doc
      {{:function, ^name, _a}, _, _, %{"en" => doc}, _} -> doc
      _ -> nil
    end)
  end
end
