//! What the interface is allowed to know, and what it is allowed to ask for.
//!
//! Presentation reads [`UiSnapshot`] and emits [`Intent`]. It never parses a
//! packet, never touches a socket, and never learns a packet id. That is the
//! whole point: the same screens are driven by a fixture in a test and by a
//! live session in production, and neither can tell the difference.
//!
//! Two rules this boundary enforces.
//!
//! **Server feedback crosses as a key, not a sentence.** The wire protocol
//! carries Spanish strings inherited from VB6 in places, but anywhere the
//! protocol can avoid it, feedback arrives as a [`FeedbackKey`] plus typed
//! parameters. A client that renders server prose cannot be translated, and
//! cannot tell "you lack the mana" from "you lack the skill" without matching
//! on text.
//!
//! **Nothing here is optional-shaped when it is really invalid.** A gauge whose
//! maximum is zero, a quantity that arrived negative, a slot index past the end
//! of the grid — the server should never send these, but "should never" is not
//! a guarantee, and a UI that divides by a zero maximum takes the whole client
//! down. Every accessor here is total.

/// A current-over-maximum value: health, mana, experience, a cooldown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Gauge {
    pub current: i32,
    pub max: i32,
}

impl Gauge {
    pub const fn new(current: i32, max: i32) -> Self {
        Self { current, max }
    }

    /// Fill fraction, always between 0 and 1.
    ///
    /// Total by construction. A zero maximum reads as empty rather than
    /// dividing by zero, and a current above the maximum — which the server
    /// does send transiently, mid-buff — clamps instead of overflowing the bar
    /// past its track.
    pub fn fraction(&self) -> f32 {
        if self.max <= 0 {
            return 0.0;
        }
        (self.current as f32 / self.max as f32).clamp(0.0, 1.0)
    }

    /// True when the value is at or below zero, whatever the maximum says.
    pub fn is_depleted(&self) -> bool {
        self.current <= 0
    }
}

/// The five bars, plus experience.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PlayerVitals {
    pub health: Gauge,
    pub mana: Gauge,
    pub stamina: Gauge,
    pub hunger: Gauge,
    pub thirst: Gauge,
}

impl PlayerVitals {
    /// A character with no health is dead, which changes what the interface
    /// permits rather than only how it looks.
    pub fn is_dead(&self) -> bool {
        self.health.is_depleted()
    }
}

/// Name, class, level and progress.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProgressionState {
    pub name: String,
    /// A key, not a display string: "mage" localises, "Mago" does not.
    pub class_key: String,
    pub level: u16,
    pub experience: Gauge,
    pub gold: i64,
}

/// What a rarity means for presentation, without naming a colour.
///
/// The model says what something *is*; the token layer decides what that looks
/// like. A model that carried a colour could not be re-themed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Rarity {
    #[default]
    Common,
    Uncommon,
    Rare,
    Epic,
    Legendary,
}

/// An item as the interface needs to draw it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ItemView {
    pub item_id: i32,
    /// Localisation key. The display name is the UI's problem.
    pub name_key: String,
    pub quantity: i32,
    pub equipped: bool,
    pub rarity: Rarity,
    /// Graphic index into the shared atlas.
    pub icon_grh: i32,
    /// What activating this item does.
    ///
    /// Carried, not inferred. The interface previously guessed from the stack
    /// quantity — anything not stackable was treated as equipment — which is
    /// wrong for every single-copy consumable a player owns one of, and the
    /// guess gets *worse* as their inventory empties: the last potion in a stack
    /// becomes a sword.
    pub action: ItemAction,
}

/// What activating an item does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ItemAction {
    /// Consumed: a potion, food, a scroll.
    Use,
    /// Worn or wielded.
    Equip,
    /// Opens something — a container, a book, a map.
    Open,
    /// Nothing, but it can still be moved, dropped and inspected. Quest tokens
    /// and materials.
    #[default]
    Inert,
}

impl ItemAction {
    /// Whether double-clicking should do anything at all.
    pub fn is_activatable(self) -> bool {
        !matches!(self, ItemAction::Inert)
    }

    /// The localisation key naming the action, for tooltips and prompts.
    pub fn name_key(self) -> &'static str {
        match self {
            ItemAction::Use => "item.action.use",
            ItemAction::Equip => "item.action.equip",
            ItemAction::Open => "item.action.open",
            ItemAction::Inert => "item.action.none",
        }
    }
}

impl ItemView {
    /// Quantity as it should be shown: never negative.
    ///
    /// A negative quantity means the client and server disagree, which is worth
    /// logging but not worth rendering as "-3 potions".
    pub fn display_quantity(&self) -> i32 {
        self.quantity.max(0)
    }

    /// Whether the count is worth drawing at all. A single item shows no number
    /// in any AO client; the icon is the information.
    pub fn shows_quantity(&self) -> bool {
        self.display_quantity() > 1
    }
}

