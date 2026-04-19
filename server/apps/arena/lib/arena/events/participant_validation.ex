defmodule Arena.Events.ParticipantValidation do
  @moduledoc """
  Pure validation for event registration eligibility.

  Mirrors the 11 checks from VB6 `clsCaptura.cls:482-564`:
    1. Event state = registration open  (caller's responsibility)
    2. Has enough gold
    3. Not already registered
    4. Level >= min
    5. Level <= max
    6. Not in safe zone
    7. Not jailed (penalty > 0)
    8. Not dead
    9. Not trading
   10. Not mounted
   11. Not navigating

  Check #1 (event state) is enforced by the calling event module, not here.
  Check #3 (already registered) requires a set of registered IDs from the caller.

  All functions are pure — no GenServer calls, no side effects.
  """

  @typedoc "Event configuration map expected by `validate_registration/3`."
  @type event_config :: %{
          optional(:entry_fee) => non_neg_integer(),
          optional(:min_level) => pos_integer(),
          optional(:max_level) => pos_integer(),
          optional(:safe_zone) => boolean()
        }

  @doc """
  Validate whether an entity may register for an event.

  `entity` is an `AoEntities.PlayerEntity` struct (or any map with the same keys).
  `event_config` holds event-specific constraints (`:entry_fee`, `:min_level`,
  `:max_level`, `:safe_zone`).
  `registered_ids` is a `MapSet` of char_ids already registered (for the
  duplicate-registration check).

  Returns `:ok` or `{:error, reason_atom}`. The first failing check wins.
  """
  @spec validate_registration(entity :: map(), event_config :: event_config(), registered_ids :: MapSet.t()) ::
          :ok | {:error, atom()}
  def validate_registration(entity, event_config, registered_ids \\ MapSet.new()) do
    checks = [
      &check_not_dead/2,
      &check_not_jailed/2,
      &check_not_trading/2,
      &check_not_mounted/2,
      &check_not_navigating/2,
      &check_gold/2,
      &check_min_level/2,
      &check_max_level/2,
      &check_not_in_safe_zone/2,
      fn entity_inner, _config -> check_not_registered(entity_inner, registered_ids) end
    ]

    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.(entity, event_config) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # ── Individual checks (exported for granular testing) ────────────────

  @doc false
  def check_not_dead(entity, _config) do
    if entity.dead, do: {:error, :dead}, else: :ok
  end

  @doc false
  def check_not_jailed(entity, _config) do
    if entity.penalty > 0, do: {:error, :jailed}, else: :ok
  end

  @doc false
  def check_not_trading(entity, _config) do
    if entity.trade_partner_id != nil, do: {:error, :trading}, else: :ok
  end

  @doc false
  def check_not_mounted(entity, _config) do
    if entity.mounted, do: {:error, :mounted}, else: :ok
  end

  @doc false
  def check_not_navigating(entity, _config) do
    if entity.navigating, do: {:error, :navigating}, else: :ok
  end

  @doc false
  def check_gold(entity, config) do
    fee = Map.get(config, :entry_fee, 0)

    if fee > 0 and entity.gold < fee do
      {:error, :insufficient_gold}
    else
      :ok
    end
  end

  @doc false
  def check_min_level(entity, config) do
    case Map.fetch(config, :min_level) do
      {:ok, min} when entity.level < min -> {:error, :level_too_low}
      _ -> :ok
    end
  end

  @doc false
  def check_max_level(entity, config) do
    case Map.fetch(config, :max_level) do
      {:ok, max} when entity.level > max -> {:error, :level_too_high}
      _ -> :ok
    end
  end

  @doc false
  def check_not_in_safe_zone(_entity, config) do
    if Map.get(config, :safe_zone, false) do
      {:error, :in_safe_zone}
    else
      :ok
    end
  end

  @doc false
  def check_not_registered(entity, registered_ids) do
    if MapSet.member?(registered_ids, entity.char_id) do
      {:error, :already_registered}
    else
      :ok
    end
  end
end
