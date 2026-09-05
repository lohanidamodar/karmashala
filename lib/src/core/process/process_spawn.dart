import 'dart:io';

import 'command_runner.dart';

/// How many processes **this isolate** has created through this file.
///
/// Isolates share no memory, so the counter is per-isolate by construction —
/// which is the whole reason it is the measurement this file exists for. A
/// reading taken on the UI isolate that goes *up* across a call means a process
/// was created there, on the thread that draws frames; a reading that does not
/// move means the creation happened somewhere else.
///
/// It is a *count*, never a duration: milliseconds on a shared machine are
/// noise, and the deterministic half of this shape is how many processes an
/// isolate made. `test/core/process/process_spawn_isolate_test.dart` is the
/// only place that asserts on it; nothing in the app branches on it.
int get processSpawnsOnThisIsolate => _spawnsHere;
int _spawnsHere = 0;

/// Creates the process for [request] and waits for it to exit.
///
/// **This is the expensive half of running a command, and it is synchronous.**
/// `Process.run` looks asynchronous and only its *waiting* is: the process
/// creation itself — `CreateProcessW` on Windows, `fork`/`posix_spawn` on macOS
/// and Linux — is charged to the isolate that calls it, before the future being
/// awaited exists. Measured on the owner's machine, doing no work at all:
/// `git.exe` ~90 ms, `wsl.exe -d <distro> -- true` 208/439/328 ms. Thirty of
/// those on the UI isolate is the ten seconds of unpainted interface that
/// expanding a project used to cost, and it is why a 60 s CPU profile of this
/// app named `RtlCreateUnicodeString` (4.60%) and `NtCreateUserProcess` (2.02%)
/// among its top *Dart* leaves.
///
/// So the app does not call this from the UI isolate. `ProcessSpawner` decides
/// where it runs, and in the app that is a worker isolate — see
/// `process_spawner.dart`. This function stays deliberately dumb: it knows how
/// to turn a [CommandRequest] into a [CommandResult] and nothing about who is
/// asking or from where.
///
/// The working directory is read off the request's `EnvironmentPath` here, at
/// the `Process.run` call, and nowhere earlier: a path is bound to the
/// environment that owns it and is never flattened to a bare string in transit
/// (architecture constraints 7 & 8).
///
/// A [ProcessException] is left to propagate as itself. Each runner turns it
/// into the [CommandException] its own callers already expect, and it names the
/// environment — "on windows", "in WSL \"Ubuntu\"" — which this function has no
/// business knowing.
Future<CommandResult> spawnToCompletion(CommandRequest request) async {
  _spawnsHere++;
  final result = await Process.run(
    request.executable,
    request.arguments,
    workingDirectory: request.workingDirectory?.path,
    // Honoured for `run` as well as `start`: dropping it meant an executable
    // only the shell can resolve — an app-execution alias, or a `.cmd` shim
    // such as an npm-global `claude.cmd` — could be started but never probed,
    // and the probe's failure looked like "not installed".
    runInShell: request.runInShell,
    // wsl.exe and several Windows tools emit UTF-16; decode leniently and let
    // callers strip control characters as needed. This is also `Process.run`'s
    // own default, which is what the WSL runner has always relied on — naming
    // it keeps the two paths provably identical now that they share one call.
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  return CommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

/// Creates the process for [request] and hands back the live [Process].
///
/// **Stays on the calling isolate, and has to.** A [Process] is a handle to
/// native resources — three pipes and a wait — and none of that can be copied
/// across an isolate boundary, so a streaming command cannot be answered by a
/// worker the way [spawnToCompletion] is. Proxying the three streams and stdin
/// over ports would put a message hop in front of every byte an agent or a
/// terminal writes, which is a worse trade than the spawn it would move.
///
/// It costs far less than it looks, because the call sites are few and rare:
/// one per agent session, one per terminal, one per device stream. Nothing
/// starts thirty of these inside a frame the way the Explorer's git probes did.
Future<Process> spawnStreaming(CommandRequest request) {
  _spawnsHere++;
  return Process.start(
    request.executable,
    request.arguments,
    workingDirectory: request.workingDirectory?.path,
    runInShell: request.runInShell,
  );
}