/// One cell of the inventory grid.
///
/// Locked is a distinct state, not an absence. The reference client shows
/// locked slots with a padlock rather than hiding them, so a player can see
/// what expanding their pack would buy — the roadmap calls this out as one of
/// the ideas worth taking.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum SlotState {
    #[default]
    Empty,
    Locked,
    Filled(ItemView),
}

impl SlotState {
    pub fn item(&self) -> Option<&ItemView> {
        match self {
            SlotState::Filled(item) => Some(item),
            _ => None,
        }
    }

    /// Whether a drag may be dropped here.
    pub fn accepts_drop(&self) -> bool {
        !matches!(self, SlotState::Locked)
    }
}

/// The inventory grid.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct InventoryState {
    pub slots: Vec<SlotState>,
    /// Columns the grid is laid out in.
    pub columns: usize,
}

impl InventoryState {
    pub fn slot(&self, index: usize) -> &SlotState {
        // Total: an index past the end reads as empty rather than panicking.
        // Slot indices arrive from the server and from drag gestures, and
        // neither is worth crashing over.
        self.slots.get(index).unwrap_or(&SlotState::Empty)
    }

    pub fn used_slots(&self) -> usize {
        self.slots.iter().filter(|s| s.item().is_some()).count()
    }

    pub fn unlocked_slots(&self) -> usize {
        self.slots.iter().filter(|s| !matches!(s, SlotState::Locked)).count()
    }

    /// Rows needed, so the grid can be sized before it is filled.
    pub fn rows(&self) -> usize {
        if self.columns == 0 {
            return 0;
        }
        self.slots.len().div_ceil(self.columns)
    }
}

/// Where a piece of equipment sits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EquipSlot {
    Weapon,
    Shield,
    Helmet,
    Armour,
    Ring,
    Ammunition,
}

impl EquipSlot {
    /// Localisation key naming the slot, for empty slots and tooltips.
    pub fn name_key(self) -> &'static str {
        match self {
            EquipSlot::Weapon => "equip.slot.weapon",
            EquipSlot::Shield => "equip.slot.shield",
            EquipSlot::Helmet => "equip.slot.helmet",
            EquipSlot::Armour => "equip.slot.armour",
            EquipSlot::Ring => "equip.slot.ring",
            EquipSlot::Ammunition => "equip.slot.ammunition",
        }
    }

    pub const ALL: [EquipSlot; 6] = [
        EquipSlot::Weapon,
        EquipSlot::Shield,
        EquipSlot::Helmet,
        EquipSlot::Armour,
        EquipSlot::Ring,
        EquipSlot::Ammunition,
    ];
}

/// What is currently worn.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct EquipmentState {
    pub worn: Vec<(EquipSlot, ItemView)>,
}

impl EquipmentState {
    pub fn in_slot(&self, slot: EquipSlot) -> Option<&ItemView> {
        self.worn.iter().find(|(s, _)| *s == slot).map(|(_, item)| item)
    }
}

/// Why a spell cannot be cast right now.
///
/// An enum rather than a boolean, because "greyed out" is not feedback: a
/// player needs to know whether to drink a potion, train a skill, put down a
/// shield or step off the water.
///
/// The client decides all of these for *presentation* only. Final authority is
/// the server's, and it re-checks every one — a client that treats its own
/// judgement as final desynchronises the moment a rule changes on one side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SpellBlocker {
    /// The character is a ghost. Nothing else matters.
    Dead,
    InsufficientMana,
    InsufficientStamina,
    /// The skill is below the spell's requirement, which training fixes.
    InsufficientSkill,
    OnCooldown,
    /// Wants a target and has none.
    NoTarget,
    /// The target is a corpse.
    TargetDead,
    /// The target is below the level this spell may be used on, which is the
    /// newbie protection rule.
    TargetLevelTooLow,
    /// Held equipment forbids it: a shield or a two-handed weapon.
    EquipmentMask,
    /// Wrong terrain — casting from water, or at a land-only target.
    WrongTerrain,
    /// A safe zone refuses hostile actions.
    ForbiddenHere,
}

impl SpellBlocker {
    /// The one to show when several apply.
    ///
    /// Ordered by what the player can act on soonest. Being dead subsumes
    /// everything; a cooldown resolves by waiting; a skill requirement takes
    /// days. Showing the wrong one sends a player to train a skill when they
    /// only had to sheathe a shield.
    pub fn most_actionable(blockers: &[SpellBlocker]) -> Option<SpellBlocker> {
        blockers.iter().min().copied()
    }
}

/// What a spell needs pointed at it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TargetMode {
    /// Affects the caster; no selection step.
    #[default]
    SelfCast,
    /// Needs a selected entity.
    Entity,
    /// Needs a tile.
    Ground,
    /// Centred on the caster, no selection.
    Area,
}

impl TargetMode {
    /// Whether choosing this spell should arm a targeting cursor.
    pub fn needs_selection(self) -> bool {
        matches!(self, TargetMode::Entity | TargetMode::Ground)
    }
}

