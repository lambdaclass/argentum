//! What the host can do, as narrow services rather than conditional compilation.
//!
//! Before this module, `#[cfg(target_arch = "wasm32")]` appeared in eight files,
//! including three that draw the interface. Two of them had grown *identical*
//! `document_hidden()` pairs and one had its own `now_ms()`, because a UI system that
//! needs to know whether the page is in the foreground had nowhere to ask. That is how a
//! platform detail becomes six platform details that can disagree.
//!
//! The rule this module exists to make possible: gameplay and UI systems ask a service
//! what the host can do and get a typed answer. They never ask which architecture they
//! were compiled for. `cfg` belongs to the adapters — today the ones at the bottom of
//! this file, and from W-0016 onward a browser host boundary that owns the whole set.
//!
//! ## Why the services are narrow
//!
//! One `Platform` trait with twenty methods forces every fake in every test to implement
//! twenty methods, and forces a caller that wants the clock to depend on the clipboard.
//! Each capability here is its own trait with the smallest surface the client actually
//! uses, and [`Platform`] is a bundle of them that a system can ask for by part.
//!
//! ## Why capabilities are values, not booleans
//!
//! "Can I go fullscreen?" has four different answers on the web — yes, the host has no
//! such concept, the user has refused, and the host has it but not right now — and a
//! `bool` collapses the last three into "no" with no way to tell a player which one they
//! are looking at. [`Support`] keeps them apart, because the interface has to say
//! something different for each.

use bevy::prelude::*;
use std::sync::Arc;

/// Whether a capability can be used, and if not, why not.
///
/// The distinction is not academic: a player whose browser cannot do something needs a
/// different sentence from one who declined a permission prompt, and both need a
/// different sentence from "this needs a gesture you have not made yet". Collapsing them
/// into `false` is how an interface ends up telling someone to change a setting that does
/// not exist.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Support {
    /// Usable now.
    Available,
    /// The host has no such facility at all. Nothing the player does will change it.
    Unsupported,
    /// The host has it and the player, or their configuration, has refused.
    Denied,
    /// The host has it and it cannot be used at this moment — a missing user gesture, a
    /// document that is not focused, storage that is full. The reason is a key rather
    /// than a sentence, because it is shown to a player and has to be translated.
    Unavailable { reason_key: &'static str },
}

impl Support {
    pub fn is_available(&self) -> bool {
        matches!(self, Support::Available)
    }

    /// Whether asking again could plausibly succeed.
    ///
    /// `Unsupported` and `Denied` are settled: retrying is how an interface ends up in a
    /// loop that a player cannot break out of. `Unavailable` is the one worth another
    /// attempt, because the condition it names is the kind that changes.
    pub fn is_worth_retrying(&self) -> bool {
        matches!(self, Support::Unavailable { .. })
    }

    /// What to tell the player, as a key.
    pub fn explanation_key(&self) -> Option<&'static str> {
        match self {
            Support::Available => None,
            Support::Unsupported => Some("platform.unsupported"),
            Support::Denied => Some("platform.denied"),
            Support::Unavailable { reason_key } => Some(reason_key),
        }
    }
}

/// How the host is presenting the client.
///
/// Mirrors `ui::topbar::HostMode` deliberately rather than importing it: the window
/// service is a platform concern and the top bar is a picture of it, and a service that
/// depends on the interface it serves cannot be faked in a test that has no interface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WindowMode {
    #[default]
    Windowed,
    Maximized,
    Fullscreen,
}

/// Wall-clock time and page visibility: the two host facts the interface reads every
/// frame.
///
/// Together because they are read together — a client that is not being looked at should
/// not be timing pings — and because keeping them apart is what produced two copies of
/// `document_hidden` and one of `now_ms`.
pub trait HostClock: Send + Sync + 'static {
    /// Milliseconds since the epoch, or 0.0 where the host has no clock the client is
    /// allowed to read. Callers that need a duration must take two readings rather than
    /// trusting the absolute value.
    fn now_ms(&self) -> f64;

    /// Whether the client is currently being displayed at all.
    ///
    /// A hidden page is throttled by the browser to something like a frame a minute, so
    /// work scheduled from it arrives in bursts long after it was asked for. Systems that
    /// poll anything ask this first.
    fn is_visible(&self) -> bool;
}

/// The window the client is drawn into, as the host sees it.
pub trait HostWindow: Send + Sync + 'static {
    fn mode(&self) -> WindowMode;

    /// Whether this host can be asked for `mode`, and if not, why not.
    fn supports(&self, mode: WindowMode) -> Support;

    /// The presentation box the host has given the client — CSS-pixel size and device
    /// pixel ratio — when the host has an opinion about it.
    fn presentation_box(&self) -> Option<(Vec2, f32)>;
}

