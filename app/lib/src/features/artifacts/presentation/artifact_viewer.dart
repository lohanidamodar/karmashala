import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/artifact_providers.dart';
import '../domain/artifact_fallback.dart';
import 'artifact_content_view.dart';
import 'artifact_fallback_view.dart';

/// The glyph for an artifact's kind.
IconData artifactKindIcon(ArtifactKind kind) => switch (kind) {
  ArtifactKind.html => AppIcons.globe,
  ArtifactKind.svg || ArtifactKind.image => AppIcons.image,
  ArtifactKind.mermaid => AppIcons.treeStructure,
  ArtifactKind.markdown => AppIcons.bookOpen,
  ArtifactKind.pdf => AppIcons.file,
};

/// What a person reads an artifact's kind as.
String artifactKindLabel(ArtifactKind kind) => switch (kind) {
  ArtifactKind.html => 'HTML',
  ArtifactKind.svg => 'SVG',
  ArtifactKind.mermaid => 'Diagram',
  ArtifactKind.markdown => 'Markdown',
  ArtifactKind.image => 'Image',
  ArtifactKind.pdf => 'PDF',
};

/// One artifact opened: its header (kind, revision picker, network switch
/// for a page, Open in browser, Save), why its copy may be stale, and the
/// content. Follows the newest revision until another is picked, so a
/// rewrite reloads it.
class ArtifactViewer extends ConsumerStatefulWidget {
  const ArtifactViewer({
    required this.sessionId,
    required this.artifactId,
    super.key,
  });

  final String sessionId;
  final String artifactId;

  @override
  ConsumerState<ArtifactViewer> createState() => _ArtifactViewerState();
}

class _ArtifactViewerState extends ConsumerState<ArtifactViewer> {
  int? _picked;

  @override
  void didUpdateWidget(ArtifactViewer old) {
    super.didUpdateWidget(old);
    if (old.artifactId != widget.artifactId) _picked = null;
  }

  @override
  Widget build(BuildContext context) {
    final artifact = ref.watch(
      sessionArtifactProvider((
        sessionId: widget.sessionId,
        id: widget.artifactId,
      )),
    );
    if (artifact == null) {
      final list = ref.watch(sessionArtifactsProvider(widget.sessionId));
      return list.isLoading
          ? const Center(
              child: InlineSpinner(
                size: InlineSpinnerSize.large,
                semanticsLabel: 'Reading artifacts',
              ),
            )
          : PanePlaceholder(
              message: list.hasError
                  ? artifactLoadFallback(list.error!).message
                  : 'This session has no artifact ${widget.artifactId}.',
              icon: AppIcons.warningCircle,
            );
    }
    final revision = _picked ?? artifact.revision;
    final note = artifactSourceNote(artifact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          artifact: artifact,
          revision: revision,
          following: _picked == null,
          onPick: (r) =>
              setState(() => _picked = r == artifact.revision ? null : r),
        ),
        if (note != null)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.xs,
              ),
              child: Text(
                note.message,
                key: ValueKey('artifact-note-${note.reason.name}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ArtifactContentView(artifact: artifact, revision: revision),
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.artifact,
    required this.revision,
    required this.following,
    required this.onPick,
  });

  final Artifact artifact;
  final int revision;
  final bool following;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final revisions = ref.watch(artifactRevisionsProvider(artifact.id)).value;
    final kept = [
      for (final r in revisions ?? const <ArtifactRevisionSummary>[])
        r.revision,
    ];
    if (!kept.contains(artifact.revision)) kept.add(artifact.revision);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, Insets.xs, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(artifactKindIcon(artifact.kind)),
              const SizedBox(width: Insets.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(
                  artifact.title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          DropdownButton<int>(
            key: const ValueKey('artifact-revision'),
            value: revision,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final r in kept.reversed)
                DropdownMenuItem(
                  value: r,
                  child: Text(
                    r == artifact.revision ? 'Revision $r (newest)' : 'Revision $r',
                  ),
                ),
            ],
            onChanged: (r) {
              if (r != null) onPick(r);
            },
          ),
          if (artifact.kind == ArtifactKind.html)
            _NetworkSwitch(artifact: artifact),
          ArtifactActionButtons(
            artifact: artifact,
            revision: revision,
            dense: true,
          ),
        ],
      ),
    );
  }
}

/// Network for one page, off until a person allows it — on the server, so
/// every client sees the one setting.
class _NetworkSwitch extends ConsumerWidget {
  const _NetworkSwitch({required this.artifact});

  final Artifact artifact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: artifact.networkAllowed
          ? 'This page may load from https sites. Files and plain http stay '
                'shut.'
          : 'This page can reach no network. Allow it only for a page you '
                'trust to load from the web.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Network', style: Theme.of(context).textTheme.labelMedium),
          Switch(
            key: const ValueKey('artifact-network'),
            value: artifact.networkAllowed,
            onChanged: (allowed) => ref.read(setArtifactNetworkProvider)(
              artifact.id,
              allowed: allowed,
            ),
          ),
        ],
      ),
    );
  }
}
