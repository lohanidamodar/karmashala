import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/quick_open/quick_open_list.dart'
    show QuickOpenKeyChip;
import '../../../app/widgets/adaptive_modal.dart';
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

/// R: Resume… a stopped or ended session.
class OverviewResumeIntent extends Intent {
  const OverviewResumeIntent();
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
  const SingleActivator(LogicalKeyboardKey.arrowDown): const OverviewMoveIntent(
    down: true,
  ),
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
  const SingleActivator(LogicalKeyboardKey.keyR): const OverviewResumeIntent(),
  const CharacterActivator('?'): const OverviewShowKeysIntent(),
};

/// What [intent] does, and the group the keys sheet files it under; null for
/// an intent this list has not been told about, which a test refuses.
({String group, String does})? describeOverviewIntent(Intent intent) =>
    switch (intent) {
      OverviewNextWaitingIntent() => (
        group: 'Move',
        does: 'Next item waiting on you — in the peek when it is open',
      ),
      OverviewMoveIntent(down: true) => (group: 'Move', does: 'Next session'),
      OverviewMoveIntent(down: false) => (
        group: 'Move',
        does: 'Previous session',
      ),
      OverviewDismissIntent() => (
        group: 'Move',
        does: 'Close the peek, or clear the selection',
      ),
      OverviewPickOptionIntent() => (
        group: 'Answer',
        does: 'Pick an option of the selected question',
      ),
      OverviewSendIntent() => (
        group: 'Answer',
        does: 'Send the picked answer, or open the selected session',
      ),
      OverviewApproveIntent(answer: BoardApproval.allow) => (
        group: 'Answer',
        does: 'Allow the selected command',
      ),
      OverviewApproveIntent(answer: BoardApproval.always) => (
        group: 'Answer',
        does: 'Always allow the selected command',
      ),
      OverviewApproveIntent(answer: BoardApproval.deny) => (
        group: 'Answer',
        does: 'Deny the selected command',
      ),
      OverviewTerminalIntent() => (
        group: 'Answer',
        does: 'Open the terminal of a terminal-only prompt',
      ),
      OverviewResumeIntent() => (
        group: 'Sessions',
        does: 'Resume a stopped or ended session',
      ),
      OverviewShowKeysIntent() => (group: 'Help', does: 'Show these keys'),
      _ => null,
    };

/// [activator] as a keycap reads: "↓", "Esc", "?", "Ctrl K". The nine
/// option keys and their keypad twins read as one "1–9".
String overviewKeyCap(ShortcutActivator activator, Intent intent) {
  if (intent is OverviewPickOptionIntent) return '1–9';
  return switch (activator) {
    CharacterActivator(:final character) => character,
    SingleActivator(
      :final trigger,
      :final control,
      :final shift,
      :final alt,
      :final meta,
    ) =>
      [
        if (control) 'Ctrl',
        if (meta) 'Meta',
        if (alt) 'Alt',
        if (shift) 'Shift',
        switch (trigger) {
          LogicalKeyboardKey.arrowDown => '↓',
          LogicalKeyboardKey.arrowUp => '↑',
          LogicalKeyboardKey.escape => 'Esc',
          LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'Enter',
          _ => trigger.keyLabel.toUpperCase(),
        },
      ].join(' '),
    _ => activator.debugDescribeKeys(),
  };
}

/// One line of the keys sheet: its keycaps and what they do.
typedef OverviewKeyRow = ({String group, List<String> keys, String does});

/// The groups, in the order the sheet draws them.
const List<String> kOverviewKeyGroups = [
  'Move',
  'Answer',
  'Sessions',
  'Help',
  'In a quick message',
  'With the mouse',
];

