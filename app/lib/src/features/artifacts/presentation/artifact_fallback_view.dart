import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/artifact_actions.dart';
import '../domain/artifact_fallback.dart';

/// Where an artifact would be drawn, when it cannot be: the reason in words,
/// and the ways out that still work.
class ArtifactFallbackView extends StatelessWidget {
  const ArtifactFallbackView({
    required this.artifact,
    required this.revision,
    required this.fallback,
    super.key,
  });

  final Artifact artifact;
  final int revision;
  final ArtifactFallback fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.warningCircle,
                size: 28,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                fallback.message,
                key: ValueKey('artifact-fallback-${fallback.reason.name}'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Insets.md),
              ArtifactActionButtons(
                artifact: artifact,
                revision: revision,
                browser: fallback.offersBrowser,
                save: fallback.offersSave,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Open in browser" and "Save", each saying what happened when done.
class ArtifactActionButtons extends ConsumerWidget {
  const ArtifactActionButtons({
    required this.artifact,
    required this.revision,
    this.browser = true,
    this.save = true,
    this.dense = false,
    super.key,
  });

  final Artifact artifact;
  final int revision;
  final bool browser;
  final bool save;

  /// Icon buttons rather than labelled ones, for a header row.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(artifactActionsProvider);
    Future<void> run(Future<String?> Function() action) async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      String? said;
      try {
        said = await action();
      } on Object catch (error) {
        said = 'That did not work: $error';
      }
      if (said != null) {
        messenger?.showSnackBar(SnackBar(content: Text(said)));
      }
    }

    Future<void> openInBrowser() =>
        run(() => actions.openInBrowser(artifact, revision));
    Future<void> saveIt() => run(() => actions.save(artifact, revision));
    if (dense) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (browser)
            IconButton(
              key: const ValueKey('artifact-open-browser'),
              tooltip: 'Open in browser — outside Karmashala\'s sandbox',
              icon: const Icon(AppIcons.globe, size: 18),
              onPressed: openInBrowser,
            ),
          if (save)
            IconButton(
              key: const ValueKey('artifact-save'),
              tooltip: 'Save a copy',
              icon: const Icon(AppIcons.downloadSimple, size: 18),
              onPressed: saveIt,
            ),
        ],
      );
    }
    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      alignment: WrapAlignment.center,
      children: [
        if (browser)
          OutlinedButton.icon(
            key: const ValueKey('artifact-open-browser'),
            icon: const Icon(AppIcons.globe),
            label: const Text('Open in browser'),
            onPressed: openInBrowser,
          ),
        if (save)
          OutlinedButton.icon(
            key: const ValueKey('artifact-save'),
            icon: const Icon(AppIcons.downloadSimple),
            label: const Text('Save'),
            onPressed: saveIt,
          ),
      ],
    );
  }
}
