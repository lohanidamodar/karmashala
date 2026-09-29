import 'package:riverpod/riverpod.dart';

import '../../features/settings/application/settings_controller.dart';

/// **The context panel's tabs** (UI overhaul spec §6), in the order they are
/// drawn. Every menu that lists the panel follows this order.
enum ContextTab {
  changes('Changes'),
  repo('Repo'),
  history('History'),
  files('Files'),
  more('More');

  const ContextTab(this.label);

  final String label;

  /// The surfaces under this tab, the one it opens first leading. Empty for
  /// More, which holds every surface no other tab does.
  List<SidePanelSurface> get surfaces => switch (this) {
    ContextTab.changes => const [SidePanelSurface.changes],
    ContextTab.repo => const [SidePanelSurface.repository],
    ContextTab.history => const [
      SidePanelSurface.checkpoints,
      SidePanelSurface.decisions,
      SidePanelSurface.plan,
    ],
    ContextTab.files => const [SidePanelSurface.files],
    ContextTab.more => const [],
  };

  /// The tab [surface] sits under.
  static ContextTab of(SidePanelSurface surface) => values.firstWhere(
    (tab) => tab.surfaces.contains(surface),
    orElse: () => ContextTab.more,
  );
}

/// The surfaces the context panel can show (spec §4). Named `SidePanel` for the
/// right-hand side panel and its rail, which the context panel replaced.
/// Declared in the order every list of them follows: the tabs' surfaces, then
/// More's. Stored by name, so reordering is safe.
enum SidePanelSurface {
  changes('Changes', drawsOwnHeader: true, scopedToRepository: true),

  /// Named for what it holds. "Info" said nothing, so nobody opened it — and
  /// the branch and worktree list nobody could find lives in here. GitHub's
  /// pull requests and issues too, since 2026-09-28: they describe the same
  /// checkout, and a pane of their own was blank without a GitHub remote.
  repository('Repository', scopedToRepository: true),

  /// **The way back from a turn.** One entry per turn an agent finished, plus
  /// the safety captures taken before a restore — the only undo for its edits.
  checkpoints('Checkpoints', drawsOwnHeader: true),

  /// **What the session has settled**, in the words it was settled in — the one
  /// of the trio a handoff carries *ahead* of the transcript.
  decisions('Decisions', drawsOwnHeader: true),

  /// **The agent's own plan**, read out of the record it writes for itself, and
  /// read-only. Two agents of the three publish one; the third says so.
  plan('Plan'),
  files('Files', drawsOwnHeader: true, scopedToRepository: true),

  /// The user's own list: a line of text, done or not, filed under a project or
  /// under nothing. **Not gated** on Notes — that switch is about capture.
  todos('Todos', drawsOwnHeader: true),

  /// Ideas kept out of a conversation instead of acted on, and sent back to an
  /// agent when the user is ready for them. Hidden when Notes is switched off.
  notes('Notes', drawsOwnHeader: true, requiresNotes: true),
  verification('Verification'),

  /// Every picture the session on screen has produced or been shown, newest
  /// first — a picture pasted into a terminal is recorded as bytes with no path.
  media('Media'),
  browser('Browser'),

  /// The Flutter app the developer is running: its debug console, hot reload
  /// and a widget picker.
  flutterApp('Flutter app'),
  device('Device'),

  /// **What a session started here would be given** — the MCP servers and
  /// skills the agent's own configuration names, read off files with their
  /// age. Never what a running session bound; the CLI owns that (§19).
  agentContext('Agent context'),

  /// The app's own log tail. Hidden unless debug mode is on: a diagnostic, not
  /// a tool, and an entry nobody needs is in the way of the daily ones.
  logs('Logs', requiresDebugMode: true),

  /// Never offered: an area of the activity strip, kept for its stored id.
  inbox('Inbox', drawsOwnHeader: true);

  const SidePanelSurface(
    this.label, {
    this.drawsOwnHeader = false,
    this.scopedToRepository = false,
    this.requiresDebugMode = false,
    this.requiresNotes = false,
  });

  final String label;

  /// Whether the surface already titles itself. Stacking the panel's header on
  /// one that does is two rows of chrome saying one word.
  final bool drawsOwnHeader;

  /// Whether the surface describes **one checkout**. That selection moves on
  /// its own when the active terminal tab changes, so these have to say which.
  final bool scopedToRepository;

  /// Whether the surface only exists while debug mode is on.
  final bool requiresDebugMode;

  /// Whether the surface only exists while the Notes feature is on.
  final bool requiresNotes;

