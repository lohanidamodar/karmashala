import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/session_context.dart';
import '../application/artifact_providers.dart';
import '../domain/artifact_fallback.dart';
import 'artifact_card.dart';
import 'artifact_viewer.dart';

/// The Artifacts side-panel surface: the session on screen's artifacts, the
/// one opened beneath them. Newest first, as a person looks for the last one
/// shown.
class ArtifactsPanel extends ConsumerWidget {
  const ArtifactsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(panelSessionIdProvider);
    if (sessionId == null) {
      return const PanePlaceholder(
        message: 'Open a session to see what its agent has shown.',
        icon: AppIcons.fileCode,
      );
    }
    return SessionArtifactsView(sessionId: sessionId);
  }
}

/// [sessionId]'s artifacts and the open one. Also what the subagents panel
/// shows for a child.
class SessionArtifactsView extends ConsumerWidget {
  const SessionArtifactsView({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listed = ref.watch(sessionArtifactsProvider(sessionId));
    return listed.when(
      loading: () => const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Reading artifacts',
        ),
      ),
      error: (error, _) => PanePlaceholder(
        message: artifactLoadFallback(error).message,
        icon: AppIcons.warningCircle,
      ),
      data: (artifacts) {
        if (artifacts.isEmpty) {
          return const PanePlaceholder(
            message:
                'Nothing shown yet. An agent shows a page, diagram or image '
                'here with artifact_show.',
            icon: AppIcons.fileCode,
          );
        }
        final picked = ref.watch(selectedArtifactProvider);
        final open = artifacts.any((a) => a.id == picked)
            ? picked!
            : artifacts.last.id;
        final newestFirst = artifacts.reversed.toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final a in newestFirst)
                    _ArtifactRow(artifact: a, selected: a.id == open),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ArtifactViewer(
                key: ValueKey('artifact-viewer-$open'),
                sessionId: sessionId,
                artifactId: open,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ArtifactRow extends ConsumerWidget {
  const _ArtifactRow({required this.artifact, required this.selected});

  final Artifact artifact;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = artifactSourceNote(artifact);
    return ListTile(
      key: ValueKey('artifact-row-${artifact.id}'),
      dense: true,
      selected: selected,
      leading: Icon(artifactKindIcon(artifact.kind), size: 18),
      title: Text(
        artifact.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${artifactKindLabel(artifact.kind)} · revision ${artifact.revision}'
        '${stale == null ? '' : ' · source ${_staleWord(stale.reason)}'}',
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.md),
      onTap: () =>
          ref.read(selectedArtifactProvider.notifier).select(artifact.id),
    );
  }

  static String _staleWord(ArtifactFallbackReason reason) => switch (reason) {
    ArtifactFallbackReason.sourceMissing => 'gone',
    ArtifactFallbackReason.hostUnreachable => 'out of reach',
    ArtifactFallbackReason.tooLarge => 'too large',
    _ => 'stale',
  };
}