/// One-shot document fetches.
///
/// Not a general HTTP client: the client asks for a handful of documents by URL and this
/// is the whole surface. Started-then-claimed rather than `async fn`, because the caller
/// is a Bevy system that cannot await, and because a boxed async trait method needs a
/// runtime the wasm build does not have.
///
/// The shape matters beyond convenience. The code this replaces spawned a detached task
/// that wrote the answer into an `Arc<Mutex<_>>` the interface also read, so a fetch's
/// result reached the screen through a side channel no system declared. Now the request
/// is started by a system and claimed by a system, and the flow is visible in the
/// schedule.
pub trait HostHttp: Send + Sync + 'static {
    /// Start fetching `url` as text. The handle is how the answer is recognised.
    fn get_text(&self, url: &str) -> RequestId;

    /// Take whatever finished since the last call.
    ///
    /// Draining rather than peeking, so two systems cannot both act on one answer, and
    /// so an answer nobody claimed does not accumulate forever.
    fn take_outcomes(&self) -> Vec<Outcome>;
}

/// A fetch in flight.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RequestId(pub u64);

/// A finished fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub id: RequestId,
    pub result: Result<String, FetchError>,
}

/// Why a fetch did not return a document.
///
/// Two variants rather than a string because the callers that matter branch on them: a
/// transport failure is worth asking again, an answer the client cannot parse is not, and
/// a client that retries the second hammers a broken endpoint forever.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    /// The host cannot fetch at all.
    Unsupported,
    /// It never completed: no route, closed document, refused connection.
    Transport(String),
}

impl FetchError {
    pub fn is_worth_retrying(&self) -> bool {
        matches!(self, FetchError::Transport(_))
    }
}

/// Every service the client has, behind one resource.
///
/// Bundled so a system can take `Res<Platform>` and reach the part it needs, and cloned
/// cheaply because Bevy resources are owned and the services are shared. `Arc<dyn _>`
/// rather than generics because the alternative is a type parameter threaded through
/// every plugin that touches the host.
#[derive(Resource, Clone)]
pub struct Platform {
    pub clock: Arc<dyn HostClock>,
    pub window: Arc<dyn HostWindow>,
    pub http: Arc<dyn HostHttp>,
}

impl Platform {
    /// The services this build actually has.
    ///
    /// One place, so a test can substitute the whole host and a system never has to know
    /// which host it got.
    pub fn host() -> Self {
        Self {
            clock: Arc::new(host::Clock),
            window: Arc::new(host::Window),
            http: Arc::new(host::Http::default()),
        }
    }
}

#[cfg(test)]
impl Platform {
    /// A host whose clock and visibility a test decides.
    ///
    /// Test-only, and the reason the clock is its own trait: a test about the frame-rate
    /// readout has an opinion about whether the page is visible and none at all about the
    /// clipboard, so it substitutes one service and inherits the rest.
    /// A host that reports `fullscreen` support however a test needs it.
    pub fn with_fullscreen(support: Support) -> Self {
        struct Fixed(Support);

        impl HostWindow for Fixed {
            fn mode(&self) -> WindowMode {
                WindowMode::Windowed
            }

            fn supports(&self, mode: WindowMode) -> Support {
                match mode {
                    WindowMode::Fullscreen => self.0.clone(),
                    _ => Support::Available,
                }
            }

            fn presentation_box(&self) -> Option<(Vec2, f32)> {
                None
            }
        }

        Self { window: Arc::new(Fixed(support)), ..Self::host() }
    }

    pub fn with_clock(now_ms: f64, visible: bool) -> Self {
        struct Fixed {
            now_ms: f64,
            visible: bool,
        }

        impl HostClock for Fixed {
            fn now_ms(&self) -> f64 {
                self.now_ms
            }

            fn is_visible(&self) -> bool {
                self.visible
            }
        }

        Self { clock: Arc::new(Fixed { now_ms, visible }), ..Self::host() }
    }
}

/// Installs the host services.
pub struct PlatformPlugin;

impl Plugin for PlatformPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(Platform::host());
    }
}

/// The adapters. Every `cfg(target_arch)` in the platform boundary is inside this module,
/// which is the whole point of the module existing.
mod host {
    use super::*;

    pub struct Clock;

    impl HostClock for Clock {
        #[cfg(target_arch = "wasm32")]
        fn now_ms(&self) -> f64 {
            js_sys::Date::now()
        }

        #[cfg(not(target_arch = "wasm32"))]
        fn now_ms(&self) -> f64 {
            // Native has no page clock the rest of the client agrees on yet, and a
            // plausible-looking wrong time is worse than an obvious zero: callers treat
            // 0.0 as "no clock" and skip timing rather than reporting nonsense.
            0.0
        }

