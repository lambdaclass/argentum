//! Frame rate and latency cadence.
//!
//! Both numbers are trust signals: a player reads them to decide whether a
//! stutter is their machine, the network or the server. That only works if they
//! are honest, and the two ways they lie are subtle.
//!
//! **A background frame rate is not a frame rate.** A hidden tab is throttled to
//! a few frames a second by the browser, and a client that reports that as
//! performance tells a player their machine is failing when it is idle. The
//! sample window is therefore foreground-only and restarts on restoration.
//!
//! **A suspended timer catches up.** A repeating timer ticked with a 30-second
//! delta reports six elapsed intervals, and a probe scheduled from it fires six
//! times at once — a burst aimed at the server precisely when a client wakes.
//! The schedule here fires once and starts over.
//!
//! Both are pure and take their clock as an argument, so the boundaries can be
//! tested exactly rather than approached with sleeps.

use bevy::prelude::{Component, Resource};

/// How often the frame rate is rewritten, in seconds.
pub const FPS_REFRESH_SECS: f64 = 1.0;

/// How often latency is probed, in seconds.
pub const PING_INTERVAL_SECS: f64 = 5.0;

/// Slack on a boundary comparison.
///
/// Frame times never sum to a round number: 60 frames of 1/60 lands just under
/// one second in f32. Without this the refresh is withheld for an extra frame
/// and the counter reads one low forever.
const EPSILON: f64 = 1e-6;

/// What the frame-rate field should say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FpsReading {
    /// Foreground, but a full second has not been measured yet.
    Measuring,
    /// A real foreground measurement.
    Foreground(u32),
    /// Not foreground. Carries the last foreground reading, if there was one,
    /// so the field can show it as held rather than as current.
    Background(Option<u32>),
}

/// Counts frames over a foreground second.
///
/// A component rather than a resource so the status row owns its own counter;
/// the logic below is plain data and takes its clock as an argument, which is
/// what lets the cadence boundaries be tested exactly.
#[derive(Component, Debug, Clone, Copy)]
pub struct FpsAverage {
    frames: u32,
    elapsed: f64,
    last: Option<u32>,
    foreground: bool,
}

impl Default for FpsAverage {
    fn default() -> Self {
        Self { frames: 0, elapsed: 0.0, last: None, foreground: true }
    }
}

impl FpsAverage {
    /// Tell the counter whether the window is foreground.
    ///
    /// A transition either way discards the partial sample. Going background,
    /// the frames already counted would be mixed with throttled ones; coming
    /// back, the first frame after a long pause carries a huge delta that would
    /// otherwise be averaged in as though the machine had stalled.
    pub fn set_foreground(&mut self, foreground: bool) {
        if foreground != self.foreground {
            self.foreground = foreground;
            self.restart_sample();
        }
    }

    pub fn is_foreground(&self) -> bool {
        self.foreground
    }

    fn restart_sample(&mut self) {
        self.frames = 0;
        self.elapsed = 0.0;
    }

    /// Record a frame. Returns a new reading only when one is due.
    ///
    /// `None` means "nothing to rewrite", which is the common case: at 144Hz
    /// this is 143 of every 144 calls.
    pub fn tick(&mut self, dt: f64) -> Option<FpsReading> {
        if !self.foreground {
            return None;
        }

        self.frames += 1;
        self.elapsed += dt;
        if self.elapsed + EPSILON < FPS_REFRESH_SECS {
            return None;
        }

        let rate = (self.frames as f64 / self.elapsed).round() as u32;
        self.last = Some(rate);
        self.restart_sample();
        Some(FpsReading::Foreground(rate))
    }

    /// What the field should currently show.
    pub fn reading(&self) -> FpsReading {
        if !self.foreground {
            return FpsReading::Background(self.last);
        }
        match self.last {
            Some(rate) => FpsReading::Foreground(rate),
            None => FpsReading::Measuring,
        }
    }
}

/// Text for a reading.
///
/// A held background sample is marked rather than shown bare, because an
/// unmarked stale number is indistinguishable from a current one — which is the
/// specific lie this whole module exists to avoid.
pub fn fps_label(reading: FpsReading) -> String {
    match reading {
        FpsReading::Measuring => "--".to_string(),
        FpsReading::Foreground(rate) => rate.to_string(),
        FpsReading::Background(Some(rate)) => format!("{rate} bg"),
        FpsReading::Background(None) => "bg".to_string(),
    }
}

