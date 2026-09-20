import 'package:flutter/widgets.dart';

/// Marks a subtree deliberately holding the physical keyboard. "Is it a text
/// field" was too narrow — a device mirror is not an [EditableText].
class KeyboardCaptureScope extends StatelessWidget {
  const KeyboardCaptureScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Whether the keyboard is somewhere it would be wrong to take it from — a
/// text field or a [KeyboardCaptureScope], not merely "focus exists".
bool keyboardIsSpokenFor() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null ||
      context.findAncestorWidgetOfExactType<KeyboardCaptureScope>() != null;
}
