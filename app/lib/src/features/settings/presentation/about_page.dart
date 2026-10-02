import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/store_rating.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → About: the About dialog's facts (`KarmashalaAboutDialog`), where
/// someone filing a bug looks in Settings. Read-only: [buildIdentity], the same
/// line every log starts with, so a pasted log cannot disagree with it.
///
/// Drawn as [SettingsAnchor.about], under the heading the catalogue gives it,
/// so search and a link land on it.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  /// Where the code lives; the same address the About dialog gives.
  static const repository = 'https://github.com/lohanidamodar/karmashala';

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
      title: SettingsAnchor.about.heading,
      // Board "Karmashala": flat rows — the version as a value, the build
      // line under its row's label with Copy beside it, then the source and
      // the licences.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'An agent development environment: Claude Code, Codex and '
            'Antigravity in terminal panes, across projects.',
          ),
          SettingsRow(
            label: 'Version',
            control: SelectableText(
              // An empty define would draw a blank, which reads as a
              // rendering fault rather than an unstamped build.
              appVersion.isEmpty ? 'not recorded' : appVersion,
              style: mono,
            ),
          ),
          SettingsRow(
            label: 'Build',
            // Selectable, because the point of this line is that it ends up
            // in an issue.
            helpWidget: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(identity, style: mono),
                const SizedBox(height: Insets.xs),
                const Text(
                  'This is the line every log starts with — paste it into a '
                  'bug report.',
                ),
              ],
            ),
            control: OutlinedButton.icon(
              icon: const Icon(AppIcons.copy),
              label: const Text('Copy build details'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: identity));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Build details copied')),
                );
              },
            ),
          ),
          SettingsRow(
            label: 'Source',
            control: SelectableText(
              repository,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (ratesOnStore)
            SettingsRow(
              label: 'Rate Karmashala',
              help: 'On Google Play — it helps other people find it.',
              control: OutlinedButton.icon(
                icon: const Icon(AppIcons.star),
                label: const Text('Rate'),
                onPressed: requestStoreRating,
              ),
            ),
          SettingsRow(
            label: 'Licences',
            help: 'The open source this build is made of.',
            control: OutlinedButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Karmashala',
                applicationVersion: appVersion.isEmpty
                    ? 'version not recorded'
                    : appVersion,
              ),
              child: const Text('Open source licences'),
            ),
          ),
        ],
      ),
    );
  }
}
