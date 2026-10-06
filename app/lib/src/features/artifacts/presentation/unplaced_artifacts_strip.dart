import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/tokens.dart';

import 'artifact_card.dart';
import 'artifact_viewer.dart';

/// Artifacts this conversation has no row to hang on — shown before the
/// earliest message held, or in a record whose rows carry no time. Kept in
/// reach above the composer rather than filed under the wrong turn.
class UnplacedArtifactsStrip extends ConsumerWidget {
  const UnplacedArtifactsStrip({required this.artifacts, super.key});

  final List<Artifact> artifacts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      key: const ValueKey('artifacts-unplaced'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          Text('Shown earlier:', style: theme.textTheme.labelMedium),
          const SizedBox(width: Insets.xs),
          for (final a in artifacts.reversed)
            Padding(
              padding: const EdgeInsets.only(right: Insets.xs),
              child: ActionChip(
                key: ValueKey('artifact-chip-${a.id}'),
                avatar: Icon(artifactKindIcon(a.kind)),
                label: Text(a.title),
                onPressed: () => openArtifact(context, ref, a),
              ),
            ),
        ],
      ),
    );
  }
}
