import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/presentation/environment_mark.dart';
import '../application/session_location_providers.dart';

/// Where [sessionId] runs, beside its agent's mark on the session bar.
/// Nothing, and no width, until that is known.
class SessionEnvironmentMark extends ConsumerWidget {
  const SessionEnvironmentMark({
    required this.sessionId,
    this.labelled = true,
    super.key,
  });

  /// The key the bar's mark carries, for whoever looks for it.
  static const barKey = EnvironmentMark.barKey;

  final String sessionId;

  /// Whether the bar has room for the name; the glyph stays either way.
  final bool labelled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(sessionLocationProvider(sessionId));
    if (location == null) return const SizedBox.shrink();
    return EnvironmentMark(location: location, labelled: labelled);
  }
}

/// [SessionEnvironmentMark]'s name, apart from its glyph: on the one status
/// line it is the first thing to go when the facts need the width.
class SessionEnvironmentLabel extends ConsumerWidget {
  const SessionEnvironmentLabel({required this.sessionId, super.key});

  static const barKey = ValueKey('session-bar-environment-label');

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(sessionLocationProvider(sessionId));
    if (location == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: Tooltip(
        message: environmentMarkTooltip(location),
        // The glyph beside it already names the machine to a screen reader.
        child: ExcludeSemantics(
          child: EnvironmentMarkLabel(label: location.label),
        ),
      ),
    );
  }
}
