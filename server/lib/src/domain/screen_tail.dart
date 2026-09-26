import 'package:xterm2/core.dart';

/// The last [lines] rows [terminal] holds, scrollback included, as plain
/// text: what a finished check leaves beside its verdict, and the rows an
/// agent's status and menus are read from on every tick. Read from the bottom
/// up, so the cost is the rows returned, not the 2000 of scrollback above.
List<String> screenTailOf(Terminal terminal, {required int lines}) {
  final all = terminal.buffer.lines;
  var row = all.length - 1;
  while (row >= 0 && all[row].getText().trimRight().isEmpty) {
    row--;
  }
  final tail = <String>[];
  for (; row >= 0 && tail.length < lines; row--) {
    tail.add(all[row].getText().trimRight());
  }
  return tail.reversed.toList();
}
