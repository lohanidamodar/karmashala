import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../application/acp_session_providers.dart';
import '../application/session_launcher.dart';
import '../application/session_signals.dart';
import 'model_chip.dart';
import 'permission_mode_chip.dart';
import 'session_mode_picker.dart';

/// **The agent's controls on the session bar**: the permission mode, the
/// agent's own mode picker where it has one, and the model, each its own chip
/// on the bar. They were folded into one Agent ▾ menu for a while; the owner
/// wanted them back on the bar, one click each (2026-10-07). The same
/// [PermissionModeChip], [SessionModePicker] and [SessionModelChip] as ever,
/// so each sets what it always set. Nothing for a session with no agent.
class SessionAgentChip extends ConsumerWidget {
  const SessionAgentChip({
    required this.sessionId,
    this.maxLabelWidth = 180,
    super.key,
  });

  static const barKey = ValueKey('session-agent-chip');

  final String sessionId;

  /// Kept for the bar's layout, which hands every host the same width; the
  /// chips size themselves.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final acp = ref.watch(isAcpSessionProvider(sessionId));
    // A PTY session with no launch to read has no permission to show, and
    // so no agent controls at all — as before.
    if (!acp &&
        ref.read(sessionLauncherProvider).effectivePermissionFor(sessionId) ==
            null) {
      return const SizedBox.shrink();
    }
    // Compact on the bar, as the one chip they replaced was: their labels end
    // in an ellipsis rather than pushing the pair off a narrow bar, and each
    // tooltip still names the whole mode and model.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PermissionModeChip(
          sessionId: sessionId,
          maxLabelWidth: maxLabelWidth * 0.6,
        ),
        SessionModePicker(sessionId: sessionId),
        const SizedBox(width: Insets.xs),
        SessionModelChip(
          sessionId: sessionId,
          maxLabelWidth: maxLabelWidth * 0.5,
        ),
      ],
    );
  }
}
