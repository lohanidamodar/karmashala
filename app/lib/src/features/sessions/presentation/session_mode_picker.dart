import 'package:agent_cli/descriptors.dart'
    show
        AcpLaunchSpec,
        AgentPermissionSupport,
        PermissionRisk,
        PermissionSelection;
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
import '../application/session_launcher.dart';
import '../application/session_modes_providers.dart';
import '../application/session_signals.dart';
import 'permission_mode_chip.dart' show PermissionChoice;

/// **The agent's own modes**: what the session's agent offers
/// at runtime, by name, with the one it is in selected. For an ACP session
/// this *is* the permission axis, and the PTY permission chip stands down.
/// Before the agent has announced any, an ACP session shows the modes its
/// descriptor declares on the same face, and a pick there is the mode the
/// session starts in. A mode the agent's spec places on a rung says so, and a
/// bypassing one is confirmed before it is set. Nothing at all — no width
/// either — for any other session with no modes.
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
      if (!ref.watch(isAcpSessionProvider(sessionId))) {
        return const SizedBox.shrink();
      }
      return _StartingModePicker(
        sessionId: sessionId,
        maxLabelWidth: maxLabelWidth,
        leadingGap: leadingGap,
      );
    }
    final spec = ref.watch(sessionAcpSpecProvider(sessionId));
    final current = modes.current;
    final label = current?.name ?? modes.currentModeId ?? 'Mode';
    final rung = current == null ? null : rungOfModeOption(spec, current);
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
        child: _ModeFace(
          label: label,
          rung: rung,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
    return _gapped(picker, leadingGap);
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
    badgeColor: _badgeColor(rung, scheme),
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
}

/// **The mode a chat session will start in**, drawn from its descriptor's
/// one permission axis and the session's effective selection — the same
/// `effectivePermissionFor` / `setPermissionMode` the PTY chip uses — on the
/// face the live modes take, so nothing jumps when the agent announces them.
/// Nothing for an agent whose modes were never established.
class _StartingModePicker extends ConsumerWidget {
  const _StartingModePicker({
    required this.sessionId,
    required this.maxLabelWidth,
    required this.leadingGap,
  });

  final String sessionId;
  final double maxLabelWidth;
  final bool leadingGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `setPermissionMode` publishes `reconfigured` against this row.
    ref.watchSession(sessionId);
    final effective = ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(sessionId);
    final support = effective?.descriptor?.launch.permission;
    if (effective == null || support == null || support.axes.length != 1) {
      return const SizedBox.shrink();
    }
    final axis = support.axes.single;
    final selectedId =
        effective.selection.valueFor(axis.id) ?? axis.defaultValueId;
    final selected = axis.values.where((v) => v.id == selectedId).firstOrNull;
    if (selected == null) return const SizedBox.shrink();
    final agentName = effective.descriptor?.displayName ?? 'This agent';
    final scheme = Theme.of(context).colorScheme;
    final origin = effective.inherited
        ? 'Following the $agentName default in Settings.'
        : 'Set for this session.';
    final picker = PopupMenuButton<PermissionChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (choice) => _apply(context, ref, choice, support),
      itemBuilder: (context) => [
        DesktopMenuDetailItem<PermissionChoice>(
          value: PermissionChoice.followDefault,
          selected: effective.inherited,
          label: 'Follow the Settings default',
          detail: effective.inherited
              ? 'Currently ${selected.label} for $agentName. Changing that '
                    'setting changes this session too.'
              : 'Start in the $agentName default from Settings.',
        ),
        const DesktopMenuDivider(),
        for (final value in axis.values)
          DesktopMenuDetailItem<PermissionChoice>(
            value: PermissionChoice(axis.id, value.id),
            selected: !effective.inherited && value.id == selected.id,
            label: value.label,
            badge: value.permits.shortLabel,
            badgeColor: _badgeColor(value.permits, scheme),
            detail: value.description,
          ),
      ],
      child: Tooltip(
        message: [
          'Starts in: ${selected.label}',
          selected.description,
          '${selected.permits.label}: ${selected.permits.description}',
          origin,
        ].join('\n'),
        child: _ModeFace(
          label: selected.label,
          rung: selected.permits,
          dangerous: selected.isDangerous,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
    return _gapped(picker, leadingGap);
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    PermissionChoice choice,
    AgentPermissionSupport support,
  ) async {
    final launcher = ref.read(sessionLauncherProvider);
    final selection = choice.axisId == null
        ? null
        : support.normalise(
            PermissionSelection({choice.axisId!: choice.valueId!}),
          );
    // Asked before the row is written, so Cancel leaves it as it was.
    if (selection != null && support.isDangerous(selection)) {
      final value = support.axes.single.values
          .where((v) => v.id == choice.valueId)
          .firstOrNull;
      final confirmed = await _confirmDangerous(
        context,
        value?.label ?? '${choice.valueId}',
      );
      if (confirmed != true) return;
    }
    launcher.setPermissionMode(sessionId, selection);
  }
}

/// One face for a mode, live or not yet started: the mode's name, the rung
/// it sits on when that says something more, and a warning on a bypass.
class _ModeFace extends StatelessWidget {
  const _ModeFace({
    required this.label,
    required this.rung,
    required this.maxLabelWidth,
    this.dangerous = false,
  });

  final String label;
  final PermissionRisk? rung;
  final double maxLabelWidth;
  final bool dangerous;

  @override
  Widget build(BuildContext context) {
    final alarming = dangerous || (rung?.isDangerous ?? false);
    final qualifier = rung?.shortLabel;
    return PickerFace(
      icon: alarming ? AppIcons.warning : AppIcons.slidersHorizontal,
      label: label,
      qualifiers: [if (qualifier != null && qualifier != label) qualifier],
      alarming: alarming,
      maxLabelWidth: maxLabelWidth,
    );
  }
}

Widget _gapped(Widget picker, bool leadingGap) => leadingGap
    ? Padding(
        padding: const EdgeInsetsDirectional.only(start: Insets.xs),
        child: picker,
      )
    : picker;

Color? _badgeColor(PermissionRisk? rung, ColorScheme scheme) => rung == null
    ? null
    : rung.isDangerous
    ? scheme.error
    : scheme.onSurfaceVariant;

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

/// The rung [spec] places [mode] on, by its id and then its name; null for a
/// mode nobody placed.
PermissionRisk? rungOfModeOption(AcpLaunchSpec? spec, SessionModeOption mode) =>
    spec?.rungOfOffered(mode.id, mode.name);
