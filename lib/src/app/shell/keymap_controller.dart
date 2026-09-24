import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../core/paths/app_support_directory.dart';
import 'keymap.dart';
import 'shell_shortcuts.dart';

/// The user's keymap file, `keymap.json` in the app's data folder. Null under
/// `flutter test`: a test must not read the owner's keys; one that wants a
/// file overrides this.
final keymapFileProvider = FutureProvider<File?>((ref) async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
  final directory = await appSupportDirectory();
  return File(p.join(directory.path, 'keymap.json'));
});

/// Where the keymap stands: which file, and what was wrong with it the last
/// time it was read. [revision] moves each time a reading is applied.
@immutable
class KeymapStatus {
  const KeymapStatus({
    this.path,
    this.problems = const [],
    this.entries = 0,
    this.revision = 0,
  });

  final String? path;

  /// Why the file as it stands is not in use; the last good map still is.
  final List<String> problems;

  /// How many entries of the file are in force.
  final int entries;
  final int revision;
}

/// Reads the keymap file when the app starts and again whenever it changes.
/// A reading with any problem is not applied: the last good map stays, and
/// [KeymapStatus.problems] says what to fix.
class KeymapController extends Notifier<KeymapStatus> {
  static final _log = AppLogger.named('shell.keymap');

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _settle;
  File? _file;

  @override
  KeymapStatus build() {
    ref.onDispose(() {
      _settle?.cancel();
      unawaited(_watch?.cancel());
    });
    unawaited(_start());
    return const KeymapStatus();
  }

  Future<void> _start() async {
    final File? found;
    try {
      found = await ref.read(keymapFileProvider.future);
    } on Object catch (e) {
      _log.warning('no keymap file could be found: $e');
      return;
    }
    if (found == null || !ref.mounted) return;
    final file = found;
    _file = file;
    state = KeymapStatus(path: file.path);
    await reload();
    try {
      // The folder, not the file: an editor saving by rename replaces the
      // file, and a watch on the old one would hear nothing more.
      _watch = file.parent
          .watch()
          .where((e) => p.basename(e.path) == p.basename(file.path))
          .listen((_) {
            _settle?.cancel();
            _settle = Timer(const Duration(milliseconds: 150), reload);
          });
    } on FileSystemException catch (e) {
      _log.warning('the keymap file cannot be watched: $e');
    }
  }

  /// Reads the file again and applies it when it is usable. A missing file is
  /// an empty keymap: the app's own keys.
  Future<void> reload() async {
    final file = _file;
    if (file == null) return;
    String text;
    try {
      text = await file.exists() ? await file.readAsString() : '';
    } on FileSystemException catch (e) {
      if (!ref.mounted) return;
      state = _with(problems: ['The file could not be read: ${e.message}']);
      return;
    }
    if (!ref.mounted) return;
    apply(text);
  }

  /// Applies the keymap [text] says, or keeps the one in force and says why
  /// not. Public so a test can hand it text without a file.
  void apply(String text) {
    final defaults = defaultShellChords;
    final reading = parseKeymap(text, commands: keymapCommands(defaults));
    if (!reading.isUsable) {
      _log.warning('keymap not applied: ${reading.problems.join(' ')}');
      state = _with(problems: reading.problems);
      return;
    }
    final resolved = resolveKeymap(defaults, reading.entries);
    applyKeymapEntries(reading.entries);
    state = KeymapStatus(
      path: state.path,
      problems: resolved.problems,
      entries: reading.entries.length,
      revision: state.revision + 1,
    );
  }

  /// The file, created with an example when there is none yet, so there is
  /// something to open and edit. Null when there is no file to have.
  Future<File?> ensureFile() async {
    final file = _file;
    if (file == null) return null;
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await file.writeAsString(kKeymapTemplate);
    }
    return file;
  }

  KeymapStatus _with({required List<String> problems}) => KeymapStatus(
    path: state.path,
    problems: problems,
    entries: state.entries,
    revision: state.revision,
  );
}

final keymapProvider = NotifierProvider<KeymapController, KeymapStatus>(
  KeymapController.new,
);
