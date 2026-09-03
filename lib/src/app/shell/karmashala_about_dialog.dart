import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/build_identity.dart';
import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

/// Which build this is, in the form a bug report needs.
///
/// **It shows [buildIdentity] rather than composing its own line.** That
/// function is already the one every log starts with, and its comment gives the
/// reason this dialog exists in the shape it does: the owner's reports have
/// arrived as a copied log with no way to tell whether the fix being discussed
/// was even in the running build. Two surfaces describing the same build in two
/// different ways would put that question back.
///
/// So the version can read **`version not recorded`**, and that is correct
/// rather than a gap. The version is a `--dart-define` set by the release
/// recipe; a `flutter run` does not set it, and there is no runtime source for
/// `pubspec.yaml` without a plugin. A constant kept in step by hand drifts
/// silently, and a dialog confidently naming the wrong version costs more than
/// one that admits it does not know — which is exactly the trap an About box
/// is usually built into.
///
/// Licences come from Flutter's own [LicenseRegistry] via [showLicensePage],
/// which enumerates every dependency that shipped a licence — including the two
/// packages this app carries itself, `xterm2` as a git dependency and
/// `flutter_pty` by path. Hand-maintaining that list would go stale the first
/// time a dependency moved.
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
      content: SizedBox(
        width: 520,
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
            // up in an issue. The same string the logs carry, so a pasted log
            // and a pasted About box cannot disagree.
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
            // line where a version belongs, which reads as a rendering fault
            // rather than as an unstamped build.
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
