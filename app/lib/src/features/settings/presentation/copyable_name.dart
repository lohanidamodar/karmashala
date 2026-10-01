import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Puts [text] on the clipboard and says so, in the words the rest of Settings
/// uses. Only ever a name or an id: never hand it a secret's value.
Future<void> copyNameToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text('Copied “$text”')));
}

/// The small copy button beside a name somebody will paste elsewhere: a row
/// menu button's slot, so it does not make a row taller, and a thumb's on touch.
class CopyNameButton extends StatelessWidget {
  const CopyNameButton({
    required this.text,
    this.tooltip = 'Copy name',
    super.key,
  });

  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.of(context).isTouch;
    final slot = touch ? Touch.target : Chrome.icon + Insets.sm;
    return SizedBox(
      width: slot,
      height: slot,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: touch ? Touch.icon : Chrome.iconSmall,
        icon: const Icon(AppIcons.copySimple),
        onPressed: () => copyNameToClipboard(context, text),
      ),
    );
  }
}

/// A name, an id or a variable, as selectable text with [CopyNameButton]
/// after it: what a person copies to paste into a file, a prompt or a shell.
class CopyableName extends StatelessWidget {
  const CopyableName({
    required this.text,
    this.style,
    this.tooltip = 'Copy name',
    super.key,
  });

  final String text;
  final TextStyle? style;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: SelectableText(text, style: style)),
      const SizedBox(width: Insets.xs),
      CopyNameButton(text: text, tooltip: tooltip),
    ],
  );
}
