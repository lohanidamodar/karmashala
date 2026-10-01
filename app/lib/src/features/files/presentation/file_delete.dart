import 'dart:async';

import '../../environments/application/environment_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_files/values.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../editor/application/open_documents.dart';
import '../../editor/domain/document_id.dart';
import '../application/file_deletion.dart';

/// What a delete did: the entries that went, and a sentence for each that
/// did not.
typedef FileDeleteOutcome = ({List<FileEntry> deleted, List<String> failures});

/// **The one delete every file browser uses** — the Files tab's row menu and
/// the Split browser's toolbar: asks first, naming the item (and what a
/// folder holds), then has the server do it where the file is.
///
/// To the recycle bin where the machine has one ([FileDeletion.canTrash]: a
/// drive path on Windows); otherwise — a WSL distribution, an SSH host — a
/// permanent delete, and the question says "permanently" before anyone
/// agrees. With [within], anything that is [within] itself or outside it is
/// refused before a question is asked; the server refuses a project or
/// checkout root, and a folder holding one, whoever asks.
///
/// An editor open on a file that went is told at once, so it shows "Deleted
/// on disk" with its text kept. The caller lists the folder again.
Future<FileDeleteOutcome> confirmAndDeleteFiles(
  BuildContext context,
  List<FileEntry> entries, {
  EnvironmentPath? within,
}) async {
  const nothing = (deleted: <FileEntry>[], failures: <String>[]);
  if (entries.isEmpty) return nothing;
  if (within != null) {
    for (final entry in entries) {
      if (_same(within, entry.path) || !_isUnder(within, entry.path)) {
        return (
          deleted: const <FileEntry>[],
          failures: [
            '"${entry.name}" is not inside ${within.path}; it is not '
                'deleted from here.',
          ],
        );
      }
    }
  }
  // The container, not the row's ref: the row can be gone (its folder
  // re-listed) before the answer comes back.
  final container = ProviderScope.containerOf(context, listen: false);
  final files = container.read(fileDeletionProvider);
  final toBin = entries.every((entry) => files.canTrash(entry.path));
  final one = entries.length == 1 ? entries.single : null;

  String? inside;
  if (one != null && one.isDirectory) {
    final count = await files.countIn(one.path);
    inside = count == null
        ? 'Anything inside goes with it.'
        : count == 0
        ? 'The folder is empty.'
        : 'The ${count == 1 ? 'item' : '$count items'} inside '
              '${count == 1 ? 'goes' : 'go'} with it.';
  } else if (entries.any((entry) => entry.isDirectory)) {
    inside = 'Anything inside the folders goes with them.';
  }
  if (!context.mounted) return nothing;

  final what = one != null ? '"${one.name}"' : '${entries.length} items';
  final confirmed = await showConfirmDialog(
    context,
    destructive: true,
    title: toBin
        ? 'Move $what to the Recycle Bin?'
        : 'Permanently delete $what?',
    message: [
      ?inside,
      toBin
          ? 'It can be restored from the Recycle Bin.'
          : 'This cannot be undone: files in WSL or on an SSH host have no '
                'recycle bin here, so they are deleted permanently.',
    ].join(' '),
    confirmLabel: toBin ? 'Move to Recycle Bin' : 'Delete permanently',
  );
  if (!confirmed) return nothing;

  final deleted = <FileEntry>[];
  final failures = <String>[];
  for (final entry in entries) {
    final failed = await files.remove(entry, toBin: toBin);
    if (failed == null) {
      deleted.add(entry);
    } else {
      failures.add('Could not delete "${entry.name}": $failed');
    }
  }
  if (deleted.isNotEmpty) {
    _tellEditors(container, [for (final entry in deleted) entry.path]);
  }
  return (deleted: deleted, failures: failures);
}

/// Every open buffer on a file that went looks at the disk now — the one
/// check an editor already runs, which marks it "Deleted on disk".
void _tellEditors(ProviderContainer container, List<EnvironmentPath> gone) {
  final documents = container.read(openDocumentsProvider.notifier);
  for (final documentId in container.read(openDocumentsProvider).keys) {
    final path = documentPathOf(documentId);
    if (gone.any((went) => _same(went, path) || _isUnder(went, path))) {
      unawaited(documents.checkOnDisk(documentId));
    }
  }
}

String _key(EnvironmentPath path) {
  var spelled = path.path.replaceAll(r'\', '/').toLowerCase();
  while (spelled.length > 1 && spelled.endsWith('/')) {
    spelled = spelled.substring(0, spelled.length - 1);
  }
  return '${path.environmentId}␟$spelled';
}

bool _same(EnvironmentPath a, EnvironmentPath b) => _key(a) == _key(b);

bool _isUnder(EnvironmentPath folder, EnvironmentPath path) =>
    _key(path).startsWith('${_key(folder)}/');
