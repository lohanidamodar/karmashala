import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import 'package:karmashala_flutter_apps/projects.dart';

/// Settings → Projects and files: what Karmashala can do with each kind of
/// project.
/// All data off `builtInProjectDescriptors`, and nothing is measured to show it.
class ProjectKindsSection extends StatelessWidget {
  const ProjectKindsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: 'APP PROJECTS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'What each checkout is detected as, and what it builds.',
          ),
          for (final kind in ProjectKind.values)
            _KindRow(kind: kind, descriptor: descriptorFor(kind)),
        ],
      ),
    );
  }
}

class _KindRow extends StatelessWidget {
  const _KindRow({required this.kind, required this.descriptor});

  final ProjectKind kind;
  final ProjectDescriptor? descriptor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // One ruled entry per kind, like every list on a settings page.
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A Wrap: at phone width and 1.3x text the tag drops under the name
          // instead of pushing past the edge.
          Wrap(
            spacing: Insets.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(kind.label, style: SettingsStyles.rowLabel(context)),
              if (descriptor == null || !descriptor!.canBuild)
                Semantics(
                  label: '${kind.label}: detection only',
                  child: Text(
                    'detection only',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          Text(
            descriptor?.summary ??
                'Karmashala can spot one and nothing more: there is no build '
                    'command for this kind here, because nobody has run its '
                    'toolchain from this app.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (descriptor != null) ...[
            const SizedBox(height: Insets.xs),
            for (final spec in descriptor!.builds)
              _TargetLine(kind: kind, spec: spec),
            _FieldLine(
              label: 'Live channel',
              value: descriptor!.liveChannel,
              measured: descriptor!.liveChannel.value ?? '',
            ),
          ],
        ],
      ),
    );
  }
}

class _TargetLine extends StatelessWidget {
  const _TargetLine({required this.kind, required this.spec});

  final ProjectKind kind;
  final ProjectBuildSpec spec;

  @override
  Widget build(BuildContext context) {
    final command = spec.commandFor();
    return _FieldLine(
      label: '${spec.target.label} build',
      value: spec.command,
      measured: command == null
          ? ''
          : '${spec.tool.label} ${command.join(' ')} '
                '→ ${spec.artifactFor()?.path ?? ''}',
    );
  }
}

/// One field, rendered as what it is: a reading, a known absence, or an
/// admission that nobody ran it.
class _FieldLine extends StatelessWidget {
  const _FieldLine({
    required this.label,
    required this.value,
    required this.measured,
  });

  final String label;
  final Established<Object> value;

  final String measured;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color colour, String text) = switch (value.state) {
      EstablishedState.measured => (
        AppIcons.checkCircle,
        theme.colorScheme.primary,
        measured,
      ),
      EstablishedState.absent => (
        AppIcons.minusCircle,
        theme.colorScheme.onSurfaceVariant,
        value.reason,
      ),
      EstablishedState.unchecked => (
        AppIcons.question,
        theme.colorScheme.onSurfaceVariant,
        value.reason,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: Chrome.iconAction, color: colour),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$label: ',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: text),
                    ],
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // What it *would* be, kept visibly apart from what anything
                // ran — here so the spec can be reviewed, never as an offer.
                if (value.sketch.isNotEmpty)
                  Text(
                    'Would be: ${value.sketch}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