/// [bindings] — the board's own unless a test hands its own — as the sheet
/// and Settings › Keyboard list them: one row per thing done, its keys in
/// binding order, so the list cannot drift from what the keys do.
List<OverviewKeyRow> overviewBoundKeyRows([
  Map<ShortcutActivator, Intent>? bindings,
]) {
  final rows = <String, ({String group, Set<String> keys})>{};
  for (final MapEntry(key: activator, value: intent)
      in (bindings ?? overviewTriageShortcuts).entries) {
    final described =
        describeOverviewIntent(intent) ??
        (group: 'Help', does: '${intent.runtimeType}');
    rows
        .putIfAbsent(
          described.does,
          () => (group: described.group, keys: <String>{}),
        )
        .keys
        .add(overviewKeyCap(activator, intent));
  }
  return [
    for (final group in kOverviewKeyGroups)
      for (final MapEntry(key: does, value: row) in rows.entries)
        if (row.group == group)
          (group: group, keys: row.keys.toList(), does: does),
  ];
}

/// Keys the dashboard answers outside [overviewTriageShortcuts]: in a card's
/// quick message box, and with the mouse.
const List<OverviewKeyRow> kOverviewOtherKeys = [
  (group: 'In a quick message', keys: ['Enter'], does: 'Send it'),
  (group: 'In a quick message', keys: ['Shift Enter'], does: 'A new line'),
  (group: 'In a quick message', keys: ['Esc'], does: 'Clear it'),
  (
    group: 'With the mouse',
    keys: ['Ctrl click'],
    does: 'Pick a card for a batch answer, or put it back',
  ),
  (
    group: 'With the mouse',
    keys: ['Shift click'],
    does: 'Pick every card up to this one',
  ),
  (group: 'With the mouse', keys: ['Ctrl scroll'], does: 'Zoom the Timeline'),
  (group: 'With the mouse', keys: ['Shift scroll'], does: 'Pan the Timeline'),
];

/// Every key the sheet lists, grouped in [kOverviewKeyGroups] order.
List<OverviewKeyRow> overviewKeyRows() {
  final all = [...overviewBoundKeyRows(), ...kOverviewOtherKeys];
  return [
    for (final group in kOverviewKeyGroups)
      for (final row in all)
        if (row.group == group) row,
  ];
}

/// Said wherever the keys are listed.
const String kOverviewTriageNote =
    'On the Agent dashboard only, and never while you type in a field. After '
    'an answer the next waiting item is selected by itself.';

/// The keys sheet's title.
const String kOverviewKeysTitle = 'Agent dashboard keys';

/// The "?" sheet: every key the dashboard answers, as a sheet on a phone and
/// a dialog elsewhere.
Future<void> showOverviewKeys(BuildContext context) => showAdaptiveModal<void>(
  context: context,
  title: kOverviewKeysTitle,
  width: DialogWidth.regular,
  builder: (_) => const OverviewKeysSheet(),
);

/// The keys, a group at a time, each row its keycaps then what they do.
class OverviewKeysSheet extends StatelessWidget {
  const OverviewKeysSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final rows = overviewKeyRows();
    // Wide enough for "Shift scroll" at any text size, never most of a phone.
    final capsWidth = MediaQuery.textScalerOf(
      context,
    ).scale(Insets.xxl * 3).clamp(Insets.xxl * 3, Insets.xxl * 4.5);
    final children = <Widget>[];
    String? group;
    for (final row in rows) {
      if (row.group != group) {
        children.add(
          EyebrowLabel(
            row.group,
            padding: EdgeInsets.only(
              top: group == null ? 0 : Insets.md,
              bottom: Insets.xs,
            ),
          ),
        );
        group = row.group;
      }
      children.add(
        Padding(
          key: ValueKey('overview-key:${row.does}'),
          padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: capsWidth,
                child: Wrap(
                  spacing: Insets.xs,
                  runSpacing: Insets.xs,
                  children: [for (final key in row.keys) QuickOpenKeyChip(key)],
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(child: Text(row.does, style: theme.textTheme.bodySmall)),
            ],
          ),
        ),
      );
    }
    return Padding(
      key: const ValueKey('overview-keys'),
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          const SizedBox(height: Insets.md),
          Text(kOverviewTriageNote, style: muted),
        ],
      ),
    );
  }
}
