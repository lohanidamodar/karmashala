/// The folders pinned to every file browser's quick-access column.
///
/// The server keeps them, so a folder pinned in the desktop's picker is in the
/// phone's Files page too. `karmashala_ui` knows no server, so the app hands
/// the list in through [QuickAccess.lookup], the way [BrowseSources.lookup]
/// hands in the machines.
library;

import 'package:flutter/foundation.dart';

/// One pinned folder: [path] spelled for [environmentId]'s own machine, as
/// every stored path is, so a WSL or SSH-box folder stays one.
@immutable
class PinnedFolder {
  const PinnedFolder({
    required this.environmentId,
    required this.path,
    this.label,
  });

  final String environmentId;
  final String path;

  /// What the person named it; null shows the folder's own name.
  final String? label;

  /// What the column shows.
  String get name {
    final named = label?.trim();
    if (named != null && named.isNotEmpty) return named;
    final cleaned = path.length > 3
        ? path.replaceAll(RegExp(r'[\\/]+$'), '')
        : path;
    final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
    final leaf = cut == -1 ? cleaned : cleaned.substring(cut + 1);
    return leaf.isEmpty ? cleaned : leaf;
  }

  /// Whether this pin is the folder at [path] in [environmentId]: a Windows
  /// spelling folds case and separators, and a trailing separator never
  /// counts.
  bool names(String environmentId, String path) =>
      environmentId == this.environmentId &&
      pinnedFolderKey(path) == pinnedFolderKey(this.path);

  @override
  bool operator ==(Object other) =>
      other is PinnedFolder &&
      other.environmentId == environmentId &&
      other.path == path &&
      other.label == label;

  @override
  int get hashCode => Object.hash(environmentId, path, label);
}

/// [path] as two spellings of one folder agree on.
String pinnedFolderKey(String path) {
  final windows = RegExp(r'^[A-Za-z]:|\\').hasMatch(path);
  var key = windows ? path.replaceAll(r'\', '/').toLowerCase() : path;
  while (key.length > 1 && key.endsWith('/') && !key.endsWith(':/')) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}

/// The pins as a browser reads and changes them. Notifies when the list
/// changes — here or on any other client of the server.
abstract interface class QuickAccessPins implements Listenable {
  /// Every pin, in the order the column shows them.
  List<PinnedFolder> get pins;

  /// Why pins cannot be changed from here — an older server — or null.
  String? get unavailable;

  /// Each throws with a sentence a person can be shown.
  Future<void> pin(PinnedFolder folder);

  Future<void> unpin(PinnedFolder folder);

  /// A null or blank [label] gives the folder its own name back.
  Future<void> rename(PinnedFolder folder, String? label);
}

/// Where a browser finds the pins. Until the app sets [lookup] there are none,
/// which is what a test and a browser of this device's own disk want.
class QuickAccess {
  const QuickAccess._();

  static QuickAccessPins? Function()? lookup;

  static QuickAccessPins? get current {
    try {
      return lookup?.call();
    } on Object {
      // No server session: a browser without pins, never no browser.
      return null;
    }
  }
}
