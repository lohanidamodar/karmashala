import '../../support/fake_command_runner.dart';

/// A streamed git process that has already finished: [stderr] printed, then
/// [code]. What a worktree's checkout stage gets from a fake runner that is not
/// testing the stream itself.
FakeProcessHandle finishedGit({int code = 0, List<String> stderr = const []}) {
  final handle = FakeProcessHandle();
  for (final line in stderr) {
    handle.emitStderr(line);
  }
  handle.complete(code);
  return handle;
}

/// The `git worktree add` a create ran, found among everything else it ran.
List<String>? worktreeAddArgv(FakeCommandRunner runner) {
  for (final request in runner.requests.reversed) {
    final args = request.arguments;
    final at = args.indexOf('worktree');
    if (at >= 0 && at + 1 < args.length && args[at + 1] == 'add') return args;
  }
  return null;
}