        #[cfg(target_arch = "wasm32")]
        fn is_visible(&self) -> bool {
            !web_sys::window().and_then(|w| w.document()).map(|d| d.hidden()).unwrap_or(false)
        }

        #[cfg(not(target_arch = "wasm32"))]
        fn is_visible(&self) -> bool {
            true
        }
    }

    /// Fetches, and the answers waiting to be claimed.
    ///
    /// The queue is a module-level static rather than state on this struct because a
    /// browser fetch is a detached task that cannot borrow the service that started it.
    #[derive(Default)]
    pub struct Http {
        next: std::sync::atomic::AtomicU64,
    }

    static FINISHED: std::sync::Mutex<Vec<Outcome>> = std::sync::Mutex::new(Vec::new());

    #[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
    fn finish(outcome: Outcome) {
        if let Ok(mut queue) = FINISHED.lock() {
            queue.push(outcome);
        }
    }

    impl HostHttp for Http {
        fn get_text(&self, url: &str) -> RequestId {
            let id = RequestId(self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));

            #[cfg(target_arch = "wasm32")]
            {
                let url = url.to_string();
                wasm_bindgen_futures::spawn_local(async move {
                    let result =
                        crate::net::fetch_text_public(&url).await.map_err(FetchError::Transport);
                    finish(Outcome { id, result });
                });
            }

            #[cfg(not(target_arch = "wasm32"))]
            {
                // Native has no fetch of its own yet, and saying so immediately is better
                // than a request that never answers: the caller sees a failure it can
                // classify instead of a permanently pending handle.
                let _ = url;
                finish(Outcome { id, result: Err(FetchError::Unsupported) });
            }

            id
        }

