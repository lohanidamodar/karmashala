import 'dart:io';

import '../environments/local_environment.dart';
import './command_runner.dart';
import './io_process_handle.dart';
import './process_handle.dart';
import './process_spawn.dart';
import './process_spawner.dart';

/// Runs commands on the **local host** — Windows, macOS or Linux.
///
/// This is the only place (besides `WslCommandRunner`) that describes a process
/// to create; features go through the [CommandRunner] interface. There is
/// nothing OS-specific left in here: what differs between hosts is the
/// *request* (see `locateRequest`), not how a process is started.
///
/// [run] hands the request to a [ProcessSpawner], which in the app means the
/// creation happens on a worker isolate rather than on the one drawing the
/// interface — see `process_spawner.dart` for why that is the whole fix, and
/// why it is not a Windows-only one. [start] cannot: a live [Process] does not
/// cross an isolate boundary.
class LocalCommandRunner implements CommandRunner {
  /// [spawner] is where this runner's processes are created; `null` means the
  /// app-wide [sharedProcessSpawner]. Nullable rather than defaulted so
  /// `const LocalCommandRunner()` still compiles at the three places that
  /// compose one, including `main()` before any container exists.
  const LocalCommandRunner({this.spawner});

  final ProcessSpawner? spawner;

  @override
  String get environmentId => localHostEnvironmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    try {
      return await (spawner ?? sharedProcessSpawner).run(request);
    } on ProcessException catch (e) {
      // Thrown by the creation itself, wherever it happened, and carried back
      // across the boundary as itself so this message is unchanged.
      throw CommandException(
        'Failed to run "${request.executable}" on ${Platform.operatingSystem}',
        cause: e,
      );
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    try {
      return IoProcessHandle(await spawnStreaming(request));
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to start "${request.executable}" on ${Platform.operatingSystem}',
        cause: e,
      );
    }
  }
}
