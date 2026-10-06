import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/session_model_providers.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/acp_session_providers.dart';
import '../application/session_launcher.dart';
import '../application/session_modes_providers.dart';
import '../application/session_signals.dart';
import 'model_chip.dart';
import 'permission_mode_chip.dart';
import 'session_mode_picker.dart';

/// **Agent ▾ on the session bar**: the model and the permission mode on one
/// face (`Opus · Accept edits`), and one menu holding both pickers — the same
/// [SessionModelChip], [PermissionModeChip] and [SessionModePicker] that
/// stood on the bar, so each sets what it always set. Nothing for a session
/// with no agent.
class SessionAgentChip extends ConsumerWidget {
  const SessionAgentChip({
    required this.sessionId,
    this.maxLabelWidth = 180,
    super.key,
  });

  static const barKey = ValueKey('session-agent-chip');

  final String sessionId;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final acp = ref.watch(isAcpSessionProvider(sessionId));
    final model = ref.watch(sessionModelProvider(sessionId));
    final modelLabel = SessionModelMark.namesAModel(model)
        ? modelChipViewFor(model!).label
        : null;

    String? modeLabel;
    var alarming = false;
    if (acp) {
      final modes = ref.watch(sessionModesProvider(sessionId));
      modeLabel = modes?.current?.name ?? modes?.currentModeId;
    } else {
      final effective = ref
          .read(sessionLauncherProvider)
          .effectivePermissionFor(sessionId);
      if (effective == null) return const SizedBox.shrink();
      final support = effective.descriptor?.launch.permission;
      final known = support != null && support.isKnown;
      modeLabel = known
          ? describeSelectionFamiliarShort(support, effective.selection)
          : 'Not established';
      alarming = !known || support.isDangerous(effective.selection);
    }
    final parts = [?modelLabel, ?modeLabel];
    return PopupMenuButton<void>(
      tooltip: '',
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [_AgentPickers(sessionId: sessionId)],
      child: Tooltip(
        message: 'Agent: the model and what it may do without asking',
        child: PickerFace(
          icon: alarming ? AppIcons.warning : AppIcons.robot,
          label: parts.isEmpty ? 'Agent' : parts.join(' · '),
          alarming: alarming,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
  }
}

/// The menu's one entry: both pickers, each opening its own list over it, so
/// the menu stays while a model and then a mode are picked.
class _AgentPickers extends PopupMenuEntry<void> {
  const _AgentPickers({required this.sessionId});

  final String sessionId;

  @override
  double get height => kMinInteractiveDimension * 2;

  @override
  bool represents(void value) => false;

  @override
  State<_AgentPickers> createState() => _AgentPickersState();
}

class _AgentPickersState extends State<_AgentPickers> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    final sessionId = widget.sessionId;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MODEL', style: label),
          const SizedBox(height: Insets.xs),
          SessionModelChip(sessionId: sessionId),
          const SizedBox(height: Insets.sm),
          Text('PERMISSIONS', style: label),
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.sm,
            children: [
              PermissionModeChip(sessionId: sessionId),
              SessionModePicker(sessionId: sessionId, leadingGap: false),
            ],
          ),
        ],
      ),
    );
  }
}
