import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../settings/presentation/settings_section.dart';
import '../domain/built_in_projects.dart';
import '../domain/established.dart';
import '../domain/project_descriptor.dart';
import '../domain/project_kind.dart';

/// Settings → Environments: **what Karmashala can do with each kind of app
/// project**, and what it refuses to claim.
///
/// The whole section is data off `builtInProjectDescriptors`, so it cannot
/// drift from what the tool does — a row here is the same `Established` field
/// the build reads, rendered. Nothing is measured by opening this page: no
/// process is spawned, no directory is walked, and there is nothing here that
/// could be stale, because a descriptor is a claim about a toolchain rather
/// than a reading of this machine.
///
/// **A target nobody ran shows its reason where the command would be.** That
/// is the point of the page: iOS is written out in full — the command, the
/// artifact, the id — and every line of it says unchecked. No button.
class ProjectKindsSection extends StatelessWidget {
  const ProjectKindsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'APP PROJECTS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'What a checkout is detected as, and what can be built from it. '
            'Building produces an artifact and an application id; installing '
            'and launching it is the device tools, which work the same for '
            'every kind.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.sm),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(kind.label, style: theme.textTheme.titleSmall),
              const SizedBox(width: Insets.sm),
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

  /// What to show when the field is measured.
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
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text.rich(
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
          ),
        ],
      ),
    );
  }
}
