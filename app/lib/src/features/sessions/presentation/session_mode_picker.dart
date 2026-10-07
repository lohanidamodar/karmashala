import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec, PermissionRisk;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionModeOption;

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/acp_session_providers.dart';
import '../application/session_modes_providers.dart';

/// **The agent's own modes**: what the session's agent offers
/// at runtime, by name, with the one it is in selected. Nothing at all — no
/// width either — for a session whose agent has announced none. For an ACP
/// session this *is* the permission axis: Karmashala's rung only picked the
/// mode the agent started in, and the PTY permission chip stands down. A mode
/// the agent's spec places on a rung says so, and a bypassing one is
/// confirmed before it is set.
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
    final spec = ref.watch(sessionAcpSpecProvider(sessionId));
    final current = modes.current;
    final label = current?.name ?? modes.currentModeId ?? 'Mode';
    final rung = current == null ? null : rungOfModeOption(spec, current);
    final dangerous = rung?.isDangerous ?? false;
    final scheme = Theme.of(context).colorScheme;
    final picker = PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (modeId) => _apply(context, ref, modeId, spec),
      itemBuilder: (context) => [
        for (final mode in modes.availableModes)
          _item(
            mode,
            rungOfModeOption(spec, mode),
            mode.id == modes.currentModeId,
            scheme,
          ),
      ],
      child: Tooltip(
        message: [
          'Agent mode: $label',
          ?current?.description,
          if (rung != null) '${rung.label}: ${rung.description}',
        ].join('\n'),
        child: PickerFace(
          icon: dangerous ? AppIcons.warning : AppIcons.slidersHorizontal,
          label: label,
          qualifiers: [?rung?.shortLabel],
          alarming: dangerous,
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

  static PopupMenuEntry<String> _item(
    SessionModeOption mode,
    PermissionRisk? rung,
    bool selected,
    ColorScheme scheme,
  ) => DesktopMenuDetailItem<String>(
    value: mode.id,
    selected: selected,
    label: mode.name,
    badge: rung?.shortLabel,
    badgeColor: rung == null
        ? null
        : rung.isDangerous
        ? scheme.error
        : scheme.onSurfaceVariant,
    // The badge names the rung; its words stand in only for a bare mode.
    detail:
        mode.description ??
        rung?.description ??
        'The agent\'s own mode "${mode.id}".',
  );

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    String modeId,
    AcpLaunchSpec? spec,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final modes = ref.read(sessionModesProvider(sessionId));
    final mode = modes?.availableModes.where((m) => m.id == modeId).firstOrNull;
    final rung = mode == null ? null : rungOfModeOption(spec, mode);
    if (mode != null &&
        (rung?.isDangerous ?? false) &&
        modeId != modes?.currentModeId) {
      final confirmed = await _confirmDangerous(context, mode.name);
      if (confirmed != true) return;
    }
    final refusal = await ref
        .read(sessionModesActionsProvider)
        .setMode(sessionId, modeId);
    if (refusal == null) return;
    messenger?.showSnackBar(SnackBar(content: Text(refusal)));
  }

  Future<bool?> _confirmDangerous(BuildContext context, String modeName) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: DesktopDialogTitle(
            icon: AppIcons.warning,
            title: '$modeName?',
            subtitle: PermissionRisk.bypass.label,
          ),
          content: BoundedDialogContent(
            width: DialogWidth.narrow,
            child: Text(
              'In $modeName the agent makes every file edit and runs every '
              'command without asking, and Karmashala answers its permission '
              'requests itself. Nothing here can stop a command the agent has '
              'already decided to run.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            DestructiveButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Use $modeName'),
            ),
          ],
        ),
      );
}

/// The rung [spec] places [mode] on, by its id and then its name; null for a
/// mode nobody placed.
PermissionRisk? rungOfModeOption(AcpLaunchSpec? spec, SessionModeOption mode) =>
    spec?.rungOfOffered(mode.id, mode.name);
