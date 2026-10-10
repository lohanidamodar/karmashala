import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// How the Stores tab draws its one list of apps.
enum StoresLayout {
  table('Table'),
  cards('Cards');

  const StoresLayout(this.label);
  final String label;
}

/// Where [StoresLayoutStore] keeps its file; a test points it at a folder of
/// its own.
final storesLayoutDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => appSupportDirectory,
);

/// **The Stores tab's layout on this device**, in a file of its own. Per
/// device: a phone's cards are not the desktop's table.
class StoresLayoutStore {
  StoresLayoutStore(this._directory);

  static final _log = AppLogger.named('stores.layout');

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'stores_tab.json'));

  /// What was kept, or null when nothing was or it cannot be read.
  Future<StoresLayout?> load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is! Map) return null;
      return StoresLayout.values
          .where((layout) => layout.name == json['layout'])
          .firstOrNull;
    } on Object {
      return null;
    }
  }

  Future<void> _writing = Future<void>.value();

  /// Keeps [layout]; settles once it, and every write before it, is on disk.
  Future<void> save(StoresLayout layout) => _writing = _writing.then((_) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'layout': layout.name}),
        flush: true,
      );
    } on Object catch (e) {
      _log.warning('Keeping the Stores layout failed: $e');
    }
  });
}

final storesLayoutStoreProvider = Provider<StoresLayoutStore>(
  (ref) => StoresLayoutStore(ref.watch(storesLayoutDirectoryProvider)),
);

/// The layout picked on this device; null until one is, when the width
/// decides.
class StoresLayoutChoice extends Notifier<StoresLayout?> {
  bool _touched = false;

  @override
  StoresLayout? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final kept = await ref.read(storesLayoutStoreProvider).load();
    // A pick made while the file was read wins over what it held.
    if (ref.mounted && !_touched && kept != null) state = kept;
  }

  void pick(StoresLayout layout) {
    _touched = true;
    if (state == layout) return;
    state = layout;
    unawaited(ref.read(storesLayoutStoreProvider).save(layout));
  }
}

final storesLayoutProvider =
    NotifierProvider<StoresLayoutChoice, StoresLayout?>(StoresLayoutChoice.new);
