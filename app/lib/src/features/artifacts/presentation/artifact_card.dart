import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/side_panel_state.dart';
import '../application/artifact_providers.dart';
import '../domain/artifact_fallback.dart';
import 'artifact_content_view.dart';
import 'artifact_fallback_view.dart';
import 'artifact_screen.dart';
import 'artifact_viewer.dart';

/// The artifact a person opened in the side panel, by id.
class SelectedArtifactController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedArtifactProvider =
    NotifierProvider<SelectedArtifactController, String?>(
      SelectedArtifactController.new,
    );

/// Opens [artifact]: beside the session where the window has room for the
/// side panel, full screen where it does not (a phone).
void openArtifact(BuildContext context, WidgetRef ref, Artifact artifact) {
  final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  if (!compact && ref.read(sidePanelRoomProvider)) {
    ref.read(selectedArtifactProvider.notifier).select(artifact.id);
    ref.read(sidePanelProvider.notifier).show(SidePanelSurface.artifacts);
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ArtifactScreen(
        sessionId: artifact.sessionId,
        artifactId: artifact.id,
      ),
    ),
  );
}

/// Inline under this size, a drawn kind shows itself in the card.
const _inlineBytes = 64 * 1024;

/// An artifact at the turn that made it: its title, kind and revision, a
/// small one drawn in place, and Open, Open in browser and Save. Watches its
/// own row, so each revision redraws it.
class ArtifactCard extends ConsumerWidget {
  const ArtifactCard({required this.artifact, super.key});

  final Artifact artifact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live =
        ref.watch(
          sessionArtifactProvider((
            sessionId: artifact.sessionId,
            id: artifact.id,
          )),
        ) ??
        artifact;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final note = artifactSourceNote(live);
    final inline =
        live.kind != ArtifactKind.pdf &&
        live.size <= _inlineBytes;
    return Container(
      key: ValueKey('artifact-card-${live.id}'),
      margin: const EdgeInsets.only(top: Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => openArtifact(context, ref, live),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                Insets.sm,
                Insets.xs,
                Insets.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    artifactKindIcon(live.kind),
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          live.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${artifactKindLabel(live.kind)} · revision '
                          '${live.revision}',
                          key: ValueKey('artifact-card-meta-${live.id}'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: ValueKey('artifact-open-${live.id}'),
                    onPressed: () => openArtifact(context, ref, live),
                    child: const Text('Open'),
                  ),
                  ArtifactActionButtons(
                    artifact: live,
                    revision: live.revision,
                    dense: true,
                  ),
                ],
              ),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.md,
                Insets.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    AppIcons.warningCircle,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      note.message,
                      key: ValueKey('artifact-card-note-${note.reason.name}'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (inline)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ClipRect(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.md,
                    0,
                    Insets.md,
                    Insets.md,
                  ),
                  child: ArtifactContentView(
                    artifact: live,
                    revision: live.revision,
                    compact: true,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
