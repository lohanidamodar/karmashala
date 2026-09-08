import 'dart:async';
import 'dart:io';

/// Where a screen recording's bytes go: a file in the app, a list in a test.
///
/// Small on purpose. The only thing a recorder needs of a destination is that
/// it takes bytes, says when a write to it failed, and reports how much it
/// ended up holding — and a test that had to stand in for `IOSink` would have
/// to implement `StringSink` as well, for no gain.
abstract interface class RecordingSink {
  /// Hands [bytes] over. Does not wait for them: a live view produces frames
  /// faster than a disk acknowledges them, and awaiting each one would put the
  /// disk in front of the picture.
  void add(List<int> bytes);

  /// Errors when a write failed, and never completes normally before [close].
  ///
  /// This is the out-of-disk path. [add] cannot report it — the write has not
  /// happened yet when it returns — so the failure arrives here instead, and
  /// arrives as an event rather than as something a caller has to go and ask
  /// about.
  Future<void> get done;

  /// Flushes, closes, and answers how many bytes the destination holds.
  ///
  /// The size is read back rather than counted on the way in, so a partial
  /// write is reported as what reached the disk rather than as what was
  /// offered to it.
  Future<int> close();
}

/// A [RecordingSink] writing to a file on this machine.
class FileRecordingSink implements RecordingSink {
  FileRecordingSink._(this._file, this._sink);

  /// Creates [path]'s directory if it is missing and opens the file.
  ///
  /// Throws whatever the filesystem throws — a read-only location, a name the
  /// platform refuses, a full disk — and the caller turns that into the
  /// "destination could not be opened" outcome, which is a different sentence
  /// from a write that failed part way through.
  static Future<RecordingSink> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return FileRecordingSink._(file, file.openWrite());
  }

  final File _file;
  final IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> get done => _sink.done;

  @override
  Future<int> close() async {
    await _sink.flush();
    await _sink.close();
    return _file.length();
  }
}
