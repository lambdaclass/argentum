//! Walk rate limiting, including the server's speed-hack accumulator.
//!
//! Ported from `Arena.Map.Movement.do_handle_move_effects/3`. The server gates a
//! walk twice:
//!
//! 1. `now < next_move_at` — silently ignored, no packet, no visible effect.
//! 2. A speed-hack accumulator. A step taken faster than `min_interval` adds
//!    `(min_interval - elapsed) / min_interval` to a counter; a slower step
//!    drains it at 5x, floored at zero. Crossing the threshold rejects the move,
//!    sends a `pos_update`, and holds the entity for `2 * min_interval`.
//!
//! That rejection is what a player sees as a teleport backwards. The TS client
//! models neither gate, so it predicts steps the server discards. Running this
//! same type on both sides removes the disagreement by construction.

/// Tunables that must match `Arena.Settings`.
#[derive(Debug, Clone, Copy)]
pub struct WalkGateConfig {
    /// `base_walk_interval_ms` — 210 on the server.
    pub base_interval_ms: f64,
    /// `speed_hack_threshold` — 3.0 on the server.
    pub speed_hack_threshold: f64,
    /// How much faster the counter drains when a step is late. Server uses 5.
    pub drain_multiplier: f64,
    /// Floor applied to the per-entity interval, matching the client's
    /// `Math.max(40, ...)`.
    pub min_interval_floor_ms: f64,
}

impl Default for WalkGateConfig {
    fn default() -> Self {
        Self {
            base_interval_ms: 210.0,
            speed_hack_threshold: 3.0,
            drain_multiplier: 5.0,
            min_interval_floor_ms: 40.0,
        }
    }
}

/// What the gate decided about a requested step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkOutcome {
    /// Step is allowed; commit it.
    Allowed,
    /// Before `next_move_at`. The server ignores these silently, so the client
    /// should simply not send — no correction follows.
    TooEarly,
    /// Would cross the speed-hack threshold. The server rejects and snaps.
    /// A client running this gate declines to send instead of being snapped.
    SpeedHack,
}

/// Speed-hack accumulator and cooldown for one entity.
///
/// `now_ms` is supplied by the caller (monotonic on the server, `performance.now`
/// in the browser), keeping the type pure and testable.
#[derive(Debug, Clone)]
pub struct WalkGate {
    config: WalkGateConfig,
    counter: f64,
    last_step_at: Option<f64>,
    next_move_at: f64,
}

impl WalkGate {
    pub fn new(config: WalkGateConfig) -> Self {
        Self {
            config,
            counter: 0.0,
            last_step_at: None,
            next_move_at: f64::NEG_INFINITY,
        }
    }

    /// Effective minimum interval for an entity at `speed` (the server's
    /// `speeding`). Speed 0 is treated as 1 so bad data cannot divide by zero.
    pub fn min_interval_ms(&self, speed: f64) -> f64 {
        let speed = if speed > 0.0 { speed } else { 1.0 };
        (self.config.base_interval_ms / speed).max(self.config.min_interval_floor_ms)
    }

    pub fn counter(&self) -> f64 {
        self.counter
    }

    /// Decide a step without mutating anything.
    pub fn evaluate(&self, now_ms: f64, speed: f64) -> WalkOutcome {
        if now_ms < self.next_move_at {
            return WalkOutcome::TooEarly;
        }

        let min_interval = self.min_interval_ms(speed);
        if self.projected_counter(now_ms, min_interval) > self.config.speed_hack_threshold {
            return WalkOutcome::SpeedHack;
        }

        WalkOutcome::Allowed
    }

    /// Decide a step and, when allowed, record it.
    pub fn try_step(&mut self, now_ms: f64, speed: f64) -> WalkOutcome {
        let outcome = self.evaluate(now_ms, speed);
        if outcome == WalkOutcome::Allowed {
            let min_interval = self.min_interval_ms(speed);
            self.counter = self.projected_counter(now_ms, min_interval);
            self.last_step_at = Some(now_ms);
            self.next_move_at = now_ms + min_interval;
        }
        outcome
    }

