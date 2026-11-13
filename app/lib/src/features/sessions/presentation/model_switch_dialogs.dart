import 'package:flutter/material.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// What a person chose for a model pick made while the agent is mid-turn.
enum MidTurnModelChoice {
  /// Typed the moment the turn ends.
  afterTurn,

  /// The turn is stopped and the agent relaunched on the model, resumed.
  relaunch,
}

const String kSwitchAfterTurnLabel = 'Switch after this turn';
const String kStopAndRelaunchLabel = 'Stop and relaunch';
const String kStartNowLabel = 'Start now';
const String kKeepForNextLaunchLabel = 'Keep for next launch';

/// Asks how a pick of [model] should reach [agentName] while it is mid-turn.
/// Null for Cancel or a dismissal: nothing is recorded then.
Future<MidTurnModelChoice?> askMidTurnModelSwitch(
  BuildContext context, {
  required String agentName,
  required String model,
}) => showDialog<MidTurnModelChoice>(
  context: context,
  builder: (context) {
    void answer(MidTurnModelChoice? choice) =>
        Navigator.of(context).pop(choice);
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.robot,
        title: 'Switch to $model?',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Text(
          '$agentName is mid-turn. Karmashala never types into a running '
          'turn. It can switch the moment this turn ends, or stop the turn '
          'and relaunch on $model with the conversation resumed.',
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => answer(null),
          child: const Text('Cancel'),
        ),
        // Stopping loses the turn's unfinished work, so it is never the
        // filled default.
        OutlinedButton(
          onPressed: () => answer(MidTurnModelChoice.relaunch),
          child: const Text(kStopAndRelaunchLabel),
        ),
        FilledButton(
          onPressed: () => answer(MidTurnModelChoice.afterTurn),
          child: const Text(kSwitchAfterTurnLabel),
        ),
      ],
    );
  },
);

/// Asks whether a session nothing runs should start now on [model], which is
/// already recorded. False keeps it for the next launch.
Future<bool> askStartOnModel(BuildContext context, {required String model}) =>
    showConfirmDialog(
      context,
      title: 'Start on $model?',
      message:
          'Nothing is running this session. It is recorded to start on '
          '$model; start it now?',
      confirmLabel: kStartNowLabel,
      cancelLabel: kKeepForNextLaunchLabel,
    );
