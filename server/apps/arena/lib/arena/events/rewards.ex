defmodule Arena.Events.Rewards do
  @moduledoc """
  Pure reward computation for competitive events.

  Each function takes event results and returns a list of `{char_id, gold_amount}`
  tuples. No side effects — callers are responsible for distributing gold.

  VB6 baseline:
    - Capture: winners get entry_fee * 2, losers forfeit their fee.
    - Invasion (siege): top-10 defenders get 50_000 * gold_mult on defender win.
    - Tournament: VB6 had no automated reward; we allow a configurable prize pool.
  """

  @typedoc "A single reward entry: character id and gold amount."
  @type reward :: {char_id :: pos_integer(), gold :: non_neg_integer()}

  # ── Capture ──────────────────────────────────────────────────────────

  @doc """
  Calculate capture-event rewards.

  Winners each receive `entry_fee * 2`. Losers receive nothing (they already
  paid the entry fee, which funds the winners' purse).

  Returns `[]` when the winners list is empty or the entry fee is zero.
  """
  @spec calculate_capture_rewards(winners :: [pos_integer()], entry_fee :: non_neg_integer()) ::
          [reward()]
  def calculate_capture_rewards([], _entry_fee), do: []
  def calculate_capture_rewards(_winners, 0), do: []

  def calculate_capture_rewards(winners, entry_fee) when is_integer(entry_fee) and entry_fee > 0 do
    prize = entry_fee * 2
    Enum.map(winners, fn char_id -> {char_id, prize} end)
  end

  # ── Siege / Invasion ─────────────────────────────────────────────────

  @siege_base_reward 50_000

  @doc """
  Calculate siege (invasion) rewards.

  When defenders win, each entry in `top10` receives `#{@siege_base_reward} * gold_mult`.
  When attackers win, defenders receive nothing.

  `top10` is a list of `{char_id, score}` tuples ordered by score descending
  (only the char_id is used for reward assignment).

  Returns `[]` when attackers win, the scoreboard is empty, or gold_mult is zero.
  """
  @spec calculate_siege_rewards(
          top10 :: [{pos_integer(), number()}],
          outcome :: :defenders_win | :attackers_win,
          gold_mult :: number()
        ) :: [reward()]
  def calculate_siege_rewards(_top10, :attackers_win, _gold_mult), do: []
  def calculate_siege_rewards([], :defenders_win, _gold_mult), do: []
  def calculate_siege_rewards(_top10, :defenders_win, gold_mult)
      when is_number(gold_mult) and gold_mult <= 0 do
    []
  end

  def calculate_siege_rewards(top10, :defenders_win, gold_mult)
      when is_number(gold_mult) and gold_mult > 0 do
    reward_per_player = trunc(@siege_base_reward * gold_mult)

    Enum.map(top10, fn {char_id, _score} -> {char_id, reward_per_player} end)
  end

  # ── Tournament ───────────────────────────────────────────────────────

  @doc """
  Calculate tournament rewards.

  The winner receives the entire `prize_pool`. Returns `[]` when
  `winner_id` is nil or the prize pool is zero.
  """
  @spec calculate_tournament_rewards(
          winner_id :: pos_integer() | nil,
          prize_pool :: non_neg_integer()
        ) :: [reward()]
  def calculate_tournament_rewards(nil, _prize_pool), do: []
  def calculate_tournament_rewards(_winner_id, 0), do: []

  def calculate_tournament_rewards(winner_id, prize_pool)
      when is_integer(prize_pool) and prize_pool > 0 do
    [{winner_id, prize_pool}]
  end
end
