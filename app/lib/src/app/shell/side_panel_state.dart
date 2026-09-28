import 'package:riverpod/riverpod.dart';

import '../../features/settings/application/settings_controller.dart';

/// **The context panel's tabs** (UI overhaul spec §6): three surfaces a
/// session is steered by, and **More** for everything else — which takes the
/// name of the surface it is showing.
enum ContextTab {
  changes('Changes'),
  repo('Repo'),
  history('History'),
  more('More');

  const ContextTab(this.label);

  final String label;

  /// The surface this tab stands for; null for More, which shows whichever of
  /// the rest was open last.
  SidePanelSurface? get surface => switch (this) {
    ContextTab.changes => SidePanelSurface.changes,
    ContextTab.repo => SidePanelSurface.repository,
    ContextTab.history => SidePanelSurface.checkpoints,
    ContextTab.more => null,
  };

  /// The tab [surface] sits under.
  static ContextTab of(SidePanelSurface surface) => switch (surface) {
    SidePanelSurface.changes => ContextTab.changes,
    SidePanelSurface.repository => ContextTab.repo,
    SidePanelSurface.checkpoints => ContextTab.history,
    _ => ContextTab.more,
  };
}

/// The surfaces the right-hand side panel can show.
enum SidePanelSurface {
  /// First on the rail because it is the thing you check first: everything
  /// pending, in one list, whichever pane owns the thing that is waiting.
  inbox('Inbox', drawsOwnHeader: true),
  changes('Changes', drawsOwnHeader: true, scopedToRepository: true),
  files('Files', drawsOwnHeader: true, scopedToRepository: true),
  device('Device'),
  browser('Browser'),

  /// The Flutter app the developer is running: its debug console, hot reload
  /// and a widget picker.
  flutterApp('Flutter app'),
  verification('Verification'),

  /// Every picture the session on screen has produced or been shown, newest
  /// first — a picture pasted into a terminal is recorded as bytes with no path.
  media('Media'),

  /// Named for what it holds. "Info" said nothing, so nobody opened it — and
  /// the branch and worktree list nobody could find lives in here. GitHub's
  /// pull requests and issues too, since 2026-09-28: they describe the same
  /// checkout, and a pane of their own was blank without a GitHub remote.
  repository('Repository', scopedToRepository: true),

  /// **The agent's own plan**, read out of the record it writes for itself, and
  /// read-only. Two agents of the three publish one; the third says so.
  plan('Plan'),

  /// **The way back from a turn.** One entry per turn an agent finished, plus
  /// the safety captures taken before a restore — the only undo for its edits.
  checkpoints('Checkpoints', drawsOwnHeader: true),

  /// **What the session has settled**, in the words it was settled in — the one
  /// of the trio a handoff carries *ahead* of the transcript.
  decisions('Decisions', drawsOwnHeader: true),

  /// The user's own list: a line of text, done or not, filed under a project or
  /// under nothing. **Not gated** on Notes — that switch is about capture.
  todos('Todos', drawsOwnHeader: true),

  /// Ideas kept out of a conversation instead of acted on, and sent back to an
  /// agent when the user is ready for them. Hidden when Notes is switched off.
  notes('Notes', drawsOwnHeader: true, requiresNotes: true),

  /// **What a session started here would be given** — the MCP servers and
  /// skills the agent's own configuration names, read off files with their
  /// age. Never what a running session bound; the CLI owns that (§19).
  agentContext('Context'),

  /// The app's own log tail. Hidden unless debug mode is on: a diagnostic, not
  /// a tool, and a rail glyph nobody needs is in the way of the daily ones.
  logs('Logs', requiresDebugMode: true);

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

/// The surfaces the user took out of the More menu. Only More and the lists
/// that toggle it read this; the View menu, quick open and every chord still
/// open a hidden surface.
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

  /// What the **More** tab shows when it is picked: the last surface under it.
  SidePanelSurface _lastMore = SidePanelSurface.todos;

  /// The surface the More tab would open.
  SidePanelSurface get lastMore => _lastMore;

  @override
  SidePanelSurface? build() => null;

  /// Opening needs room: a panel the window cannot draw must not be recorded as
  /// open, or every control would claim a body nobody can see.
  bool get _hasRoom => ref.read(sidePanelRoomProvider);

  /// Clicking the open surface's icon closes the panel; clicking another
  /// switches to it. The same gesture does both jobs, as in every editor rail.
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
    if (ContextTab.of(surface) == ContextTab.more) _lastMore = surface;
    state = surface;
  }

  /// Opens [tab]: its own surface, or for More the one shown there last.
  void showTab(ContextTab tab) => show(tab.surface ?? _lastMore);

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

/// Why the side panel cannot open right now, worded for a tooltip or a menu.
const kSidePanelNoRoom = 'Widen the window to open the side panel';

/// Whether the window has room for the side panel's body. The shell writes it
/// from its layout; true until the shell has measured.
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

/// The surface the side panel is actually showing: null when collapsed, and
/// null when a selection is kept but the window is too narrow to draw it.
final visibleSidePanelProvider = Provider<SidePanelSurface?>(
  (ref) =>
      ref.watch(sidePanelRoomProvider) ? ref.watch(sidePanelProvider) : null,
);
