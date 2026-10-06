import 'package:flutter/material.dart';
import 'package:karmashala_ui/panes.dart';

/// **Placeholder** for the Overview's Timeline, which round 28 builds. The
/// tab constructs it as `const OverviewTimelineView()` and nothing else, so
/// that round's class replaces this one at merge without touching the tab.
class OverviewTimelineView extends StatelessWidget {
  const OverviewTimelineView({super.key});

  @override
  Widget build(BuildContext context) =>
      const PanePlaceholder(message: 'The Timeline is not built yet.');
}