/// A spell in the book.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpellView {
    pub spell_id: i32,
    pub name_key: String,
    pub mana_cost: i32,
    pub stamina_cost: i32,
    pub required_skill: i32,
    pub icon_grh: i32,
    pub target_mode: TargetMode,
    /// Empty when the spell is ready.
    pub blockers: Vec<SpellBlocker>,
}

impl SpellView {
    pub fn is_castable(&self) -> bool {
        self.blockers.is_empty()
    }

    /// The reason to show, when there are several.
    pub fn primary_blocker(&self) -> Option<SpellBlocker> {
        SpellBlocker::most_actionable(&self.blockers)
    }
}

/// The spellbook.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpellbookState {
    pub spells: Vec<SpellView>,
}

/// What a hotbar slot points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotbarBinding {
    Item { item_id: i32, icon_grh: i32 },
    Spell { spell_id: i32, icon_grh: i32 },
}

/// One hotbar slot.
///
/// Not `Eq`: the cooldown is a float, and the malformed fixture deliberately
/// carries a NaN one. Deriving `Eq` on a NaN-bearing type would be a lie the
/// compiler is right to reject.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct HotbarSlotState {
    pub binding: Option<HotbarBinding>,
    /// Remaining cooldown as a fraction, 1.0 meaning just triggered.
    pub cooldown: f32,
}

impl HotbarSlotState {
    /// Cooldown clamped for drawing. A cooldown outside 0..1 would render a
    /// sweep past the edge of the slot.
    pub fn cooldown_fraction(&self) -> f32 {
        if self.cooldown.is_finite() {
            self.cooldown.clamp(0.0, 1.0)
        } else {
            0.0
        }
    }

    pub fn is_ready(&self) -> bool {
        self.binding.is_some() && self.cooldown_fraction() <= 0.0
    }
}

/// The hotbar, one page at a time.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct HotbarState {
    pub slots: Vec<HotbarSlotState>,
    pub page: usize,
    pub page_count: usize,
}

impl HotbarState {
    pub fn slot(&self, index: usize) -> HotbarSlotState {
        self.slots.get(index).copied().unwrap_or_default()
    }
}

/// What kind of thing is targeted, which decides what actions are offered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetKind {
    Player,
    Npc,
    Hostile,
    Item,
}

/// The current target.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum TargetState {
    #[default]
    None,
    Selected {
        name: String,
        kind: TargetKind,
        /// None when the server does not disclose it, which is different from
        /// full health.
        health: Option<Gauge>,
    },
}

/// Which conversation a line belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatChannel {
    Say,
    Whisper,
    Party,
    Guild,
    Faction,
    System,
}

/// One line of chat or one server message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatLine {
    pub channel: ChatChannel,
    /// Empty for system messages, which have no speaker.
    pub speaker: String,
    pub body: String,
}

/// Chat and the world-message overlay.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChatState {
    pub lines: Vec<ChatLine>,
    pub active_channel: Option<ChatChannel>,
    /// True while a text field owns the keyboard, which must suppress every
    /// world command — otherwise typing "w" walks.
    pub composing: bool,
}

/// A trainable skill.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SkillView {
    pub skill_id: i32,
    pub name_key: String,
    pub points: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SkillsState {
    pub skills: Vec<SkillView>,
    pub unspent_points: i32,
}

/// Combat safety toggles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SafetyState {
    /// Refuses attacks on other citizens.
    pub safe_mode: bool,
    /// Refuses attacks on party members.
    pub party_safe: bool,
    /// Refuses to drop items on death where the rules allow it.
    pub secure_trade: bool,
}

/// Whether a map view has anything to show, and why not when it does not.
///
/// Four states rather than an `Option`, because "not loaded yet", "this map has
/// no data" and "the fetch failed" are three different things to a player and
/// only one of them is worth retrying. An unexplained black rectangle is
/// indistinguishable from a rendering fault, which is the state the shell is in
/// today and what W-0088 and W-0089 replace.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum MapAvailability {
    /// No request has been made yet.
    #[default]
    Idle,
    /// A request is in flight.
    Loading,
    /// Data arrived and can be drawn.
    Ready,
    /// It cannot be drawn, and this is why.
    Unavailable(MapUnavailable),
}

/// Why a map cannot be drawn.
///
/// Its own vocabulary rather than a `FeedbackKey`: those are gameplay results a
/// player caused, and these are states of the client. Sharing the enum would
/// have meant either inventing a free-form key variant — which nothing could
/// safely branch on — or overloading "blocked" to mean two unrelated things.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MapUnavailable {
    /// Turned off, or not permitted in this area.
    Disabled,
    /// There is no server to ask.
    Offline,
    /// The request or the decode failed. The only one worth retrying.
    Failed,
    /// This map genuinely has no data to show.
    NoData,
}

impl MapUnavailable {
    /// The localisation key for the label a player is shown.
    pub fn name_key(self) -> &'static str {
        match self {
            MapUnavailable::Disabled => "map.unavailable.disabled",
            MapUnavailable::Offline => "map.unavailable.offline",
            MapUnavailable::Failed => "map.unavailable.failed",
            MapUnavailable::NoData => "map.unavailable.no_data",
        }
    }

    /// Whether asking again could succeed.
    pub fn is_retryable(self) -> bool {
        matches!(self, MapUnavailable::Failed)
    }
}