/// Decides when a latency probe is due.
#[derive(Resource, Debug, Clone, Copy, Default)]
pub struct PingSchedule {
    elapsed: f64,
}

impl PingSchedule {
    /// Advance the schedule. Returns true at most once per call.
    ///
    /// The counter is reset rather than decremented by the interval. A
    /// decrementing schedule is "correct" in the sense that it preserves
    /// average rate, but after a 30-second suspension it owes six probes and
    /// fires them the moment the tab wakes — a burst aimed at the server
    /// exactly when a crowd of clients is waking together.
    pub fn tick(&mut self, dt: f64) -> bool {
        self.elapsed += dt.max(0.0);
        if self.elapsed + EPSILON < PING_INTERVAL_SECS {
            return false;
        }
        self.elapsed = 0.0;
        true
    }

    /// Forget any progress. Used on reconnect, where the previous schedule
    /// belonged to a socket that no longer exists.
    pub fn reset(&mut self) {
        self.elapsed = 0.0;
    }

    /// Seconds until the next probe, for diagnostics.
    pub fn remaining(&self) -> f64 {
        (PING_INTERVAL_SECS - self.elapsed).max(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frame at a given rate, in seconds.
    fn frame(hz: f64) -> f64 {
        1.0 / hz
    }

    #[test]
    fn no_second_rewrite_before_a_full_foreground_second() {
        // The cadence requirement, at the boundary rather than near it.
        let mut fps = FpsAverage::default();
        let mut rewrites = 0;

        for _ in 0..143 {
            if fps.tick(frame(144.0)).is_some() {
                rewrites += 1;
            }
        }
        assert_eq!(rewrites, 0, "rewrote before a second had passed");

        assert!(fps.tick(frame(144.0)).is_some(), "did not rewrite at one second");
    }

    #[test]
    fn the_rate_is_counted_rather_than_estimated() {
        let mut fps = FpsAverage::default();
        for _ in 0..59 {
            assert_eq!(fps.tick(frame(60.0)), None);
        }
        assert_eq!(fps.tick(frame(60.0)), Some(FpsReading::Foreground(60)));
    }

    #[test]
    fn a_severe_stutter_is_reported_rather_than_smoothed_away() {
        // Two frames in a second is 2 fps, and that is the number a player
        // needs to see.
        let mut fps = FpsAverage::default();
        fps.tick(0.5);
        assert_eq!(fps.tick(0.5), Some(FpsReading::Foreground(2)));
    }

    #[test]
    fn a_background_interval_never_becomes_a_foreground_sample() {
        // The lie this exists to prevent: a throttled tab reporting 10 fps as
        // though the machine were struggling.
        let mut fps = FpsAverage::default();
        for _ in 0..60 {
            fps.tick(frame(60.0));
        }
        assert_eq!(fps.reading(), FpsReading::Foreground(60));

        fps.set_foreground(false);
        // Throttled frames: 10Hz for three seconds.
        for _ in 0..30 {
            assert_eq!(fps.tick(0.1), None, "a background frame produced a reading");
        }

        assert_eq!(fps.reading(), FpsReading::Background(Some(60)));
    }

    #[test]
    fn a_held_background_sample_is_marked_as_held() {
        // An unmarked stale number is indistinguishable from a current one.
        assert_eq!(fps_label(FpsReading::Foreground(144)), "144");
        assert_eq!(fps_label(FpsReading::Background(Some(144))), "144 bg");
        assert_ne!(
            fps_label(FpsReading::Background(Some(144))),
            fps_label(FpsReading::Foreground(144))
        );
    }

    #[test]
    fn a_tab_that_was_never_foreground_shows_no_number_at_all() {
        let mut fps = FpsAverage::default();
        fps.set_foreground(false);
        assert_eq!(fps_label(fps.reading()), "bg");
    }

    #[test]
    fn restoration_starts_a_fresh_sample() {
        // The first frame after a long pause carries a huge delta. Averaged
        // into the previous partial sample it reads as a stall that never
        // happened.
        let mut fps = FpsAverage::default();
        for _ in 0..30 {
            fps.tick(frame(60.0));
        }

        fps.set_foreground(false);
        fps.set_foreground(true);

        // Half a second of real frames is not yet a second, because the
        // half-second measured before the pause was discarded.
        for _ in 0..30 {
            assert_eq!(fps.tick(frame(60.0)), None, "the stale partial sample survived");
        }
        for _ in 0..30 {
            fps.tick(frame(60.0));
        }
        assert_eq!(fps.reading(), FpsReading::Foreground(60));
    }

    #[test]
    fn a_long_frame_on_resume_is_not_averaged_into_the_rate() {
        let mut fps = FpsAverage::default();
        fps.set_foreground(false);
        fps.set_foreground(true);

        // 30 seconds of suspension arriving as one delta would otherwise make
        // the next reading a fraction of a frame per second.
        assert_eq!(fps.tick(30.0), Some(FpsReading::Foreground(0)));
        // And the window restarts, so the next second measures honestly.
        for _ in 0..60 {
            fps.tick(frame(60.0));
        }
        assert_eq!(fps.reading(), FpsReading::Foreground(60));
    }

    #[test]
    fn setting_the_same_foreground_state_does_not_discard_progress() {
        // Systems write this every frame from the window's state; treating each
        // write as a transition would restart the sample forever and no reading
        // would ever be produced.
        let mut fps = FpsAverage::default();
        for _ in 0..59 {
            fps.set_foreground(true);
            fps.tick(frame(60.0));
        }
        fps.set_foreground(true);
        assert!(fps.tick(frame(60.0)).is_some(), "the sample was restarted every frame");
    }

    #[test]
    fn no_probe_before_the_interval_and_exactly_one_at_it() {
        let mut schedule = PingSchedule::default();
        let mut probes = 0;

        // One frame short of five seconds at 60Hz.
        for _ in 0..(60 * 5 - 1) {
            if schedule.tick(frame(60.0)) {
                probes += 1;
            }
        }
        assert_eq!(probes, 0, "probed before five seconds");

        assert!(schedule.tick(frame(60.0)), "did not probe at five seconds");
    }

    #[test]
    fn a_thirty_second_suspension_produces_one_probe_and_not_six() {
        // The burst this schedule exists to prevent. A decrementing timer owes
        // six probes after a 30-second gap and fires them the instant the tab
        // wakes — from every client waking at once.
        let mut schedule = PingSchedule::default();
        assert!(schedule.tick(30.0), "the resumed frame should probe once");

        let mut extra = 0;
        for _ in 0..10 {
            if schedule.tick(frame(60.0)) {
                extra += 1;
            }
        }
        assert_eq!(extra, 0, "{extra} catch-up probes followed the resume");
    }

    #[test]
    fn the_schedule_holds_its_rate_over_a_long_run() {
        // Resetting rather than decrementing loses a fraction of a frame each
        // interval. Over minutes that must not drift into a materially
        // different rate.
        let mut schedule = PingSchedule::default();
        let mut probes = 0;
        let frames = 60 * 60; // one minute at 60Hz
        for _ in 0..frames {
            if schedule.tick(frame(60.0)) {
                probes += 1;
            }
        }
        assert_eq!(probes, 12, "expected one probe every five seconds over a minute");
    }

    #[test]
    fn reconnecting_resets_the_schedule() {
        // The previous schedule belonged to a socket that no longer exists;
        // carrying it over probes the new one immediately.
        let mut schedule = PingSchedule::default();
        for _ in 0..(60 * 4) {
            schedule.tick(frame(60.0));
        }
        assert!(schedule.remaining() < 2.0);

        schedule.reset();
        assert_eq!(schedule.remaining(), PING_INTERVAL_SECS);
    }

    #[test]
    fn a_negative_delta_does_not_move_the_schedule_backwards() {
        // A clock that steps back would otherwise postpone the probe forever.
        let mut schedule = PingSchedule::default();
        schedule.tick(-100.0);
        assert_eq!(schedule.remaining(), PING_INTERVAL_SECS);
    }
}
