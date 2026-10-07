import 'package:flutter/widgets.dart';
import 'package:karmashala_ui/dialogs.dart';

import 'typed_command.dart';

/// The most sessions a confirm lists by name before it counts the rest.
const int kTypedCommandConfirmNames = 12;

/// Asks before a command acts on several sessions, naming each one.
Future<bool> confirmTypedCommand(BuildContext context, CommandConfirm confirm) {
  final shown = confirm.names.take(kTypedCommandConfirmNames);
  final more = confirm.names.length - shown.length;
  return showConfirmDialog(
    context,
    title: confirm.title,
    message: [
      for (final name in shown) '• $name',
      if (more > 0) 'and $more more',
    ].join('\n'),
    confirmLabel: confirm.confirmLabel,
  );
}