impl MapAvailability {
    /// Whether a view built from this can draw map data at all.
    pub fn is_drawable(&self) -> bool {
        matches!(self, MapAvailability::Ready)
    }

    /// Whether a player is waiting rather than being told no.
    pub fn is_pending(&self) -> bool {
        matches!(self, MapAvailability::Idle | MapAvailability::Loading)
    }
}

/// A marker on a map, in tile coordinates of the map it belongs to.
///
/// Deliberately not a colour or a sprite: presentation chooses those from the
/// kind, so a palette change is one edit in the interface rather than a change
/// to what the adapter reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapMarker {
    pub x: i32,
    pub y: i32,
    pub kind: MarkerKind,
}

/// What a marker represents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkerKind {
    /// The local player.
    Player,
    /// Another member of the party.
    Party,
    /// A hostile the server has disclosed.
    Hostile,
    /// A named point of interest: a city, a dungeon mouth.
    Landmark,
}

/// The minimap: the immediate surroundings, drawn in the rail.
///
/// `radius` is in tiles and is a *presentation* bound, not a knowledge bound.
/// The authoritative limit on what a client may know about other entities is the
/// server's area of interest, and markers here must already have been filtered
/// by it — a wider minimap must never become a spyglass. `layout::AOI_RADIUS_X`
/// and `AOI_RADIUS_Y` are the client-side mirror of that bound.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MinimapState {
    pub availability: MapAvailability,
    /// The map the player is standing in.
    pub map_number: u16,
    /// Where the player is, in that map's tiles.
    pub centre: (i32, i32),
    /// Tiles from the centre this view covers on each axis.
    pub radius: i32,
    /// Everything worth drawing, already inside the server's area of interest.
    pub markers: Vec<MapMarker>,
}

impl MinimapState {
    /// Markers actually inside the view, so presentation cannot draw one that
    /// the radius excludes.
    pub fn visible_markers(&self) -> impl Iterator<Item = &MapMarker> {
        let (cx, cy) = self.centre;
        let radius = self.radius.max(0);
        self.markers
            .iter()
            .filter(move |m| (m.x - cx).abs() <= radius && (m.y - cy).abs() <= radius)
    }

    /// Whether there is anything to draw beyond the backdrop.
    pub fn has_content(&self) -> bool {
        self.availability.is_drawable() && self.visible_markers().next().is_some()
    }
}

/// The whole-world map, opened over the world viewport.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorldMapState {
    pub availability: MapAvailability,
    /// Whether the overlay is open. Separate from availability: a player can
    /// open it while it is still loading, and should see that rather than
    /// nothing.
    pub open: bool,
    /// The map currently highlighted, which is the player's unless they have
    /// panned.
    pub focus_map: u16,
    /// Size of the whole map in tiles, for placing markers proportionally.
    pub size: (i32, i32),
    pub markers: Vec<MapMarker>,
}

impl WorldMapState {
    /// Whether the overlay should be drawn at all this frame.
    pub fn is_presenting(&self) -> bool {
        self.open
    }

    /// Whether it is open but has nothing yet, which needs a labelled state
    /// rather than an empty rectangle.
    pub fn is_waiting(&self) -> bool {
        self.open && self.availability.is_pending()
    }
}

/// Whether the client is talking to a server, and how well.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ConnectionPhase {
    #[default]
    Offline,
    Connecting,
    Authenticating,
    Playing,
    Reconnecting,
    Failed,
}

/// Connection health, for the status bar.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServiceState {
    pub phase: ConnectionPhase,
    /// None until a probe is answered — distinct from a latency of zero.
    pub latency_ms: Option<u32>,
    pub population: Option<u32>,
}

/// Something the server told the player, as a key rather than a sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeedbackKey {
    NotEnoughMana,
    NotEnoughStamina,
    NotEnoughGold,
    InventoryFull,
    TooFarAway,
    TargetInvalid,
    ActionTooSoon,
    Blocked,
    Died,
    LevelUp,
    /// The protocol carried prose we cannot classify. The text is preserved so
    /// the player still sees it, but it is explicitly not a key: nothing may
    /// branch on it.
    Untranslated,
}

/// A typed value inside a feedback message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FeedbackParam {
    Amount(i32),
    Name(String),
}

/// One piece of server feedback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Feedback {
    pub key: FeedbackKey,
    pub params: Vec<FeedbackParam>,
    /// Only populated for [`FeedbackKey::Untranslated`], where the wire carried
    /// prose the protocol could not classify.
    pub literal: Option<String>,
}

impl Feedback {
    pub fn new(key: FeedbackKey) -> Self {
        Self { key, params: Vec::new(), literal: None }
    }

