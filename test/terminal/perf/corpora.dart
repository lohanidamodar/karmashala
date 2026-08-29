import 'package:xterm/xterm.dart';

/// The viewport the budgets in the spec are stated against: a maximised
/// terminal on a 1440p display.
const kPerfColumns = 200;
const kPerfRows = 50;

/// The four workloads the terminal painter is measured against.
enum PerfCorpus {
  /// (a) A plain build log: no SGR at all. The common case.
  plainLog,

  /// (b) Colourised `ls -R`-style output: many short SGR runs per line.
  colorizedLs,

  /// (c) A full-screen TUI frame: box drawing, reverse video and filled status
  /// bars — a full-viewport repaint.
  tuiFrame,

  /// (d) Adversarial: every cell a unique 24-bit colour, so run batching cannot
  /// merge anything. Proves the worst case does not regress.
  adversarial,
}

/// The VT byte stream for [corpus], sized to fill [columns] x [rows].
String corpusText(
  PerfCorpus corpus, {
  int columns = kPerfColumns,
  int rows = kPerfRows,
}) {
  switch (corpus) {
    case PerfCorpus.plainLog:
      return _plainLog(columns, rows);
    case PerfCorpus.colorizedLs:
      return _colorizedLs(columns, rows);
    case PerfCorpus.tuiFrame:
      return _tuiFrame(columns, rows);
    case PerfCorpus.adversarial:
      return _adversarial(columns, rows);
  }
}

/// A [Terminal] of [columns] x [rows] with [corpus] already written into it.
Terminal buildTerminal(
  PerfCorpus corpus, {
  int columns = kPerfColumns,
  int rows = kPerfRows,
}) {
  final terminal = Terminal(maxLines: rows);
  terminal.resize(columns, rows);
  terminal.write(corpusText(corpus, columns: columns, rows: rows));
  return terminal;
}

String _plainLog(int columns, int rows) {
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    final line =
        '[${(row * 137) % 100000}] compiling package:chitragupta/src/features/'
        'terminal/data/terminal_instance.dart unit $row';
    buffer.write(_fit(line, columns));
    if (row < rows - 1) buffer.write('\r\n');
  }
  return buffer.toString();
}

String _colorizedLs(int columns, int rows) {
  const sgr = <String>[
    '\x1b[0m',
    '\x1b[1;34m',
    '\x1b[32m',
    '\x1b[1;36m',
    '\x1b[33m',
    '\x1b[35m',
    '\x1b[1;31m',
  ];
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    var width = 0;
    var i = 0;
    while (width < columns) {
      final name = 'entry_${row}_$i';
      buffer.write(sgr[(row + i) % sgr.length]);
      final take = width + name.length > columns
          ? columns - width
          : name.length;
      buffer.write(name.substring(0, take));
      width += take;
      if (width < columns) {
        buffer.write('\x1b[0m ');
        width += 1;
      }
      i++;
    }
    buffer.write('\x1b[0m');
    if (row < rows - 1) buffer.write('\r\n');
  }
  return buffer.toString();
}

String _tuiFrame(int columns, int rows) {
  final buffer = StringBuffer();
  // Reverse-video title bar.
  buffer
    ..write('\x1b[7m')
    ..write(_fit('  chitragupta \u2014 htop-like status', columns))
    ..write('\x1b[0m\r\n');
  // Boxed body with coloured gauges.
  for (var row = 1; row < rows - 1; row++) {
    final filled = ((row * 7) % (columns - 4)) + 1;
    buffer
      ..write('\x1b[36m\u2502\x1b[0m')
      ..write('\x1b[42m')
      ..write(' ' * filled)
      ..write('\x1b[0m')
      ..write('\x1b[100m')
      ..write(' ' * (columns - 4 - filled))
      ..write('\x1b[0m')
      ..write('\x1b[36m\u2502\x1b[0m')
      ..write('\r\n');
  }
  buffer
    ..write('\x1b[7m')
    ..write(_fit(' F1 Help  F2 Setup  F10 Quit', columns))
    ..write('\x1b[0m');
  return buffer.toString();
}

String _adversarial(int columns, int rows) {
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < columns; col++) {
      final n = row * columns + col;
      final r = (n * 7) & 0xFF;
      final g = (n * 13) & 0xFF;
      final b = (n * 29) & 0xFF;
      buffer
        ..write('\x1b[38;2;$r;$g;${b}m')
        ..writeCharCode(0x41 + (n % 26));
    }
    buffer.write('\x1b[0m');
    if (row < rows - 1) buffer.write('\r\n');
  }
  return buffer.toString();
}

String _fit(String text, int columns) => text.length >= columns
    ? text.substring(0, columns)
    : text + ' ' * (columns - text.length);
