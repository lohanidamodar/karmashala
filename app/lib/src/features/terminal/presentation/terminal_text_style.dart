import 'package:karmashala_ui/tokens.dart';
import 'package:xterm2/xterm.dart';

/// The grid's face, for the view and for anything measuring its cells. xterm's
/// fallbacks are desktop fonts; the bundled symbol faces close the list, so a
/// phone still draws an agent's footer marks.
TerminalStyle terminalTextStyle(double fontSize) => TerminalStyle(
  fontSize: fontSize,
  fontFamily: kMonoFamily,
  fontFamilyFallback: _fallback,
);

final List<String> _fallback = [
  ...const TerminalStyle().fontFamilyFallback,
  ...kBundledSymbolFamilies,
];
