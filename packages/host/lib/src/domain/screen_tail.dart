import 'package:xterm2/core.dart';

/// The last [lines] rows [terminal] holds, scrollback included, as plain
/// text: what a finished check leaves beside its verdict.
List<String> screenTailOf(Terminal terminal, {required int lines}) {
  final buffer = terminal.buffer;
  final all = <String>[
    for (var row = 0; row < buffer.lines.length; row++)
      buffer.lines[row].getText().trimRight(),
  ];
  while (all.isNotEmpty && all.last.isEmpty) {
    all.removeLast();
  }
  return all.length <= lines ? all : all.sublist(all.length - lines);
}
