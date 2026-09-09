import 'package:agent_cli/process.dart';

/// A deterministic [CommandRunner] test double.
///
/// The fields are those of the app's `test/support/fake_command_runner.dart`,
/// so a suite reads the same either side of the split; [start] is not, because
/// nothing in this package starts a long-lived process — a scan and an SDK
/// probe both run to completion.
class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner({this.environmentId = 'windows', this.responder, this.throwError});

  @override
  final String environmentId;

  /// Maps a request to a result. Defaults to exit 0 with empty output.
  CommandResult Function(CommandRequest request)? responder;

  /// If set, [run] throws this instead of returning a result.
  Object? throwError;

  /// All requests received, in order.
  final List<CommandRequest> requests = <CommandRequest>[];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    if (throwError != null) throw throwError!;
    return responder?.call(request) ??
        const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      throw UnsupportedError('nothing in karmashala_flutter_apps starts a process');
}
