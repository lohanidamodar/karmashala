import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/presentation/approval_request_card.dart'
    show BoardApproval;

/// N: the next item waiting on you.
class OverviewNextWaitingIntent extends Intent {
  const OverviewNextWaitingIntent();
}

/// 1–9: pick that option of the selected question.
class OverviewPickOptionIntent extends Intent {
  const OverviewPickOptionIntent(this.number);

  final int number;
}

/// Enter: send the picked answer, or open the selected session.
class OverviewSendIntent extends Intent {
  const OverviewSendIntent();
}

/// Y / A / D: allow, always allow or deny the selected command.
class OverviewApproveIntent extends Intent {
  const OverviewApproveIntent(this.answer);

  final BoardApproval answer;
}

/// T: the terminal of a terminal-only prompt.
class OverviewTerminalIntent extends Intent {
  const OverviewTerminalIntent();
}

/// ↑ ↓ / J K: the previous or next session.
class OverviewMoveIntent extends Intent {
  const OverviewMoveIntent({required this.down});

  final bool down;
}

/// Esc: close the peek, or clear the selection.
class OverviewDismissIntent extends Intent {
  const OverviewDismissIntent();
}

/// ?: show the keys.
class OverviewShowKeysIntent extends Intent {
  const OverviewShowKeysIntent();
}

/// The Overview board's keys. Bare letters, so they live on the board alone
/// and never in the app-wide keymap, where a shell or a field would want them.
final Map<ShortcutActivator, Intent> overviewTriageShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyN):
      const OverviewNextWaitingIntent(),
  for (var n = 1; n <= 9; n++) ...{
    SingleActivator(
      LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + n - 1),
    ): OverviewPickOptionIntent(
      n,
    ),
    SingleActivator(
      LogicalKeyboardKey(LogicalKeyboardKey.numpad1.keyId + n - 1),
    ): OverviewPickOptionIntent(
      n,
    ),
  },
  const SingleActivator(LogicalKeyboardKey.enter): const OverviewSendIntent(),
  const SingleActivator(LogicalKeyboardKey.numpadEnter):
      const OverviewSendIntent(),
  const SingleActivator(LogicalKeyboardKey.keyY): const OverviewApproveIntent(
    BoardApproval.allow,
  ),
  const SingleActivator(LogicalKeyboardKey.keyA): const OverviewApproveIntent(
    BoardApproval.always,
  ),
  const SingleActivator(LogicalKeyboardKey.keyD): const OverviewApproveIntent(
    BoardApproval.deny,
  ),
  const SingleActivator(LogicalKeyboardKey.keyT):
      const OverviewTerminalIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowDown):
      const OverviewMoveIntent(down: true),
  const SingleActivator(LogicalKeyboardKey.keyJ): const OverviewMoveIntent(
    down: true,
  ),
  const SingleActivator(LogicalKeyboardKey.arrowUp): const OverviewMoveIntent(
    down: false,
  ),
  const SingleActivator(LogicalKeyboardKey.keyK): const OverviewMoveIntent(
    down: false,
  ),
  const SingleActivator(LogicalKeyboardKey.escape):
      const OverviewDismissIntent(),
  const CharacterActivator('?'): const OverviewShowKeysIntent(),
};

/// The board's keys as the "?" sheet and Settings › Keyboard list them.
const List<(String keys, String does)> kOverviewTriageKeys = [
  ('N', 'Next item waiting on you — in the peek when it is open'),
  ('1–9', 'Pick an option of the selected question'),
  ('Enter', 'Send the picked answer, or open the selected session'),
  ('Y  A  D', 'Allow, always allow or deny the selected command'),
  ('T', 'Open the terminal of a terminal-only prompt'),
  ('↑ ↓  J K', 'Move between sessions'),
  ('Esc', 'Close the peek, or clear the selection'),
  ('?', 'Show these keys'),
];

/// Said wherever the keys are listed.
const String kOverviewTriageNote =
    'On the Overview board only, and never while you type in a field. After '
    'an answer the next waiting item is selected by itself.';

/// The "?" sheet: the board's keys.
Future<void> showOverviewKeys(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialog) {
    final theme = Theme.of(dialog);
    final muted = UiDensity.of(dialog).muted(theme);
    return AlertDialog(
      key: const ValueKey('overview-keys'),
      title: const DesktopDialogTitle(
        icon: AppIcons.keyboard,
        title: 'Overview keys',
      ),
      content: SizedBox(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (keys, does) in kOverviewTriageKeys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: Insets.xxl * 2.5,
                      child: Text(keys, style: MonoStyles.small),
                    ),
                    Expanded(
                      child: Text(does, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Insets.sm),
            Text(kOverviewTriageNote, style: muted),
          ],
        ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  },
);
