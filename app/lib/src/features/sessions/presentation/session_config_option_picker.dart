import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_active_model_providers.dart';
import '../application/session_config_options_providers.dart';
import '../application/session_launcher.dart';
import 'model_chip.dart' show kModelNotRecorded, kModelRunningBadge;

/// **One `select` config option of the session's agent**: its
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
    final active = option.isModel
        ? ref.watch(sessionActiveModelProvider(sessionId))
        : null;
    final face = configOptionFace(option, active: active);
    final name = configOptionLabel(option);
    return PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (value) => _apply(context, ref, value),
      itemBuilder: (context) => _items(active?.modelId),
      child: Tooltip(
        message: [
          '$name: ${face.label}',
          if (active != null && active.label != face.label)
            'Last reported model: ${active.label}',
          ?option.current?.description,
          ?option.description,
        ].join('\n'),
        child: PickerFace(
          icon: configOptionIcon(option),
          label: face.label,
          qualifiers: [?face.qualifier],
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
  }

  /// Choices in the agent's order; a group heading once, before its first
  /// choice, only when the agent grouped them. The one [running] names says
  /// so.
  List<PopupMenuEntry<String>> _items(String? running) {
    final items = <PopupMenuEntry<String>>[
      DesktopMenuHeader<String>(configOptionLabel(option)),
    ];
    String? heading;
    for (final choice in option.choices) {
      if (choice.group != null && choice.group != heading) {
        heading = choice.group;
        items.add(DesktopMenuHeader<String>(heading!));
      }
      final description = choice.description;
      final selected = choice.value == option.currentValue;
      final isRunning = choice.value == running;
      items.add(
        (description == null || description.trim().isEmpty) && !isRunning
            ? DesktopMenuItem<String>(
                value: choice.value,
                label: choice.name,
                icon: configOptionIcon(option),
                selected: selected,
              )
            : DesktopMenuDetailItem<String>(
                value: choice.value,
                selected: selected,
                label: choice.name,
                badge: isRunning ? kModelRunningBadge : null,
                detail: description ?? '',
              ),
      );
    }
    return items;
  }

  Future<void> _apply(BuildContext context, WidgetRef ref, String value) async {
    if (value == option.currentValue) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final launcher = ref.read(sessionLauncherProvider);
    final refusal = await ref
        .read(sessionConfigOptionsActionsProvider)
        .setOption(sessionId, option.id, value);
    if (refusal == null) {
      // The agent's word wins while it runs; the row is what its next start
      // asks for, so a relaunch keeps the pick.
      if (option.isModel) {
        launcher.recordModel(sessionId, value);
      }
      return;
    }
    messenger?.showSnackBar(SnackBar(content: Text(refusal)));
  }
}

String configOptionLabel(SessionConfigOption option) =>
    option.isThinkingLevel ? 'Thinking level' : option.name;

IconData configOptionIcon(SessionConfigOption option) => switch (option) {
  _ when option.isModel => AppIcons.robot,
  _ when option.id == 'fast_mode' => AppIcons.lightning,
  _ => AppIcons.slidersHorizontal,
};

/// The selected setting for the next request. For an unresolved default, use
/// the last model the agent actually reported.
({String label, String? qualifier}) configOptionFace(
  SessionConfigOption option, {
  SessionActiveModel? active,
}) {
  final named =
      option.current?.name ?? option.currentValue?.toString() ?? option.name;
  if (!option.isModel) return (label: named, qualifier: null);
  final followsDefault = option.currentValue == 'default';
  return (
    label: followsDefault ? active?.label ?? kModelNotRecorded : named,
    qualifier: followsDefault && active != null ? 'default' : null,
  );
}

/// A picker per `select` option the session's agent exposes, the `model`
/// one first; nothing at all — no width either — until the agent has
/// announced some. A `boolean` or any other type gets no control here.
/// Where they do not fit on one line they wrap rather than overflow.
class SessionConfigPickers extends ConsumerWidget {
  const SessionConfigPickers({
    required this.sessionId,
    this.maxLabelWidth = 120,
    this.modelOnly = false,
    this.chatSettings = false,
    super.key,
  });

  final String sessionId;
  final double maxLabelWidth;

  /// Only the model's and the thinking level's pickers, for the chat
  /// composer beside Send; the rest (speed) stay on the session bar.
  final bool chatSettings;

  /// Only the model's picker, for a phone's one-line bar; the rest (effort,
  /// speed) are in the session's sheet.
  final bool modelOnly;

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
    return [
      ...options.where((option) => option.isModel),
      ...options.where((option) => !option.isModel && option.isThinkingLevel),
      ...options.where((option) => !option.isModel && !option.isThinkingLevel),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = [
      for (final option in selectable(
        ref.watch(sessionConfigOptionsProvider(sessionId)),
      ))
        if (modelOnly
            ? option.isModel
            : !chatSettings || option.isModel || option.isThinkingLevel)
          option,
    ];
    if (options.isEmpty) return const SizedBox.shrink();
    if (options.length == 1) {
      return SessionConfigOptionPicker(
        sessionId: sessionId,
        option: options.single,
        maxLabelWidth: maxLabelWidth,
      );
    }
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final option in options)
          SessionConfigOptionPicker(
            sessionId: sessionId,
            option: option,
            maxLabelWidth: maxLabelWidth,
          ),
      ],
    );
  }
}
