import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **A glance**: a small, read-only summary of another page, shown on the
/// Agent dashboard, that opens the full page when clicked.
///
/// The dashboard draws the tile around it — the icon, the title, the open
/// affordance, collapsing and hiding — and [build] draws only the body. The
/// body watches its own feature's providers, so the dashboard imports the
/// glance and nothing else of the feature. It lives here, outside any
/// feature, so a feature providing a glance need not import the dashboard.
@immutable
class DashboardGlance {
  const DashboardGlance({
    required this.id,
    required this.title,
    required this.icon,
    required this.build,
    required this.onOpen,
  });

  /// Stable and remembered per device with the order, hidden and collapsed
  /// choices: never rename one.
  final String id;

  final String title;
  final IconData icon;

  /// The tile's body: at most a few short lines, laid out for any width from
  /// about 240 px, at text scale 1.6, with its own empty and loading states.
  /// On a phone's strip, where [GlanceScope.compactOf] is true, one line.
  final WidgetBuilder build;

  /// Opens the full page: the workbench tab on a desktop, More's page on a
  /// phone (the page's own `open…Tab(ref)` does both).
  final void Function(BuildContext context, WidgetRef ref) onOpen;
}

/// Tells a glance's body where it is drawn: [compact] on a phone's strip,
/// where the board's own cards must stay in view, so the body keeps to one
/// line.
class GlanceScope extends InheritedWidget {
  const GlanceScope({required this.compact, required super.child, super.key});

  final bool compact;

  /// Whether the glance at [context] is on a phone's strip; false outside a
  /// scope.
  static bool compactOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlanceScope>()?.compact ??
      false;

  @override
  bool updateShouldNotify(GlanceScope oldWidget) =>
      oldWidget.compact != compact;
}