        fn take_outcomes(&self) -> Vec<Outcome> {
            match FINISHED.lock() {
                Ok(mut queue) => std::mem::take(&mut *queue),
                Err(_) => Vec::new(),
            }
        }
    }

    pub struct Window;

    impl HostWindow for Window {
        #[cfg(target_arch = "wasm32")]
        fn mode(&self) -> WindowMode {
            use wasm_bindgen::JsCast;
            use wasm_bindgen::JsValue;

            let Some(window) = web_sys::window() else {
                return WindowMode::Windowed;
            };
            let Ok(adapter) = js_sys::Reflect::get(&window, &JsValue::from_str("aoWindow")) else {
                return WindowMode::Windowed;
            };
            let Ok(getter) = js_sys::Reflect::get(&adapter, &JsValue::from_str("getMode")) else {
                return WindowMode::Windowed;
            };
            getter
                .dyn_ref::<js_sys::Function>()
                .and_then(|f| f.call0(&adapter).ok())
                .and_then(|v| v.as_string())
                .map(|name| match name.as_str() {
                    "fullscreen" => WindowMode::Fullscreen,
                    "maximized" => WindowMode::Maximized,
                    _ => WindowMode::Windowed,
                })
                .unwrap_or(WindowMode::Windowed)
        }

        /// Native windows are managed by the desktop, not by the client.
        #[cfg(not(target_arch = "wasm32"))]
        fn mode(&self) -> WindowMode {
            WindowMode::Windowed
        }

        fn supports(&self, mode: WindowMode) -> Support {
            match mode {
                WindowMode::Windowed | WindowMode::Maximized => Support::Available,
                WindowMode::Fullscreen => {
                    #[cfg(target_arch = "wasm32")]
                    {
                        // The host has it; whether it can be entered depends on a user
                        // gesture this code cannot see. Saying `Available` and failing
                        // would be a lie, and `Unsupported` would tell a player to stop
                        // trying something that works when they click.
                        Support::Unavailable { reason_key: "platform.needs-a-gesture" }
                    }
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        Support::Unsupported
                    }
                }
            }
        }

        #[cfg(target_arch = "wasm32")]
        fn presentation_box(&self) -> Option<(Vec2, f32)> {
            let window = web_sys::window()?;
            let ratio = window.device_pixel_ratio() as f32;
            let element = window.document()?.query_selector("#shell").ok()??;
            let css = Vec2::new(element.client_width() as f32, element.client_height() as f32);
            if css.x <= 0.0 || css.y <= 0.0 || !ratio.is_finite() || ratio <= 0.0 {
                return None;
            }
            Some((css, ratio))
        }

        #[cfg(not(target_arch = "wasm32"))]
        fn presentation_box(&self) -> Option<(Vec2, f32)> {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A host that answers however a test needs it to.
    ///
    /// The reason the traits are narrow: this is the whole fake, and a test that cares
    /// about the clock does not implement the clipboard.
    #[derive(Default)]
    struct FakeClock {
        ms: f64,
        visible: bool,
    }

    impl HostClock for FakeClock {
        fn now_ms(&self) -> f64 {
            self.ms
        }

        fn is_visible(&self) -> bool {
            self.visible
        }
    }

    #[test]
    fn a_refusal_and_an_absence_are_different_answers() {
        // The distinction the whole type exists for: three ways of saying no, one of
        // which is worth trying again and two of which are not.
        assert!(Support::Available.is_available());
        assert!(!Support::Unsupported.is_available());

        assert!(!Support::Unsupported.is_worth_retrying());
        assert!(!Support::Denied.is_worth_retrying());
        assert!(Support::Unavailable { reason_key: "platform.needs-a-gesture" }.is_worth_retrying());

        // And each has something to say to the player, except the one that worked.
        assert_eq!(Support::Available.explanation_key(), None);
        assert_eq!(
            Support::Unavailable { reason_key: "platform.needs-a-gesture" }.explanation_key(),
            Some("platform.needs-a-gesture")
        );
        assert!(Support::Denied.explanation_key().is_some_and(|key| key.starts_with("platform.")));
    }

    #[test]
    fn a_test_can_replace_part_of_the_host() {
        // What the bundle is for. A system takes `Res<Platform>`; a test substitutes the
        // one service it has an opinion about and inherits the rest, and the system cannot
        // tell. That substitutability is what keeps `cfg` out of the systems.
        let mut app = App::new();
        app.insert_resource(Platform {
            clock: Arc::new(FakeClock { ms: 1_234.0, visible: false }),
            ..Platform::host()
        });

        let platform = app.world().resource::<Platform>().clone();
        assert_eq!(platform.clock.now_ms(), 1_234.0);
        assert!(!platform.clock.is_visible());
        assert_eq!(platform.window.mode(), WindowMode::Windowed);
    }

    #[test]
    fn the_host_bundle_answers_every_service_without_panicking() {
        // Native is the host where most of this is genuinely absent, and "absent" has to
        // be an answer rather than a crash — a screen that asks whether it may write a
        // token should not take the client down.
        let platform = Platform::host();

        assert_eq!(platform.window.mode(), WindowMode::Windowed);
        assert!(platform.window.supports(WindowMode::Windowed).is_available());
        // Fullscreen is the interesting one: the answer differs by host and neither
        // answer is a bare `false`.
        assert!(!platform.window.supports(WindowMode::Fullscreen).is_available());
    }

    #[test]
    fn a_host_without_a_capability_says_so_by_name() {
        // The failure mode this replaces: a `cfg(not(wasm32))` stub returning a plausible
        // value, so a native run behaves as though the host did something. Native has no
        // fullscreen path, and it says which kind of no that is.
        let platform = Platform::host();

        #[cfg(not(target_arch = "wasm32"))]
        assert_eq!(platform.window.supports(WindowMode::Fullscreen), Support::Unsupported);

        // On the web it is the other kind: the host has it and the moment is wrong,
        // which is worth another attempt after the player clicks something.
        #[cfg(target_arch = "wasm32")]
        assert!(platform.window.supports(WindowMode::Fullscreen).is_worth_retrying());

        let _ = platform;
    }

    #[test]
    fn the_platform_boundary_is_where_the_architecture_checks_live() {
        // The claim this task makes: gameplay and UI systems do not ask what they were
        // compiled for. This counts the sites that still do, so the number can only go
        // down — W-0016 owns driving it to zero when it moves the host boundary here.
        //
        // A count rather than a ban, because the sites that remain are real and this
        // task's contract is to define the services, not to migrate every caller. A
        // ratchet that records the debt is honest; a ban that fails today is a test
        // nobody can run.
        let mut remaining: Vec<(String, usize)> = Vec::new();
        for entry in [
            "hud.rs",
            "ui/shell.rs",
            "ui/topbar.rs",
            "net.rs",
            "config.rs",
            "session.rs",
            "main.rs",
            "diagnostics.rs",
        ] {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join(entry);
            let source = std::fs::read_to_string(&path).unwrap_or_default();
            let count = source.matches("target_arch = \"wasm32\"").count();
            if count > 0 {
                remaining.push((entry.to_string(), count));
            }
        }

        let total: usize = remaining.iter().map(|(_, n)| n).sum();
        assert!(
            total <= 41,
            "conditional compilation outside the platform boundary grew to {total}: {remaining:?}"
        );

        // And the two helpers that had been copied into two files each are gone from
        // both: the clock and page visibility now have one home.
        for entry in ["hud.rs", "ui/topbar.rs"] {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join(entry);
            let source = std::fs::read_to_string(&path).expect("a source file");
            assert!(
                !source.contains("fn document_hidden"),
                "{entry} still carries its own copy of document_hidden"
            );
            assert!(!source.contains("fn now_ms"), "{entry} still carries its own copy of now_ms");
        }
    }
}