  /// Whether this surface exists for the settings given. The one answer, so the
  /// panel, the menus and [SidePanel]'s own check cannot disagree. The Inbox
  /// is never offered here: it is an area of the activity strip now.
  bool isOffered({required bool debugMode, bool notesEnabled = true}) =>
      this != SidePanelSurface.inbox &&
      (debugMode || !requiresDebugMode) &&
      (notesEnabled || !requiresNotes);

  /// The surface stored under [id], or null for one this build does not have.
  static SidePanelSurface? fromId(String id) {
    for (final surface in values) {
      if (surface.name == id) return surface;
    }
    return null;
  }

  /// The surfaces to offer — in the context panel, the View menu and quick
  /// open. One list, so a surface switched off cannot still be reachable from
  /// a menu. Taking one out of More is not switching it off: see
  /// [hiddenSidePanelSurfacesProvider].
  static List<SidePanelSurface> offered({
    required bool debugMode,
    bool notesEnabled = true,
  }) => [
    for (final surface in values)
      if (surface.isOffered(debugMode: debugMode, notesEnabled: notesEnabled))
        surface,
  ];
}

/// The surfaces the user took out of the More menu. Only More and the Settings
/// list that toggles it read this; the View menu, quick open and every chord
/// still open a hidden surface.
final hiddenSidePanelSurfacesProvider = Provider<Set<SidePanelSurface>>(
  (ref) => {
    for (final id in ref.watch(
      settingsControllerProvider.select((s) => s.hiddenSidePanelSurfaces),
    ))
      ?SidePanelSurface.fromId(id),
  },
);

/// Which side-panel surface is open, or `null` when collapsed — and collapsed
/// means collapsed: the panel takes no width at all. **Closed by default**
/// (spec §6): the workbench gets the window until the user asks for context.
class SidePanelController extends Notifier<SidePanelSurface?> {
  /// What re-opening the panel should show. Never null, so the panel always has
  /// somewhere to go back to.
  SidePanelSurface _last = SidePanelSurface.changes;

  /// What each tab shows when it is picked: the last surface open under it.
  final _lastIn = <ContextTab, SidePanelSurface>{};

  /// The surface [tab] would open.
  SidePanelSurface lastIn(ContextTab tab) =>
      _lastIn[tab] ?? tab.surfaces.firstOrNull ?? SidePanelSurface.todos;

  @override
  SidePanelSurface? build() => null;

  /// Opening needs room: a panel the window cannot draw must not be recorded as
  /// open, or every control would claim a body nobody can see.
  bool get _hasRoom => ref.read(sidePanelRoomProvider);

  /// Choosing the open surface again closes the panel; choosing another
  /// switches to it. The same gesture does both jobs, as in every editor.
  void select(SidePanelSurface surface) {
    if (!_hasRoom) return;
    if (state == surface) {
      collapse();
      return;
    }
    show(surface);
  }

  /// Opens [surface], or leaves it open — never closes, as a tab never does.
  void show(SidePanelSurface surface) {
    if (!_hasRoom) return;
    _last = surface;
    _lastIn[ContextTab.of(surface)] = surface;
    state = surface;
  }

  /// Opens [tab] on the surface last shown under it.
  void showTab(ContextTab tab) => show(lastIn(tab));

  void collapse() => state = null;

  void expand() {
    if (_hasRoom) state = _last;
  }

  /// With no room this does nothing, so a selection hidden by the window's
  /// width is kept for when it widens rather than closed unseen.
  void toggle() {
    if (!_hasRoom) return;
    if (state == null) {
      expand();
    } else {
      collapse();
    }
  }
}

final sidePanelProvider =
    NotifierProvider<SidePanelController, SidePanelSurface?>(
      SidePanelController.new,
    );

/// Why the context panel cannot open right now, worded for a tooltip or a
/// menu. Its words still say "side panel": tests quote them (see the UI
/// overhaul plan, stage 12).
const kSidePanelNoRoom = 'Widen the window to open the side panel';

/// Whether the window has room for the context panel's body. The shell writes
/// it from its layout; true until the shell has measured.
class SidePanelRoomController extends Notifier<bool> {
  @override
  bool build() => true;

  void report(bool hasRoom) {
    if (state != hasRoom) state = hasRoom;
  }
}

final sidePanelRoomProvider = NotifierProvider<SidePanelRoomController, bool>(
  SidePanelRoomController.new,
);

/// The surface the context panel is actually showing: null when collapsed, and
/// null when a selection is kept but the window is too narrow to draw it.
final visibleSidePanelProvider = Provider<SidePanelSurface?>(
  (ref) =>
      ref.watch(sidePanelRoomProvider) ? ref.watch(sidePanelProvider) : null,
);
