import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/session_model_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../domain/session_recap.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_working_directory.dart';

/// Why a recap could not be written. Never a bare failure: every sentence here
/// is one a person can act on, and the one that matters most — this session has
/// no transcript to read — is the chat view's **own** words, so the refusal and
/// the empty conversation behind it cannot describe one session differently.
class SessionRecapRefusal implements Exception {
  SessionRecapRefusal(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// Writes the recap a person asked for, by running the session's own CLI.
///
/// **Only ever from the action.** There is no tick, no launch hook and no
/// end-of-session hook anywhere in this file's callers, and that is the whole
/// decision behind the feature rather than an accident of where the button
/// went: a recap costs a turn of the owner's quota, and `session_recap_test`
/// counts the spawns across a launch, an end and a restore to keep it true.
///
/// It also does not type into the running session. `SessionHandoffService`
/// does — its brief is asked for down `session_send` and waited for on
/// `session_wait`, because the packet wants *that agent's* view of its own
/// context. A recap wants the conversation, which is on disk, so it starts a
/// second process in print mode and lets it exit. Nothing is added to the
/// session the user comes back to.
class SessionRecapService {
  SessionRecapService(this._ref);

  final Ref _ref;

  /// Reads [sessionId]'s conversation, asks its CLI to recap it, and stores the
  /// answer. Throws [SessionRecapRefusal] with the reason otherwise.
  Future<SessionRecap> write(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw SessionRecapRefusal('This session no longer exists.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) {
      throw SessionRecapRefusal(
        'The agent this session ran on is no longer installed, so there is '
        'nothing to ask.',
      );
    }
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(installation.agentId);
    final recap = descriptor?.launch.recap;
    if (descriptor == null || recap == null || !recap.isSupported) {
      throw SessionRecapRefusal(
        recap != null && recap.wasChecked
            ? 'This agent has no non-interactive mode to ask: ${recap.evidence}'
            : 'Karmashala has not established how to ask this agent for a '
                  'recap, so it will not guess at a command line.',
      );
    }

    // The reading, not the allowlist. A session with no readable transcript
    // refuses in the conversation's own sentence, which is the one already on
    // screen behind this action.
    final reading = await _ref.read(
      sessionChatViewProbeProvider(sessionId).future,
    );
    if (!reading.hasChatView) {
      throw SessionRecapRefusal(
        'There is nothing to recap. ${reading.reason}',
      );
    }

    final turns = await _turnsOf(session.id, installation.agentId);
    if (turns.isEmpty) {
      throw SessionRecapRefusal(
        'There is nothing to recap. ${reading.reason}',
      );
    }
    final blob = _blob(turns);

    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(installation.executable.environmentId);
    if (environment == null) {
      throw SessionRecapRefusal(
        'The environment this agent is installed in is no longer known, so '
        'nothing can be run there.',
      );
    }

    // Asked for explicitly wherever the CLI takes a flag, so the stored row can
    // name the model truthfully. Where it takes none the row says nothing
    // rather than repeating the session's model as though we had asked for it.
    final model = _ref.read(sessionModelProvider(sessionId))?.modelId;
    final flag = descriptor.launch.model.flag;
    final modelArguments = flag.isEmpty || model == null || model.isEmpty
        ? const <String>[]
        : [flag, model];

    final request = CommandRequest(
      executable: installation.executable.path,
      arguments: recap.argumentsFor(
        request: kSessionRecapRequest,
        turns: blob,
        modelArguments: modelArguments,
      ),
      stdinText: recap.stdinFor(blob),
      workingDirectory: sessionWorkingDirectory(_ref, sessionId),
    );

    final CommandResult result;
    try {
      result = await _ref
          .read(commandRunnerFactoryProvider)
          .forEnvironment(environment)
          .run(request);
    } on CommandException catch (error) {
      throw SessionRecapRefusal('${descriptor.displayName} could not be run: '
          '${error.message}');
    }
    if (!result.ok) {
      final said = result.stderr.trim().isEmpty
          ? result.stdout.trim()
          : result.stderr.trim();
      throw SessionRecapRefusal(
        '${descriptor.displayName} exited ${result.exitCode} without writing '
        'a recap${said.isEmpty ? '.' : ': $said'}',
      );
    }
    final text = result.stdout.trim();
    if (text.isEmpty) {
      throw SessionRecapRefusal(
        '${descriptor.displayName} answered nothing, so there is no recap to '
        'show. Nothing was stored.',
      );
    }

    final written = SessionRecap(
      sessionId: sessionId,
      text: text,
      agentId: installation.agentId,
      model: modelArguments.isEmpty ? null : model,
      // What the conversation held when it was read — not how much of it fit,
      // which the document itself says in its first line. This is the number
      // "the session has moved since" is counted against.
      turnCount: turns.length,
      writtenAt: _ref.read(clockProvider).nowUtc(),
    );
    _ref.read(sessionRecapDaoProvider).write(written);
    _ref.invalidate(sessionRecapProvider(sessionId));
    return written;
  }

  /// The session's visible turns, oldest first, read from the agent's own
  /// transcript — the same file the conversation on screen is drawn from.
  Future<List<TranscriptMessage>> _turnsOf(
    String sessionId,
    String agentId,
  ) async {
    final row = _ref.read(sessionDaoProvider).getById(sessionId);
    final externalId = row?.externalSessionId;
    if (externalId == null || externalId.isEmpty) return const [];
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) return const [];
    return readCliTranscript(path, agentId);
  }

  /// The conversation as one document, **newest-first-fitted**.
  ///
  /// Bounded at [kMaxTranscriptTextBytes] — the one number every other path
  /// this app moves transcript text down is bounded at — and the turns that fit
  /// are taken from the **end**, because a recap is asked for by somebody
  /// returning to a session and the end is what they are returning to. Cutting
  /// from the end instead would recap the opening of a conversation and call it
  /// a conclusion.
  ///
  /// When anything is left out the document says so in its first line. A model
  /// told it has the whole conversation will write about the whole
  /// conversation, which is how a bound becomes a false statement.
  String _blob(List<TranscriptMessage> turns) {
    final kept = <String>[];
    var bytes = 0;
    for (var i = turns.length - 1; i >= 0; i--) {
      final line = '${turns[i].role}: ${turns[i].text.trim()}';
      final cost = line.length + 1;
      if (bytes + cost > kMaxTranscriptTextBytes) {
        final omitted = i + 1;
        kept.insert(
          0,
          '[The earliest $omitted turns of this conversation are not shown '
          'here; it was too long to pass in full.]',
        );
        return boundedText(kept.join('\n\n')).$1;
      }
      bytes += cost;
      kept.insert(0, line);
    }
    return boundedText(kept.join('\n\n')).$1;
  }
}

final sessionRecapServiceProvider = Provider<SessionRecapService>(
  SessionRecapService.new,
);

/// The recap [sessionId] holds, or null when nobody has asked for one.
///
/// A plain read of the stored row, invalidated by the service after a write.
/// Nothing here refreshes on its own — the row only changes when a person asks.
final sessionRecapProvider = Provider.autoDispose.family<SessionRecap?, String>(
  (ref, sessionId) => ref.watch(sessionRecapDaoProvider).forSession(sessionId),
);
