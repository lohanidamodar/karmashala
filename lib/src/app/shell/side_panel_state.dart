import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The surfaces the right-hand side panel can show.
///
/// These used to switch through a bare `int` on a shared provider, which is how
/// four unrelated tools (git changes, GitHub, a device mirror and a browser)
/// ended up behind one index. Naming them makes it obvious when something new is
/// being added to a grab-bag instead of given its own home.
enum SidePanelSurface {
  changes('Changes', drawsOwnHeader: true),
  github('GitHub', drawsOwnHeader: true),
  files('Files', drawsOwnHeader: true),
  device('Device'),
  browser('Browser'),
  info('Info');

  const SidePanelSurface(this.label, {this.drawsOwnHeader = false});

  final String label;

  /// Whether the surface already titles itself. Three of them do, with their
  /// own actions in the same row, and stacking the panel's header on top of
  /// that was two rows of chrome saying one word.
  final bool drawsOwnHeader;
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
