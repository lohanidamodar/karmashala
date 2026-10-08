import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../application/visual_providers.dart';

/// One visual an agent drew, where it drew it. Watches its own row, so an
/// update in place redraws it without rebuilding the message it hangs on;
/// one that cannot be drawn is contained like a message that cannot.
class SessionVisualBlock extends ConsumerWidget {
  const SessionVisualBlock({
    required this.sessionId,
    required this.visualId,
    super.key,
  });

  final String sessionId;
  final String visualId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visual = ref.watch(
      sessionVisualProvider((sessionId: sessionId, id: visualId)),
    );
    if (visual == null) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('session-visual-$visualId'),
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: MessageBoundary(
        raw: jsonEncode(sessionVisualToJson(visual)),
        child: VisualCard(
          kind: visual.kind,
          title: visual.title,
          data: visual.data,
          image: (context, _) => _KeptImage(visual),
        ),
      ),
    );
  }
}

/// [visuals] by id, one under another.
class SessionVisualBlocks extends StatelessWidget {
  const SessionVisualBlocks({
    required this.sessionId,
    required this.visualIds,
    super.key,
  });

  final String sessionId;
  final List<String> visualIds;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final id in visualIds)
        SessionVisualBlock(sessionId: sessionId, visualId: id),
    ],
  );
}

class _KeptImage extends ConsumerWidget {
  const _KeptImage(this.visual);

  final SessionVisual visual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(
      visualImageProvider((
        sessionId: visual.sessionId,
        id: visual.id,
        revision: visual.revision,
      )),
    );
    final theme = Theme.of(context);
    return bytes.when(
      loading: () => const InlineSpinner(),
      error: (error, _) => Text(
        "Couldn't load the image: $error",
        style: theme.textTheme.bodySmall?.copyWith(
          color: SemanticColors.of(context).failure,
        ),
      ),
      data: (bytes) => Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        semanticLabel: (visual.data as Map?)?['alt'] as String?,
      ),
    );
  }
}