    /// Prose from the wire that could not be classified.
    pub fn untranslated(text: impl Into<String>) -> Self {
        Self { key: FeedbackKey::Untranslated, params: Vec::new(), literal: Some(text.into()) }
    }

    /// Whether this can be localised, as opposed to being shown verbatim.
    pub fn is_localisable(&self) -> bool {
        self.key != FeedbackKey::Untranslated
    }
}

/// Everything the interface may read, in one value.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct UiSnapshot {
    pub progression: ProgressionState,
    pub vitals: PlayerVitals,
    pub inventory: InventoryState,
    pub equipment: EquipmentState,
    pub spellbook: SpellbookState,
    pub hotbar: HotbarState,
    pub target: TargetState,
    pub chat: ChatState,
    pub skills: SkillsState,
    pub safety: SafetyState,
    pub service: ServiceState,
    pub minimap: MinimapState,
    pub world_map: WorldMapState,
    pub feedback: Vec<Feedback>,
    /// True while the snapshot is a placeholder awaiting real data. Distinct
    /// from empty: "no items" and "not loaded yet" look different and mean
    /// different things.
    pub loading: bool,
}

impl UiSnapshot {
    /// Whether the character is a ghost, which restricts most interactions.
    pub fn is_dead(&self) -> bool {
        self.vitals.is_dead()
    }

    /// Whether world commands should be suppressed because something else owns
    /// the keyboard.
    pub fn text_input_has_focus(&self) -> bool {
        self.chat.composing
    }
}

impl UiSnapshot {
    /// Whether two snapshots describe the same state, treating equal NaNs as
    /// equal.
    ///
    /// `PartialEq` cannot do this and should not: NaN really is not equal to
    /// itself. But a *snapshot* carrying one is still the same snapshot, and
    /// change detection written on `PartialEq` would rebuild the entire
    /// interface every frame for as long as a malformed cooldown was on
    /// screen.
    ///
    /// Only the fields that can carry a float need the special case; the rest
    /// compare normally, which keeps this far cheaper than formatting both
    /// values and comparing the strings.
    pub fn same_state_as(&self, other: &Self) -> bool {
        self.progression == other.progression
            && self.vitals == other.vitals
            && self.inventory == other.inventory
            && self.equipment == other.equipment
            && self.spellbook == other.spellbook
            && self.target == other.target
            && self.chat == other.chat
            && self.skills == other.skills
            && self.safety == other.safety
            && self.service == other.service
            && self.minimap == other.minimap
            && self.world_map == other.world_map
            && self.feedback == other.feedback
            && self.loading == other.loading
            && hotbars_match(&self.hotbar, &other.hotbar)
    }
}

/// Compare hotbars, treating two NaN cooldowns as the same.
fn hotbars_match(a: &HotbarState, b: &HotbarState) -> bool {
    a.page == b.page
        && a.page_count == b.page_count
        && a.slots.len() == b.slots.len()
        && a.slots.iter().zip(&b.slots).all(|(x, y)| {
            x.binding == y.binding
                && (x.cooldown == y.cooldown || (x.cooldown.is_nan() && y.cooldown.is_nan()))
        })
}

/// Something the player asked for.
///
/// The interface emits these and nothing else. It cannot send a packet, so it
/// cannot invent a protocol interaction the session layer has not sanctioned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    UseInventorySlot { slot: usize },
    EquipInventorySlot { slot: usize },
    DropInventorySlot { slot: usize, amount: i32 },
    MoveInventorySlot { from: usize, to: usize },
    CastSpell { spell_id: i32 },
    TriggerHotbarSlot { index: usize },
    BindHotbarSlot { index: usize, binding: HotbarBinding },
    ChangeHotbarPage { page: usize },
    SelectTarget { x: u8, y: u8 },
    ClearTarget,
    SendChat { channel: ChatChannel, body: String },
    SetActiveChannel { channel: Option<ChatChannel> },
    SetSafeMode(bool),
    SetPartySafe(bool),
    TrainSkill { skill_id: i32 },
    RequestReconnect,
}

