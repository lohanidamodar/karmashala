import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → About: the About dialog's facts (`KarmashalaAboutDialog`), where
/// someone filing a bug looks in Settings. Read-only: [buildIdentity], the same
/// line every log starts with, so a pasted log cannot disagree with it.
///
/// Drawn by the settings screen for its page rather than through an anchor:
/// the anchor table lives in `settings_page_body.dart`, which the responsive
/// work owns. Move it there as `SettingsAnchor.about` when that settles.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  /// Where the code lives; the same address the About dialog gives.
  static const repository = 'https://github.com/lohanidamodar/karmashala-app';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final identity = buildIdentity();
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
    );
    return SettingsSection(
      title: 'KARMASHALA',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'An agent development environment: Claude Code, Codex and '
            'Antigravity in terminal panes, across projects.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Insets.md),
          SettingsRow(
            label: 'Version',
            control: SelectableText(
              // An empty define would draw a blank, which reads as a
              // rendering fault rather than an unstamped build.
              appVersion.isEmpty ? 'not recorded' : appVersion,
              style: mono,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text('Build', style: theme.textTheme.bodyMedium),
          const SizedBox(height: Insets.xs),
          // Selectable, because the point of this box is that the line ends
          // up in an issue.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Insets.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: SelectableText(identity, style: mono),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'This is the line every log starts with — paste it into a bug '
            'report.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.md),
          SettingsRow(
            label: 'Source',
            control: SelectableText(
              repository,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: Insets.md),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              OutlinedButton.icon(
                icon: const Icon(AppIcons.copy, size: Chrome.iconAction),
                label: const Text('Copy build details'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: identity));
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Build details copied')),
                  );
                },
              ),
              OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Karmashala',
                  applicationVersion: appVersion.isEmpty
                      ? 'version not recorded'
                      : appVersion,
                ),
                child: const Text('Open source licences'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
