import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_modes_providers.dart';

/// **The agent's own modes** (ACP design, C5): what the session's agent offers
/// at runtime, by name, with the one it is in selected. Nothing at all — no
/// width either — for a session whose agent has announced none; the permission
/// chip beside it is Karmashala's rung, which this never replaces.
class SessionModePicker extends ConsumerWidget {
  const SessionModePicker({
    required this.sessionId,
    this.maxLabelWidth = 120,
    this.leadingGap = true,
    super.key,
  });

  final String sessionId;

  /// How much room the mode's name may take before it ellipsises.
  final double maxLabelWidth;

  /// A gap before the face, taken only when the face is drawn, so a row with
  /// no modes has no stray space where this would be.
  final bool leadingGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(sessionModesProvider(sessionId));
    if (modes == null || modes.availableModes.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = modes.current;
    final label = current?.name ?? modes.currentModeId ?? 'Mode';
    final picker = PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (modeId) => _apply(context, ref, modeId),
      itemBuilder: (context) => [
        for (final mode in modes.availableModes)
          DesktopMenuDetailItem<String>(
            value: mode.id,
            selected: mode.id == modes.currentModeId,
            label: mode.name,
            detail: mode.description ?? 'The agent\'s own mode "${mode.id}".',
          ),
      ],
      child: Tooltip(
        message: current?.description == null
            ? 'Agent mode: $label'
            : 'Agent mode: $label — ${current!.description}',
        child: PickerFace(
          icon: AppIcons.slidersHorizontal,
          label: label,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
    return leadingGap
        ? Padding(
            padding: const EdgeInsetsDirectional.only(start: Insets.xs),
            child: picker,
          )
        : picker;
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    String modeId,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final refusal = await ref
        .read(sessionModesActionsProvider)
        .setMode(sessionId, modeId);
    if (refusal == null) return;
    messenger?.showSnackBar(SnackBar(content: Text(refusal)));
  }
}
