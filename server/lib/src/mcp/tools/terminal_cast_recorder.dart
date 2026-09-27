import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/host_session.dart';

/// One terminal being recorded by the server (slice 5b): the session's own
/// output bytes from the moment it began, with their timing, written as an
/// asciicast v2 file when it stops — the recording, of which any video is a
/// rendering. Nothing is redacted: escapes interleave mid-word, so no pattern
/// could find a secret.
class TerminalCastRecorder {
  TerminalCastRecorder._(this.session, this.title, this._now)
    : startedAt = _now(),
      columns = session.columns,
      rows = session.rows {
    final decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_EventSink(this));
    _input = decoder;
    _subscription = session
        .readFrom(session.backlog.totalBytes)
        .listen(
          (chunk) => decoder.add(chunk.bytes),
          onDone: () => sourceEnded = true,
          onError: (Object _) => sourceEnded = true,
        );
  }

  /// Starts recording [session] from its next byte.
  static TerminalCastRecorder start(
    HostSession session, {
    required String title,
    DateTime Function()? clock,
  }) => TerminalCastRecorder._(session, title, clock ?? DateTime.now);

  final HostSession session;
  final String title;
  final DateTime Function() _now;
  final DateTime startedAt;
  final int columns;
  final int rows;

  /// Whether the session ended while it was being recorded.
  bool sourceEnded = false;

  final _events = <(double, String)>[];
  late final ByteConversionSink _input;
  StreamSubscription<Object?>? _subscription;
  DateTime? _stoppedAt;

  void _add(String text) {
    if (text.isEmpty || _stoppedAt != null) return;
    final at = _now().difference(startedAt).inMicroseconds / 1e6;
    _events.add((at, text));
  }

  /// How long it ran.
  Duration get duration => (_stoppedAt ?? _now()).difference(startedAt);

  /// Stops taking bytes and writes the cast into [directory]; answers the
  /// file.
  Future<File> stop(String directory) async {
    await _subscription?.cancel();
    _subscription = null;
    if (_stoppedAt == null) {
      try {
        _input.close();
      } on Object {
        // A half character at the very end is not worth failing the file.
      }
    }
    _stoppedAt ??= _now();
    await Directory(directory).create(recursive: true);
    final file = File(p.join(directory, castFileName(title, startedAt)));
    final out = StringBuffer()
      ..writeln(
        jsonEncode({
          'version': 2,
          'width': columns,
          'height': rows,
          'timestamp': startedAt.millisecondsSinceEpoch ~/ 1000,
          'title': title,
        }),
      );
    for (final (at, text) in _events) {
      out.writeln(jsonEncode([at, 'o', text]));
    }
    await file.writeAsString(out.toString(), flush: true);
    return file;
  }

  /// Stops without writing anything.
  Future<void> abandon() async {
    await _subscription?.cancel();
    _subscription = null;
    _stoppedAt ??= _now();
    try {
      _input.close();
    } on Object {
      // Nothing left to decode.
    }
  }
}

class _EventSink implements Sink<String> {
  _EventSink(this._recorder);
  final TerminalCastRecorder _recorder;

  @override
  void add(String data) => _recorder._add(data);

  @override
  void close() {}
}

/// `pwsh-20260908-143005.cast`, from the terminal's title and when it began.
/// The title is squeezed to what a file name can hold everywhere, because a
/// shell's OSC 0 can call a pane anything.
String castFileName(String? title, DateTime recordedAt) {
  final at = recordedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  final safe = (title ?? 'terminal')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final stem = safe.isEmpty ? 'terminal' : safe;
  return '${stem.length > 40 ? stem.substring(0, 40) : stem}-$stamp.cast';
}
