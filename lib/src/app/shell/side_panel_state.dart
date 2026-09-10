import 'package:riverpod/riverpod.dart';

/// The surfaces the right-hand side panel can show.
enum SidePanelSurface {
  /// First on the rail because it is the thing you check first: everything
  /// pending, in one list, whichever pane owns the thing that is waiting.
  inbox('Inbox', drawsOwnHeader: true),
  changes('Changes', drawsOwnHeader: true, scopedToRepository: true),
  github('GitHub', drawsOwnHeader: true, scopedToRepository: true),
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
  /// the branch and worktree list nobody could find lives in here.
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
  /// rail, the menus and [SidePanel]'s own check cannot disagree.
  bool isOffered({required bool debugMode, bool notesEnabled = true}) =>
      (debugMode || !requiresDebugMode) && (notesEnabled || !requiresNotes);

  /// The surfaces to offer — on the rail, in the View menu and in quick open.
  /// One list, so a surface cannot be hidden and still reachable from a menu.
  static List<SidePanelSurface> offered({
    required bool debugMode,
    bool notesEnabled = true,
  }) => [
    for (final surface in values)
      if (surface.isOffered(debugMode: debugMode, notesEnabled: notesEnabled))
        surface,
  ];
}

/// Which side-panel surface is open, or `null` when the panel is collapsed.
///
/// The panel remembers the surface it was last showing. Collapsed means
/// collapsed: the shell gives the body no width at all, only the rail stays.
class SidePanelController extends Notifier<SidePanelSurface?> {
  /// What re-opening the panel should show. Never null, so the panel always has
  /// somewhere to go back to.
  SidePanelSurface _last = SidePanelSurface.changes;

  @override
  SidePanelSurface? build() => SidePanelSurface.changes;

  /// Clicking the open surface's icon closes the panel; clicking another
  /// switches to it. The same gesture does both jobs, as in every editor rail.
  void select(SidePanelSurface surface) {
    if (state == surface) {
      collapse();
      return;
    }
    _last = surface;
    state = surface;
  }

  void collapse() => state = null;

  void expand() => state = _last;

  void toggle() {
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
