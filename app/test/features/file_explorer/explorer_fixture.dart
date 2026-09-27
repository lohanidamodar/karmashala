import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Ref;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala_files/values.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';

/// A place on this machine, in the server's own spelling.
EnvironmentPath at(String path) =>
    EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

/// A listed folder at [path].
FileEntry dirEntry(String path) => FileEntry(
  name: p.windows.basename(path),
  path: at(path),
  kind: FileEntryKind.directory,
);

/// A listed file at [path].
FileEntry fileEntry(String path) => FileEntry(
  name: p.windows.basename(path),
  path: at(path),
  kind: FileEntryKind.file,
);

/// The Files panel over fixed listings by folder path: rooted at [root], the
/// editor showing [editing] (none by default), and a file manager that
/// records rather than runs.
List<Override> explorerOverrides(
  String root,
  Map<String, List<FileEntry>> listings, {
  FakeCommandRunner? host,
  EnvironmentPath? Function(Ref ref)? editing,
  List<FileEntry> Function(EnvironmentPath dir)? list,
}) => [
  fileTreeRootProvider.overrideWithValue(at(root)),
  activeEditorPathProvider.overrideWith(editing ?? (ref) => null),
  directoryListingProvider.overrideWith(
    (ref, dir) async => list?.call(dir) ?? listings[dir.path] ?? const [],
  ),
  revealInFileManagerProvider.overrideWithValue(
    RevealInFileManager(
      host: host ?? FakeCommandRunner(),
      translator: const PathTranslator(),
      environmentFor: (_) => null,
      fileManagerOverride: HostFileManager.windowsExplorer,
    ),
  ),
];
