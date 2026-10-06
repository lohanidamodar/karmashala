import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/presentation/environment_rows.dart';
import '../application/environment_location.dart';

/// The most a status bar's environment name may take before it ends.
const double _environmentLabelWidth = 120;

/// What hovering a machine's mark says: its full name, and the folder there.
String environmentMarkTooltip(EnvironmentLocation location) =>
    location.folder == null
    ? location.name
    : '${location.name}\n${location.folder}';

/// A machine on a status bar: its glyph, its label where [labelled], and its
/// full name and folder on hover. The glyph alone still says which kind it is.
class EnvironmentMark extends StatelessWidget {
  const EnvironmentMark({
    required this.location,
    this.labelled = true,
    super.key,
  });

  /// The key a status bar's mark carries, for whoever looks for it.
  static const barKey = ValueKey('session-bar-environment');

  final EnvironmentLocation location;
  final bool labelled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: Insets.sm),
    child: Tooltip(
      message: environmentMarkTooltip(location),
      child: Semantics(
        label: location.spokenName,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              environmentGlyph(location.kind),
              size: UiDensity.of(context).icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            if (labelled) ...[
              const SizedBox(width: Insets.xs),
              EnvironmentMarkLabel(label: location.label),
            ],
          ],
        ),
      ),
    ),
  );
}

/// [EnvironmentMark]'s name on its own, for a bar that lets it go before the
/// facts beside it while the glyph stays.
class EnvironmentMarkLabel extends StatelessWidget {
  const EnvironmentMarkLabel({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _environmentLabelWidth),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
