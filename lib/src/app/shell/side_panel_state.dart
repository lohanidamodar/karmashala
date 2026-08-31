import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The surfaces the right-hand side panel can show.
///
/// These used to switch through a bare `int` on a shared provider, which is how
/// four unrelated tools (git changes, GitHub, a device mirror and a browser)
/// ended up behind one index. Naming them makes it obvious when something new is
/// being added to a grab-bag instead of given its own home.
enum SidePanelSurface {
  /// First on the rail because it is the thing you check first: everything
  /// pending, in one list, whichever pane owns the thing that is waiting.
  inbox('Inbox', drawsOwnHeader: true),
  changes('Changes', drawsOwnHeader: true, scopedToRepository: true),
  github('GitHub', drawsOwnHeader: true, scopedToRepository: true),
  files('Files', drawsOwnHeader: true, scopedToRepository: true),
  device('Device'),
  browser('Browser'),
  verification('Verification'),

  /// Named for what it holds. "Info" said nothing, so nobody opened it — and
  /// the branch and worktree list nobody could find lives in here.
  repository('Repository', scopedToRepository: true),

  /// The app's own log tail. Hidden unless debug mode is on: it is a
  /// diagnostic, not a tool, and a rail glyph nobody needs is a rail glyph in
  /// the way of the seven that are used every day.
  logs('Logs', requiresDebugMode: true);

  const SidePanelSurface(
    this.label, {
    this.drawsOwnHeader = false,
    this.scopedToRepository = false,
    this.requiresDebugMode = false,
  });

  final String label;

  /// Whether the surface already titles itself. Three of them do, with their
  /// own actions in the same row, and stacking the panel's header on top of
  /// that was two rows of chrome saying one word.
  final bool drawsOwnHeader;

  /// Whether the surface describes **one checkout** — the diff, the branch and
  /// worktree list, the forge links, the file tree. All four read the same
  /// selection, and since Loop 85 that selection moves on its own when the
  /// active terminal tab changes, so these are the surfaces that have to say
  /// which checkout they are describing.
  final bool scopedToRepository;

  /// Whether the surface only exists while debug mode is on.
  final bool requiresDebugMode;

  /// The surfaces to offer — on the rail, in the View menu and in quick open —
  /// for the current debug-mode setting. One list, so a surface cannot be
  /// hidden from the rail and still reachable from a menu.
  static List<SidePanelSurface> offered({required bool debugMode}) => [
    for (final surface in values)
      if (debugMode || !surface.requiresDebugMode) surface,
  ];
}

/// Which side-panel surface is open, or `null` when the panel is collapsed.
///
/// The panel *remembers* the surface it was last showing, so collapsing and
/// re-opening returns to what the user was doing rather than resetting to the
/// first tab. Collapsed means collapsed: the shell gives the panel body no
/// width at all, only the icon rail stays.
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
