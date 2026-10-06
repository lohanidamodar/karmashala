import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/presentation/environment_rows.dart';

/// The most a status bar's environment name may take before it ends.
const double _environmentLabelWidth = 120;

/// What hovering a machine's mark says: its full name, and the folder there.
String environmentMarkTooltip(String name, String? folder) =>
    folder == null ? name : '$name\n$folder';

/// A machine on a status bar: its glyph, its [label] where [labelled], and the
/// [name] and [folder] on hover. The glyph alone still says which kind it is.
class EnvironmentMark extends StatelessWidget {
  const EnvironmentMark({
    required this.kind,
    required this.label,
    required this.name,
    this.folder,
    this.labelled = true,
    super.key,
  });

  /// The key a status bar's mark carries, for whoever looks for it.
  static const barKey = ValueKey('session-bar-environment');

  final EnvironmentKind kind;
  final String label;
  final String name;
  final String? folder;
  final bool labelled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: Insets.sm),
    child: Tooltip(
      message: environmentMarkTooltip(name, folder),
      child: Semantics(
        label: spokenEnvironmentLabel(name),
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              environmentGlyph(kind),
              size: UiDensity.of(context).icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            if (labelled) ...[
              const SizedBox(width: Insets.xs),
              EnvironmentMarkLabel(label: label),
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
