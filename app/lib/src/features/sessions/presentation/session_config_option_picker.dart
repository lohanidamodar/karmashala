import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_config_options_providers.dart';

/// **One `select` config option of the session's agent** (ACP design, C5): its
/// choices by name, the one the agent holds selected, set through
/// `sessions.setConfigOption`. The agent's `model` option wears the robot the
/// PTY model chip wears, since it stands in that chip's place.
class SessionConfigOptionPicker extends ConsumerWidget {
  const SessionConfigOptionPicker({
    required this.sessionId,
    required this.option,
    this.maxLabelWidth = 120,
    super.key,
  });

  final String sessionId;
  final SessionConfigOption option;

  /// How much room the choice's name may take before it ellipsises.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = option.current;
    final label =
        current?.name ?? option.currentValue?.toString() ?? option.name;
    return PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (value) => _apply(context, ref, value),
      itemBuilder: (context) => _items(),
      child: Tooltip(
        message: [
          '${option.name}: $label',
          ?current?.description,
          ?option.description,
        ].join('\n'),
        child: PickerFace(
          icon: option.isModel ? AppIcons.robot : AppIcons.slidersHorizontal,
          label: label,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
  }

  /// Choices in the agent's order; a group heading once, before its first
  /// choice, only when the agent grouped them.
  List<PopupMenuEntry<String>> _items() {
    final items = <PopupMenuEntry<String>>[];
    String? heading;
    for (final choice in option.choices) {
      if (choice.group != null && choice.group != heading) {
        heading = choice.group;
        items.add(DesktopMenuHeader<String>(heading!));
      }
      items.add(
        DesktopMenuDetailItem<String>(
          value: choice.value,
          selected: choice.value == option.currentValue,
          label: choice.name,
          detail: choice.description ?? 'The agent\'s own "${choice.value}".',
        ),
      );
    }
    return items;
  }

  Future<void> _apply(BuildContext context, WidgetRef ref, String value) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final refusal = await ref
        .read(sessionConfigOptionsActionsProvider)
        .setOption(sessionId, option.id, value);
    if (refusal == null) return;
    messenger?.showSnackBar(SnackBar(content: Text(refusal)));
  }
}

/// A picker per `select` option the session's agent exposes, the `model`
/// one first; nothing at all — no width either — until the agent has
/// announced some. A `boolean` or any other type gets no control here.
class SessionConfigPickers extends ConsumerWidget {
  const SessionConfigPickers({
    required this.sessionId,
    this.maxLabelWidth = 120,
    super.key,
  });

  final String sessionId;
  final double maxLabelWidth;

  /// The options drawn, in the order drawn.
  static List<SessionConfigOption> selectable(
    SessionConfigOptionsChanged? announced,
  ) {
    // Not the mode: the session mode picker already draws it, and an agent
    // that announces its modes as a config option too made two "Agent" chips.
    final options = [
      for (final option in announced?.options ?? const <SessionConfigOption>[])
        if (option.isSelect && option.choices.isNotEmpty && !option.isMode)
          option,
    ];
    options.sort((a, b) => (a.isModel ? 0 : 1) - (b.isModel ? 0 : 1));
    return options;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = selectable(
      ref.watch(sessionConfigOptionsProvider(sessionId)),
    );
    if (options.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, option) in options.indexed) ...[
          if (index > 0) const SizedBox(width: Insets.xs),
          SessionConfigOptionPicker(
            sessionId: sessionId,
            option: option,
            maxLabelWidth: maxLabelWidth,
          ),
        ],
      ],
    );
  }
}