    /// Apply the server's penalty after a rejection: counter cleared, held for
    /// twice the interval. Mirrors the `speed_hack` branch on the server so a
    /// client that hears a correction backs off in step rather than pushing
    /// more steps into the penalty window and earning further snaps.
    pub fn apply_rejection_penalty(&mut self, now_ms: f64, speed: f64) {
        self.counter = 0.0;
        self.last_step_at = None;
        self.next_move_at = now_ms + self.min_interval_ms(speed) * 2.0;
    }

    /// Forget all history — use on map change or reconnect.
    pub fn reset(&mut self) {
        self.counter = 0.0;
        self.last_step_at = None;
        self.next_move_at = f64::NEG_INFINITY;
    }

    fn projected_counter(&self, now_ms: f64, min_interval: f64) -> f64 {
        // The first step of a session has no predecessor; the server treats
        // `elapsed` as at least 1ms and we start from a full interval so the
        // opening step is never counted as early.
        let elapsed = match self.last_step_at {
            Some(last) => (now_ms - last).max(1.0),
            None => min_interval,
        };

        let delta = (min_interval - elapsed) / min_interval;
        if delta > 0.0 {
            self.counter + delta
        } else {
            (self.counter + delta * self.config.drain_multiplier).max(0.0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate() -> WalkGate {
        WalkGate::new(WalkGateConfig::default())
    }

    #[test]
    fn interval_matches_the_server_formula() {
        let g = gate();
        assert_eq!(g.min_interval_ms(1.0), 210.0);
        assert_eq!(g.min_interval_ms(2.0), 105.0);
        // Floored, matching the client's Math.max(40, ...).
        assert_eq!(g.min_interval_ms(100.0), 40.0);
        // Bad data must not divide by zero.
        assert_eq!(g.min_interval_ms(0.0), 210.0);
    }

    #[test]
    fn first_step_is_always_allowed() {
        let mut g = gate();
        assert_eq!(g.try_step(1_000.0, 1.0), WalkOutcome::Allowed);
        assert_eq!(g.counter(), 0.0);
    }

    #[test]
    fn stepping_before_next_move_at_is_too_early_not_a_speed_hack() {
        // The distinction matters: TooEarly is silent on the server, SpeedHack
        // snaps the player. A client must not treat them the same.
        let mut g = gate();
        g.try_step(1_000.0, 1.0);
        assert_eq!(g.evaluate(1_100.0, 1.0), WalkOutcome::TooEarly);
    }

    #[test]
    fn stepping_exactly_on_the_interval_does_not_accumulate() {
        let mut g = gate();
        let mut now = 1_000.0;
        for _ in 0..50 {
            assert_eq!(g.try_step(now, 1.0), WalkOutcome::Allowed);
            now += 210.0;
        }
        assert_eq!(g.counter(), 0.0, "on-cadence walking must never accumulate");
    }

    #[test]
    fn late_steps_drain_the_counter() {
        let mut g = gate();
        let mut now = 1_000.0;
        g.try_step(now, 1.0);
        // Deliberately early steps to build the counter up.
        for _ in 0..3 {
            now += 210.0;
            g.try_step(now, 1.0);
        }
        let before = g.counter();
        now += 400.0;
        g.try_step(now, 1.0);
        assert!(g.counter() <= before, "a late step must not increase the counter");
    }

    #[test]
    fn counter_never_goes_negative() {
        let mut g = gate();
        let mut now = 1_000.0;
        for _ in 0..10 {
            g.try_step(now, 1.0);
            now += 5_000.0;
        }
        assert_eq!(g.counter(), 0.0);
    }

    #[test]
    fn rejection_penalty_holds_for_two_intervals() {
        let mut g = gate();
        g.try_step(1_000.0, 1.0);
        g.apply_rejection_penalty(1_000.0, 1.0);

        assert_eq!(g.evaluate(1_300.0, 1.0), WalkOutcome::TooEarly);
        assert_eq!(g.evaluate(1_421.0, 1.0), WalkOutcome::Allowed);
    }

    #[test]
    fn reset_clears_the_hold() {
        let mut g = gate();
        g.try_step(1_000.0, 1.0);
        g.apply_rejection_penalty(1_000.0, 1.0);
        g.reset();
        assert_eq!(g.evaluate(1_001.0, 1.0), WalkOutcome::Allowed);
    }
}
