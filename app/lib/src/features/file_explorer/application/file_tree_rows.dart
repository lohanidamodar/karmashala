import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/file_listing_service.dart';
import 'file_explorer_providers.dart';

/// Folders open in the Files panel, by [fileTreeKey]. Held here rather than in
/// a row, because a lazy list disposes the rows scrolled out of view.
class FileTreeExpansion extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // A reveal opens every folder on the way down, including one that arrived
    // before the panel was built. Folders opened this way stay open.
    ref.listen(fileRevealTargetProvider, (_, target) {
      if (target != null) _openTowards(target);
    });
    final target = ref.read(fileRevealTargetProvider);
    return target == null ? const {} : _towards(target);
  }

  bool isOpen(String path) => state.contains(fileTreeKey(path));

  void toggle(String path) {
    final key = fileTreeKey(path);
    state = state.contains(key) ? ({...state}..remove(key)) : {...state, key};
  }

  void _openTowards(FileRevealTarget target) {
    final wanted = _towards(target);
    if (state.containsAll(wanted)) return;
    state = {...state, ...wanted};
  }

  /// Every ancestor of [target], and the target itself when it is a folder.
  static Set<String> _towards(FileRevealTarget target) {
    final key = fileTreeKey(target.hostPath);
    final keys = <String>{};
    for (var i = key.indexOf('/'); i >= 0; i = key.indexOf('/', i + 1)) {
      if (i > 0) keys.add(key.substring(0, i));
    }
    if (target.isDirectory) keys.add(key);
    return keys;
  }
}

final fileTreeExpansionProvider =
    NotifierProvider<FileTreeExpansion, Set<String>>(FileTreeExpansion.new);

/// One line of the flattened Files tree.
@immutable
sealed class FileTreeItem {
  const FileTreeItem(this.depth);

  final int depth;
}

final class FileTreeEntryItem extends FileTreeItem {
  const FileTreeEntryItem(this.entry, super.depth);

  final DirEntry entry;

  @override
  bool operator ==(Object other) =>
      other is FileTreeEntryItem &&
      other.depth == depth &&
      other.entry.windowsPath == entry.windowsPath &&
      other.entry.name == entry.name &&
      other.entry.isDirectory == entry.isDirectory;

  @override
  int get hashCode => Object.hash(depth, entry.windowsPath, entry.isDirectory);
}

enum FileTreeNotice { loading, unreadable, empty }

/// What stands in for a folder's children while they cannot be listed.
final class FileTreeNoticeItem extends FileTreeItem {
  const FileTreeNoticeItem(this.folder, this.notice, super.depth);

  final String folder;
  final FileTreeNotice notice;

  @override
  bool operator ==(Object other) =>
      other is FileTreeNoticeItem &&
      other.depth == depth &&
      other.folder == folder &&
      other.notice == notice;

  @override
  int get hashCode => Object.hash(depth, folder, notice);
}

/// The rows a lazy list draws, compared by value so an unchanged re-listing
/// rebuilds nothing.
@immutable
class FileTreeRows {
  const FileTreeRows(this.items);

  final List<FileTreeItem> items;

  @override
  bool operator ==(Object other) =>
      other is FileTreeRows && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// The tree under [root], flattened: only folders that are open are listed.
final fileTreeRowsProvider = Provider.autoDispose.family<FileTreeRows, String>((
  ref,
  root,
) {
  final open = ref.watch(fileTreeExpansionProvider);
  final items = <FileTreeItem>[];
  void walk(String dir, int depth) {
    final listing = ref.watch(directoryListingProvider(dir));
    // A refresh keeps drawing the listing it had, the way `AsyncValue.when`
    // does; an error is said even over an older listing.
    if (listing is AsyncError) {
      items.add(FileTreeNoticeItem(dir, FileTreeNotice.unreadable, depth));
      return;
    }
    if (!listing.hasValue) {
      items.add(FileTreeNoticeItem(dir, FileTreeNotice.loading, depth));
      return;
    }
    final entries = listing.requireValue;
    if (entries.isEmpty) {
      items.add(FileTreeNoticeItem(dir, FileTreeNotice.empty, depth));
      return;
    }
    for (final entry in entries) {
      items.add(FileTreeEntryItem(entry, depth));
      if (entry.isDirectory && open.contains(fileTreeKey(entry.windowsPath))) {
        walk(entry.windowsPath, depth + 1);
      }
    }
  }

  walk(root, 0);
  return FileTreeRows(items);
});
