import 'pane_facts.dart';

/// The terminal panes the server runs, as facts — what adoption, directory
/// attribution and worktree cleanup read of a pane (slice 5c: the server's
/// own terminals since 5a, read off its own screens; no client reports them).
abstract interface class PaneSource {
  /// Every pane now.
  List<PaneFacts> get all;

  /// The bottom [lines] rows of pane [paneId]'s screen, or null for a pane
  /// that is not there.
  List<String>? tailOf(String paneId, int lines);
}

/// No panes: a server that runs no terminals, and a test that needs none.
class NoPanes implements PaneSource {
  const NoPanes();

  @override
  List<PaneFacts> get all => const [];

  @override
  List<String>? tailOf(String paneId, int lines) => null;
}
