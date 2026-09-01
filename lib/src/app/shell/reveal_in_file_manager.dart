import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/process/command_runner.dart';
import '../../core/process/command_runner_providers.dart';
import '../../core/process/path_translator.dart';
import '../../features/environments/application/environment_providers.dart';
import '../../features/environments/domain/environment_kind.dart';
import '../../features/environments/domain/environment_path.dart';
import '../../features/environments/domain/execution_environment.dart';
import '../../features/environments/domain/local_environment.dart';

/// Which file manager the host has, and therefore how it is asked to show a
/// path. Injectable so the argument shape can be asserted without a desktop.
enum HostFileManager {
  /// `explorer.exe C:\dir`, or `explorer.exe /select,C:\dir\file`.
  windowsExplorer,

  /// `open <dir>`, or `open -R <file>`.
  macFinder,

  /// `xdg-open <dir>`. There is no portable "select this entry".
  xdgOpen;

  static HostFileManager? forHost() {
    if (kIsWeb) return null;
    if (Platform.isWindows) return windowsExplorer;
    if (Platform.isMacOS) return macFinder;
    if (Platform.isLinux) return xdgOpen;
    return null;
  }
}

/// The outcome of a reveal. [error] is null when the file manager was opened,
/// and otherwise says — in words a snackbar can show — why it was not.
@immutable
class RevealOutcome {
  const RevealOutcome.opened() : error = null;
  const RevealOutcome.failed(String this.error);

  final String? error;

  bool get ok => error == null;
}

/// Shows a path in the host's file manager.
///
/// **One helper, because there is one hard part.** Every path in Karmashala is
/// an [EnvironmentPath] — a path *plus the environment that owns it* — and the
/// file manager only exists on the host. A repository checked out in WSL is
/// `/home/me/src/app` to the agent running in it and `\\wsl.localhost\Ubuntu\
/// home\me\src\app` to Explorer, and the mapping between the two belongs in
/// [PathTranslator], not in each menu item that wants to open a folder.
///
/// Nothing here is "open with the default program". A remote path over SSH has
/// no host spelling at all, and [canReveal] says so before a menu item offers
/// it — an entry that always fails is worse than no entry.
class RevealInFileManager {
  const RevealInFileManager({
    required this.host,
    required this.translator,
    required this.environmentFor,
    this.fileManagerOverride,
  });

  final CommandRunner host;
  final PathTranslator translator;

  /// How an environment id is resolved to the environment that owns it. A
  /// callback, not a value, so constructing this never opens the database.
  final ExecutionEnvironment? Function(String environmentId) environmentFor;

  /// Set in tests to assert the argument shape for a host we are not on.
  final HostFileManager? fileManagerOverride;

  HostFileManager? get fileManager =>
      fileManagerOverride ?? HostFileManager.forHost();

  /// A Windows path as Explorer must be handed it: a drive path or a UNC path.
  static final _windowsPath = RegExp(r'^([A-Za-z]:[\\/]|\\\\)');

  /// [path] spelled the way the host's file manager must be given it, or null
  /// when the host has no way to reach it: a remote path, an unknown
  /// environment, a WSL distribution with no name recorded, or a path that
  /// cannot be a path in the environment it claims to belong to.
  String? hostPathFor(EnvironmentPath path) {
    final owner = environmentFor(path.environmentId);
    if (owner == null) return null;
    if (owner.kind == EnvironmentKind.ssh) return null;
    if (owner.kind == EnvironmentKind.windowsNative) {
      // A POSIX-absolute path carrying a Windows environment id is a record
      // that does not describe a real location — `git worktree list` reports
      // one for a worktree that was created from inside WSL. Guessing which
      // machine `/mnt/c/...` meant is the implicit conversion `PathTranslator`
      // exists to forbid, so this answers "no" rather than handing Explorer
      // something it will refuse.
      return _windowsPath.hasMatch(path.path) ? path.path : null;
    }
    try {
      return translator
          .translate(
            path,
            from: owner,
            to: windowsHostEnvironment(owner.createdAt),
          )
          .path;
    } on PathTranslationException {
      return null;
    }
  }

  /// Whether [path] can be shown at all. Cheap: no process is started, so it is
  /// safe to call while building a menu.
  bool canReveal(EnvironmentPath path) =>
      fileManager != null && hostPathFor(path) != null;

  /// Opens the host's file manager on [path].
  ///
  /// [select] highlights the entry inside its parent folder — right for a file,
  /// wrong for a folder you want opened. Windows Explorer and Finder can do it;
  /// `xdg-open` cannot, and quietly opens the folder instead.
  Future<RevealOutcome> reveal(
    EnvironmentPath path, {
    bool select = false,
  }) async {
    final manager = fileManager;
    if (manager == null) {
      return const RevealOutcome.failed(
        'This platform has no file manager Karmashala can open.',
      );
    }
    final hostPath = hostPathFor(path);
    if (hostPath == null) {
      final owner = environmentFor(path.environmentId);
      return RevealOutcome.failed(
        owner?.kind == EnvironmentKind.ssh
            ? '${path.path} is on ${owner!.name}, not on this machine.'
            : 'There is no path on this machine for ${path.path}.',
      );
    }
    try {
      // The exit code is deliberately ignored: `explorer.exe` returns 1 even
      // when it opens the window, so treating non-zero as failure would report
      // an error on every successful reveal.
      await host.run(_requestFor(manager, hostPath, select: select));
      return const RevealOutcome.opened();
    } on CommandException catch (e) {
      return RevealOutcome.failed(
        'Could not open the file manager: ${e.message}',
      );
    }
  }

  /// The command for [manager], exposed so its argument shape is testable
  /// without a desktop to open a window on.
  static CommandRequest requestFor(
    HostFileManager manager,
    String hostPath, {
    bool select = false,
  }) => _requestFor(manager, hostPath, select: select);

  static CommandRequest _requestFor(
    HostFileManager manager,
    String hostPath, {
    required bool select,
  }) => switch (manager) {
    // `/select,<path>` is one argument, comma and all — Explorer parses the
    // switch and its operand out of a single token.
    HostFileManager.windowsExplorer => CommandRequest(
      executable: 'explorer.exe',
      arguments: [if (select) '/select,$hostPath' else hostPath],
    ),
    HostFileManager.macFinder => CommandRequest(
      executable: 'open',
      arguments: [if (select) '-R', hostPath],
    ),
    HostFileManager.xdgOpen => CommandRequest(
      executable: 'xdg-open',
      arguments: [hostPath],
    ),
  };
}

/// The app's [RevealInFileManager], on the host runner.
///
/// The environment lookup is a callback rather than a read at construction so
/// composing this never opens the database — only actually revealing something
/// does.
final revealInFileManagerProvider = Provider<RevealInFileManager>(
  (ref) => RevealInFileManager(
    host: ref.watch(hostCommandRunnerProvider),
    translator: ref.watch(pathTranslatorProvider),
    environmentFor: (id) =>
        ref.read(executionEnvironmentDaoProvider).getById(id),
  ),
);
