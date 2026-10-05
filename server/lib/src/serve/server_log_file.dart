import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// `<data>/logs/server.log`, rotated by size: `serve` usually runs detached,
/// with nobody reading its stdout or stderr, so this is the log there is.
///
/// Lines added before [open] wait for it (the data folder is not known
/// until the arguments are read); with no [open] they are dropped.
class ServerLogFile {
  ServerLogFile([
    String? dataDirectory,
    this.maxBytes = 2 * 1024 * 1024,
    this.keep = 3,
  ]) {
    if (dataDirectory != null) open(dataDirectory);
  }

  final int maxBytes;
  final int keep;
  LogFileSink? _sink;
  final _early = <LogEntry>[];
  final _redactor = LogRedactor();
  var _sequence = 0;

  /// The live file, once [open].
  File get file => _sink!.file;

  void open(String dataDirectory) {
    final sink = _sink = LogFileSink(
      directory: Directory(p.join(dataDirectory, 'logs')),
      fileName: 'server.log',
      maxBytes: maxBytes,
      keep: keep,
    );
    _early
      ..forEach(sink.add)
      ..clear();
  }

  void add(String channel, String line) {
    final entry = LogEntry(
      sequence: _sequence++,
      time: DateTime.now(),
      level: Level.INFO,
      channel: channel,
      message: _redactor.apply(line),
    );
    final sink = _sink;
    if (sink != null) {
      sink.add(entry);
    } else if (_early.length < 200) {
      _early.add(entry);
    }
  }

  Future<void> flush() async => _sink?.flush();

  Future<void> close() async => _sink?.close();
}

/// [inner], with every whole line written to it also added to [log].
class FiledSink implements IOSink {
  FiledSink(this.inner, this.log, {required this.channel});

  final IOSink inner;
  final ServerLogFile log;
  final String channel;
  final _partial = StringBuffer();

  void _file(String text) {
    var rest = text;
    for (var end = rest.indexOf('\n'); end >= 0; end = rest.indexOf('\n')) {
      _partial.write(rest.substring(0, end));
      log.add(channel, _partial.toString().trimRight());
      _partial.clear();
      rest = rest.substring(end + 1);
    }
    _partial.write(rest);
  }

  void _pass(void Function() write) {
    try {
      write();
    } on Object {
      // The file has the line; a reader that went away costs nothing more.
    }
  }

  @override
  Encoding get encoding => inner.encoding;

  @override
  set encoding(Encoding value) => inner.encoding = value;

  @override
  void write(Object? object) {
    _file('$object');
    _pass(() => inner.write(object));
  }

  @override
  void writeln([Object? object = '']) {
    _file('$object\n');
    _pass(() => inner.writeln(object));
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _file(objects.join(separator));
    _pass(() => inner.writeAll(objects, separator));
  }

  @override
  void writeCharCode(int charCode) {
    _file(String.fromCharCode(charCode));
    _pass(() => inner.writeCharCode(charCode));
  }

  @override
  void add(List<int> data) {
    _file(utf8.decode(data, allowMalformed: true));
    _pass(() => inner.add(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();

  @override
  Future<void> get done => inner.done;
}