impl Intent {
    /// Whether this intent is meaningful while dead.
    ///
    /// A ghost cannot use, equip, drop, cast or fight. Filtering here rather
    /// than at each button means a new control cannot forget the rule.
    pub fn allowed_while_dead(&self) -> bool {
        matches!(
            self,
            Intent::SendChat { .. }
                | Intent::SetActiveChannel { .. }
                | Intent::ClearTarget
                | Intent::SelectTarget { .. }
                | Intent::RequestReconnect
                | Intent::ChangeHotbarPage { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_gauge_with_no_maximum_reads_as_empty_rather_than_dividing_by_zero() {
        // The server sends this for a stat a character has not unlocked. A
        // naive fraction is a NaN that propagates into a bar width and takes
        // the layout with it.
        assert_eq!(Gauge::new(0, 0).fraction(), 0.0);
        assert_eq!(Gauge::new(5, 0).fraction(), 0.0);
        assert_eq!(Gauge::new(-1, 0).fraction(), 0.0);
    }

    #[test]
    fn a_gauge_above_its_maximum_clamps_instead_of_overflowing_the_track() {
        // Transient mid-buff state. Unclamped, the bar draws past its own
        // border and over whatever is beside it.
        assert_eq!(Gauge::new(150, 100).fraction(), 1.0);
    }

    #[test]
    fn a_negative_gauge_reads_as_empty_and_depleted() {
        let gauge = Gauge::new(-20, 100);
        assert_eq!(gauge.fraction(), 0.0);
        assert!(gauge.is_depleted());
    }

    #[test]
    fn a_negative_quantity_is_never_rendered() {
        // Means the client and server disagree. Worth logging, not worth
        // drawing as "-3 potions".
        let item = ItemView { quantity: -3, ..Default::default() };
        assert_eq!(item.display_quantity(), 0);
        assert!(!item.shows_quantity());
    }

    #[test]
    fn a_single_item_shows_no_count() {
        // No AO client numbers a stack of one; the icon is the information.
        assert!(!ItemView { quantity: 1, ..Default::default() }.shows_quantity());
        assert!(ItemView { quantity: 2, ..Default::default() }.shows_quantity());
    }

    #[test]
    fn a_locked_slot_is_a_state_rather_than_an_absence() {
        // Shown with a padlock, not hidden: a player can see what expanding
        // their pack would buy.
        let locked = SlotState::Locked;
        assert!(locked.item().is_none());
        assert!(!locked.accepts_drop(), "a locked slot must refuse a drop");

        assert!(SlotState::Empty.accepts_drop());
    }

    #[test]
    fn an_out_of_range_slot_index_reads_as_empty_rather_than_panicking() {
        // Indices arrive from the server and from drag gestures. Neither is
        // worth crashing the client over.
        let inventory = InventoryState { slots: vec![SlotState::Empty], columns: 6 };
        assert_eq!(inventory.slot(0), &SlotState::Empty);
        assert_eq!(inventory.slot(999), &SlotState::Empty);
    }

    #[test]
    fn a_grid_with_no_columns_needs_no_rows_rather_than_dividing_by_zero() {
        let inventory = InventoryState { slots: vec![SlotState::Empty; 10], columns: 0 };
        assert_eq!(inventory.rows(), 0);
    }

    #[test]
    fn rows_round_up_so_a_partial_last_row_is_still_drawn() {
        let inventory = InventoryState { slots: vec![SlotState::Empty; 13], columns: 6 };
        assert_eq!(inventory.rows(), 3);
    }

    #[test]
    fn locked_slots_are_counted_separately_from_used_ones() {
        let inventory = InventoryState {
            slots: vec![
                SlotState::Filled(ItemView::default()),
                SlotState::Empty,
                SlotState::Locked,
            ],
            columns: 6,
        };
        assert_eq!(inventory.used_slots(), 1);
        assert_eq!(inventory.unlocked_slots(), 2);
    }

    #[test]
    fn a_blocked_spell_says_why_rather_than_only_being_greyed_out() {
        // "Greyed out" is not feedback: a player needs to know whether to
        // drink a potion or train a skill.
        let spell =
            SpellView { blockers: vec![SpellBlocker::InsufficientMana], ..Default::default() };
        assert!(!spell.is_castable());
        assert!(spell.blockers.contains(&SpellBlocker::InsufficientMana));

        assert!(SpellView::default().is_castable());
    }

    #[test]
    fn a_cooldown_outside_its_range_is_clamped_before_it_is_drawn() {
        // An unclamped sweep renders past the edge of the slot.
        for raw in [-1.0, 1.5, f32::NAN, f32::INFINITY] {
            let slot = HotbarSlotState { cooldown: raw, ..Default::default() };
            let fraction = slot.cooldown_fraction();
            assert!((0.0..=1.0).contains(&fraction), "{raw} produced {fraction}");
        }
    }

    #[test]
    fn an_empty_hotbar_slot_is_never_ready() {
        // Ready means "pressing this does something".
        assert!(!HotbarSlotState::default().is_ready());

        let bound = HotbarSlotState {
            binding: Some(HotbarBinding::Spell { spell_id: 1, icon_grh: 1 }),
            cooldown: 0.0,
        };
        assert!(bound.is_ready());
    }

    #[test]
    fn an_out_of_range_hotbar_slot_reads_as_empty() {
        let hotbar = HotbarState::default();
        assert_eq!(hotbar.slot(99), HotbarSlotState::default());
    }

    #[test]
    fn an_undisclosed_target_health_is_distinct_from_full_health() {
        // The server withholds exact health for other players. Showing a full
        // bar would be a lie the interface invented.
        let target = TargetState::Selected {
            name: "someone".to_string(),
            kind: TargetKind::Player,
            health: None,
        };
        match target {
            TargetState::Selected { health, .. } => assert!(health.is_none()),
            _ => panic!("expected a selection"),
        }
    }

    #[test]
    fn feedback_carries_a_key_so_it_can_be_translated() {
        // A client that renders server prose cannot be localised, and cannot
        // tell "you lack the mana" from "you lack the skill" without matching
        // on text.
        let feedback = Feedback::new(FeedbackKey::NotEnoughMana);
        assert!(feedback.is_localisable());
        assert!(feedback.literal.is_none());
    }

    #[test]
    fn unclassifiable_prose_is_shown_but_marked_as_not_a_key() {
        // The wire still carries inherited Spanish in places. The player must
        // see it, but nothing may branch on it.
        let feedback = Feedback::untranslated("No tienes suficiente energia.");
        assert!(!feedback.is_localisable());
        assert_eq!(feedback.literal.as_deref(), Some("No tienes suficiente energia."));
    }

    #[test]
    fn a_ghost_may_talk_and_look_but_not_act() {
        // Filtered on the intent rather than at each button, so a control
        // added later cannot forget the rule.
        for allowed in [
            Intent::SendChat { channel: ChatChannel::Say, body: "hello".to_string() },
            Intent::ClearTarget,
            Intent::RequestReconnect,
        ] {
            assert!(allowed.allowed_while_dead(), "{allowed:?} should be allowed");
        }

        for denied in [
            Intent::UseInventorySlot { slot: 0 },
            Intent::EquipInventorySlot { slot: 0 },
            Intent::DropInventorySlot { slot: 0, amount: 1 },
            Intent::CastSpell { spell_id: 1 },
            Intent::TriggerHotbarSlot { index: 0 },
            Intent::TrainSkill { skill_id: 1 },
        ] {
            assert!(!denied.allowed_while_dead(), "{denied:?} should be denied");
        }
    }

    #[test]
    fn composing_text_is_visible_to_the_interface_so_it_can_suppress_movement() {
        // Otherwise typing "walk" in chat walks.
        let mut snapshot = UiSnapshot::default();
        assert!(!snapshot.text_input_has_focus());
        snapshot.chat.composing = true;
        assert!(snapshot.text_input_has_focus());
    }

    #[test]
    fn a_map_distinguishes_no_data_from_not_loaded_from_refused() {
        // Three states a player reacts to differently, and only one is worth
        // retrying. Collapsing them into an Option was the mistake this replaces:
        // an unexplained black rectangle is indistinguishable from a rendering
        // fault, and a player has no way to tell which.
        assert!(MapAvailability::Idle.is_pending());
        assert!(MapAvailability::Loading.is_pending());
        assert!(!MapAvailability::Ready.is_pending());
        assert!(MapAvailability::Ready.is_drawable());

        let refused = MapAvailability::Unavailable(MapUnavailable::Disabled);
        assert!(!refused.is_drawable(), "a refused map must not be drawn");
        assert!(!refused.is_pending(), "a refused map is not still coming");
    }

    #[test]
    fn only_a_failure_invites_another_attempt() {
        // Retrying a map that is disabled or genuinely empty is a request that
        // can never succeed, repeated forever.
        assert!(MapUnavailable::Failed.is_retryable());
        for reason in [MapUnavailable::Disabled, MapUnavailable::Offline, MapUnavailable::NoData] {
            assert!(!reason.is_retryable(), "{reason:?} should not be retried");
        }
    }

    #[test]
    fn every_map_reason_carries_its_own_key() {
        // Distinct, because two reasons sharing a key means a player is told the
        // wrong thing about one of them.
        let keys: Vec<&str> = [
            MapUnavailable::Disabled,
            MapUnavailable::Offline,
            MapUnavailable::Failed,
            MapUnavailable::NoData,
        ]
        .into_iter()
        .map(MapUnavailable::name_key)
        .collect();
        let mut unique = keys.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), keys.len(), "two map reasons share a key: {keys:?}");
        assert!(keys.iter().all(|k| k.starts_with("map.unavailable.")));
    }

    #[test]
    fn a_minimap_never_reports_a_marker_outside_its_own_radius() {
        // The malformed fixture carries markers far outside the view and at the
        // extremes of i32. A consumer that trusts the list rather than the bound
        // draws outside its rectangle, and computing where to overflows.
        let snapshot = crate::fixtures::snapshot(crate::fixtures::Scenario::Malformed);
        let radius = snapshot.minimap.radius;
        let (cx, cy) = snapshot.minimap.centre;

        assert!(
            snapshot.minimap.markers.len() > snapshot.minimap.visible_markers().count(),
            "this fixture is supposed to contain out-of-range markers"
        );
        for marker in snapshot.minimap.visible_markers() {
            assert!(
                (marker.x - cx).abs() <= radius && (marker.y - cy).abs() <= radius,
                "{marker:?} is outside a radius of {radius} around {cx},{cy}"
            );
        }
    }

    #[test]
    fn an_empty_minimap_is_ready_rather_than_unloaded() {
        // "Nothing in range" and "no data yet" look the same in a rectangle and
        // mean opposite things about whether to keep waiting.
        let empty = crate::fixtures::snapshot(crate::fixtures::Scenario::Empty);
        assert!(empty.minimap.availability.is_drawable());
        assert!(!empty.minimap.has_content(), "the empty fixture has markers");

        let loading = crate::fixtures::snapshot(crate::fixtures::Scenario::Loading);
        assert!(loading.minimap.availability.is_pending());
        assert!(!loading.minimap.availability.is_drawable());
    }

    #[test]
    fn a_world_map_open_while_loading_is_a_state_a_player_can_reach() {
        // Opening the overlay before its data arrives is ordinary, and needs a
        // label rather than an empty overlay.
        let loading = crate::fixtures::snapshot(crate::fixtures::Scenario::Loading);
        assert!(loading.world_map.is_presenting(), "the overlay is not open");
        assert!(loading.world_map.is_waiting(), "an open, loading overlay is not reported waiting");

        let ready = crate::fixtures::snapshot(crate::fixtures::Scenario::Populated);
        assert!(!ready.world_map.is_waiting());
    }

    #[test]
    fn a_ghost_can_still_read_the_map() {
        // Death restricts acting, not looking — the same rule the intent filter
        // applies to chat.
        let ghost = crate::fixtures::snapshot(crate::fixtures::Scenario::DeadGhost);
        assert!(ghost.is_dead());
        assert!(ghost.minimap.availability.is_drawable(), "a ghost lost the minimap");
    }

    #[test]
    fn a_disconnected_client_says_why_the_map_is_gone() {
        for (scenario, expected) in [
            (crate::fixtures::Scenario::Disconnected, MapUnavailable::Offline),
            (crate::fixtures::Scenario::Disabled, MapUnavailable::Disabled),
        ] {
            let snapshot = crate::fixtures::snapshot(scenario);
            assert_eq!(
                snapshot.minimap.availability,
                MapAvailability::Unavailable(expected),
                "{scenario:?} does not explain its missing minimap"
            );
        }
    }

    #[test]
    fn the_map_states_take_part_in_snapshot_equality() {
        // Added to the snapshot without being added to `same_state_as`, a map
        // change would never rebuild the interface — the map would freeze and
        // nothing else would look wrong.
        let a = crate::fixtures::snapshot(crate::fixtures::Scenario::Populated);
        let mut b = a.clone();
        assert!(a.same_state_as(&b));

        b.minimap.centre = (51, 50);
        assert!(!a.same_state_as(&b), "moving the minimap centre is not a change");

        let mut c = a.clone();
        c.world_map.open = !c.world_map.open;
        assert!(!a.same_state_as(&c), "opening the world map is not a change");
    }

    #[test]
    fn a_snapshot_carrying_nan_still_recognises_itself() {
        // Change detection written on PartialEq would rebuild the whole
        // interface every frame for as long as a malformed cooldown was on
        // screen, because NaN is not equal to itself.
        let mut snapshot = UiSnapshot::default();
        snapshot.hotbar.slots = vec![HotbarSlotState { binding: None, cooldown: f32::NAN }];

        assert_ne!(snapshot, snapshot.clone(), "PartialEq still behaves correctly");
        assert!(snapshot.same_state_as(&snapshot.clone()), "but the state is unchanged");
    }

    #[test]
    fn a_real_change_is_still_detected_alongside_a_nan() {
        // The comparison must not be so forgiving that it misses an update.
        let mut a = UiSnapshot::default();
        a.hotbar.slots = vec![HotbarSlotState { binding: None, cooldown: f32::NAN }];
        let mut b = a.clone();
        b.vitals.health = Gauge::new(1, 10);

        assert!(!a.same_state_as(&b));
    }

    #[test]
    fn a_changed_cooldown_is_detected() {
        let mut a = UiSnapshot::default();
        a.hotbar.slots = vec![HotbarSlotState { binding: None, cooldown: 0.5 }];
        let mut b = a.clone();
        b.hotbar.slots[0].cooldown = 0.4;

        assert!(!a.same_state_as(&b));
        assert!(a.same_state_as(&a.clone()));
    }

    #[test]
    fn a_hotbar_that_gained_a_slot_is_a_change() {
        let a = UiSnapshot::default();
        let mut b = a.clone();
        b.hotbar.slots.push(HotbarSlotState::default());

        assert!(!a.same_state_as(&b));
    }

    #[test]
    fn loading_is_distinct_from_empty() {
        // "No items" and "not loaded yet" look different and mean different
        // things; one snapshot type has to be able to say which.
        let empty = UiSnapshot::default();
        let loading = UiSnapshot { loading: true, ..Default::default() };
        assert_ne!(empty, loading);
        assert!(!empty.loading);
    }

    #[test]
    fn death_is_derived_from_health_rather_than_tracked_separately() {
        // Two sources of truth for "am I dead" is how a ghost ends up able to
        // swing a sword.
        let mut snapshot = UiSnapshot::default();
        snapshot.vitals.health = Gauge::new(10, 100);
        assert!(!snapshot.is_dead());
        snapshot.vitals.health = Gauge::new(0, 100);
        assert!(snapshot.is_dead());
    }
}
