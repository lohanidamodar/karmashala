import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../application/artifact_providers.dart';
import 'artifacts_panel.dart';

/// How many artifacts a session has shown, on its tab: a person in the
/// terminal view sees there is something to open in the Artifacts panel.
class ArtifactCountBadge extends StatelessWidget {
  const ArtifactCountBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$count artifact${count == 1 ? '' : 's'} shown in this session',
      child: Row(
        key: const ValueKey('artifact-count-badge'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.fileCode,
            size: Chrome.iconSmall,
            color: scheme.primary,
          ),
          const SizedBox(width: Insets.xxs),
          Text(
            '$count',
            style: Chrome.tabLabel.copyWith(color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// A child session's artifacts, from the subagents panel: how many, and a tap
/// to open them. Nothing, and no width, for a child that showed none.
class ChildArtifactsLink extends ConsumerWidget {
  const ChildArtifactsLink({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      sessionArtifactsProvider(sessionId).select((a) => a.value?.length ?? 0),
    );
    if (count == 0) return const SizedBox.shrink();
    return TextButton.icon(
      key: ValueKey('child-artifacts-$sessionId'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: const Icon(AppIcons.fileCode),
      label: Text('$count artifact${count == 1 ? '' : 's'}'),
      onPressed: () => showAdaptiveSidePanel<void>(
        context: context,
        title: 'Artifacts',
        builder: (_) => SizedBox(
          height: 560,
          child: SessionArtifactsView(sessionId: sessionId),
        ),
      ),
    );
  }
}
