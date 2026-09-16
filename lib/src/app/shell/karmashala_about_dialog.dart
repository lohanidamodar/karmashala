import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Which build this is, in the form a bug report needs: [buildIdentity], the
/// same line every log starts with, so a pasted log cannot disagree with it.
class KarmashalaAboutDialog extends StatelessWidget {
  const KarmashalaAboutDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const KarmashalaAboutDialog(),
  );

  static const _repository = 'https://github.com/lohanidamodar/karmashala-app';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final identity = buildIdentity();
    return AlertDialog(
      title: const Text('About Karmashala'),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'An agent development environment: Claude Code, Codex and '
              'Antigravity in terminal panes, across projects.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.md),
            // Selectable, because the point of this box is that the line ends
            // up in an issue.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Insets.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(
                identity,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
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
            SelectableText(
              _repository,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
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
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Karmashala',
            // Not `appVersion` directly: an empty define would draw a blank
            // line, which reads as a rendering fault, not an unstamped build.
            applicationVersion: appVersion.isEmpty
                ? 'version not recorded'
                : appVersion,
          ),
          child: const Text('Open source licences'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
