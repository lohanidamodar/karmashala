import 'dart:async';

import '../agents/domain/agent_descriptor.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_registry.dart';
import '../environments/environment_path.dart';
import '../process/command_runner.dart';
import '../process/process_handle.dart';
import '../agents/adapter/generic_one_shot.dart';

/// Asks a coding CLI one question and streams back what it says.
///
/// Stateless by design: each call is a fresh process. The CLIs do have resume
/// modes, but relying on them would put the conversation's memory inside the
/// CLI's session store, where this code cannot trim it, inspect it, or keep it
/// consistent with what the caller thinks the history is. Use `stream` — the
/// adapters and `StreamingAgentSession` — when a conversation is what you want.
///
/// The runner is passed in rather than resolved here: which environment an
/// installation lives in is the caller's knowledge, and a class that went
/// looking for it would need the environment table this package deliberately
/// does not own.
class CliSession {
  CliSession({
    required this.installation,
    required CommandRunner runner,
    this.registry = AgentRegistry.builtIn,
  }) : _runner = runner;

  final AgentInstallation installation;
  final CommandRunner _runner;
  final AgentRegistry registry;

  AgentDescriptor? get descriptor => registry.byId(installation.agentId);

  /// The name to put in a message about this agent.
  String get label => registry.displayNameFor(installation.agentId);

  ProcessHandle? _active;

  /// Whether a question is in flight.
  bool get isBusy => _active != null;

  /// Streams the reply to [prompt].
  ///
  /// Cancelling the returned stream kills the process, which is what makes
  /// barge-in work: the user talking over the answer stops it being generated,
  /// rather than waiting for a reply nobody will hear.
  Stream<String> ask(
    String prompt, {
    String? systemPrompt,
    String? model,
    EnvironmentPath? workingDirectory,
    Duration timeout = const Duration(minutes: 3),
  }) async* {
    // An installation whose agent left the registry is still asked, the way
    // an agent with no protocol is.
    final invocation =
        registry
            .adapterFor(installation.agentId)
            ?.oneShot(prompt, systemPrompt: systemPrompt, model: model) ??
        genericOneShot(null, prompt, systemPrompt: systemPrompt, model: model);

    final handle = await _runner.start(
      CommandRequest(
        executable: installation.executable.path,
        arguments: invocation.arguments,
        workingDirectory: workingDirectory,
      ),
    );
    _active = handle;

    // These CLIs read stdin when it is not a terminal and will wait forever
    // for input that is never coming — `codex exec` says so out loud.
    await handle.closeStdin();

    final errors = <String>[];
    final errorSub = handle.stderrLines.listen(errors.add);

    var sawAnything = false;
    try {
      await for (final line in handle.stdoutLines.timeout(timeout)) {
        final text = invocation.parse(line);
        if (text != null && text.isNotEmpty) {
          sawAnything = true;
          yield text;
        }
      }

      final code = await handle.exitCode;
      if (code != 0 && !sawAnything) {
        throw CliSessionException(
          '$label exited with code $code',
          detail: errors.isEmpty ? null : errors.take(6).join('\n'),
        );
      }
    } on TimeoutException {
      await handle.kill();
      throw CliSessionException(
        '$label did not answer within ${timeout.inSeconds}s',
      );
    } finally {
      await errorSub.cancel();
      if (identical(_active, handle)) _active = null;
      // Cancelling the stream lands here too, which is where barge-in stops
      // the process rather than leaving it running unheard.
      await handle.kill().catchError((_) {});
    }
  }

  Future<void> cancel() async {
    final handle = _active;
    _active = null;
    if (handle != null) await handle.kill();
  }
}

class CliSessionException implements Exception {
  const CliSessionException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}
