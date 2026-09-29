import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../core/paths/app_support_directory.dart';
import '../../features/editor/application/open_documents.dart'
    show documentSavesProvider;
import '../../features/notifications/application/notification_providers.dart'
    show windowFocusedProvider;
import 'keymap.dart';
import 'shell_shortcuts.dart';

/// The user's keymap file, `keymap.json` in the app's data folder — which
/// `KARMASHALA_DATA_DIR` moves, so a probe reads its own. Null under
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

/// Reads the keymap file when the app starts, when the window gets focus back
/// (an edit made in another editor) and when the app's own editor saves it —
/// read again rather than watched. A reading with any problem is not applied:
/// the last good map stays, and [KeymapStatus.problems] says what to fix.
class KeymapController extends Notifier<KeymapStatus> {
  static final _log = AppLogger.named('shell.keymap');

  File? _file;

  /// The text last applied or refused, so a focus that finds the file as it
  /// was costs nothing and says nothing again.
  String? _lastText;

  @override
  KeymapStatus build() {
    ref.listen(windowFocusedProvider, (was, now) {
      if (now && was == false) unawaited(reload());
    });
    ref.listen(documentSavesProvider, (_, saved) {
      final file = _file;
      final path = saved.hostPath;
      if (file == null || path == null) return;
      if (p.equals(p.normalize(path), p.normalize(file.path))) {
        unawaited(reload(force: true));
      }
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
    _file = found;
    state = KeymapStatus(path: found.path);
    await reload();
  }

  /// Reads the file again and applies it when it is usable. A missing file is
  /// an empty keymap: the app's own keys. Unchanged text is skipped unless
  /// [force].
  Future<void> reload({bool force = false}) async {
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
    if (!force && text == _lastText) return;
    apply(text);
  }

  /// Applies the keymap [text] says, or keeps the one in force and says why
  /// not. Public so a test can hand it text without a file.
  void apply(String text) {
    _lastText = text;
    final defaults = defaultShellChords;
    final reading = parseKeymap(text, commands: keymapCommands(defaults));
    final problems = reading.isUsable
        ? resolveKeymap(defaults, reading.entries).problems
        : reading.problems;
    if (problems.isNotEmpty) {
      _log.warning('keymap not applied: ${problems.join(' ')}');
      state = _with(problems: problems);
      return;
    }
    applyKeymapEntries(reading.entries);
    state = KeymapStatus(
      path: state.path,
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
