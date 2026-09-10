import 'package:agent_cli/process.dart';

/// A deterministic [CommandRunner] test double, field-for-field the app's own
/// — minus [start], because nothing here runs a long-lived process.
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
