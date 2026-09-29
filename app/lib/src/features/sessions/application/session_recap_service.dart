import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/session_model_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import 'package:karmashala_session/transcript.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_working_directory.dart';

/// Why a recap could not be written. The one that matters most is the chat
/// view's **own** words, so refusal and empty conversation cannot disagree.
class SessionRecapRefusal implements Exception {
  SessionRecapRefusal(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// Writes the recap a person asked for, by running the session's own CLI.
/// **Only ever from the action**: it costs a turn of the owner's quota.
class SessionRecapService {
  SessionRecapService(this._ref);

  final Ref _ref;

  /// Reads [sessionId]'s conversation, asks its CLI to recap it, and stores the
  /// answer. Throws [SessionRecapRefusal] with the reason otherwise.
  Future<SessionRecap> write(String sessionId) async {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) {
      throw SessionRecapRefusal('This session no longer exists.');
    }
    final installation = _ref
        .read(agentInstallationsDataProvider)
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

    // The reading, not the allowlist: a session with no readable transcript
    // refuses in the conversation's own sentence.
    final reading = await _ref.read(
      sessionChatViewProbeProvider(sessionId).future,
    );
    if (!reading.hasChatView) {
      throw SessionRecapRefusal('There is nothing to recap. ${reading.reason}');
    }

    final (turns, earlier) = await _turnsOf(session.id, installation.agentId);
    if (turns.isEmpty) {
      throw SessionRecapRefusal('There is nothing to recap. ${reading.reason}');
    }
    final blob = _blob(turns, earlier: earlier);

    final environment = _ref
        .read(environmentsDataProvider)
        .getById(installation.executable.environmentId);
    if (environment == null) {
      throw SessionRecapRefusal(
        'The environment this agent is installed in is no longer known, so '
        'nothing can be run there.',
      );
    }

    // Asked for explicitly wherever the CLI takes a flag, so the stored row can
    // name the model truthfully; where it takes none, the row says nothing.
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
      throw SessionRecapRefusal(
        '${descriptor.displayName} could not be run: '
        '${error.message}',
      );
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
      // What the conversation held when it was read — the number "the session
      // has moved since" is counted against.
      turnCount: earlier + turns.length,
      writtenAt: _ref.read(clockProvider).nowUtc(),
    );
    _ref.read(sessionRecordsProvider).writeRecap(written);
    _ref.invalidate(sessionRecapProvider(sessionId));
    return written;
  }

  /// The session's turns, oldest first, read from the agent's own transcript
  /// — the same record the conversation on screen is drawn from — and how
  /// many earlier ones were not read. The server reads only the tail the
  /// recap has room for.
  Future<(List<TranscriptMessage>, int)> _turnsOf(
    String sessionId,
    String agentId,
  ) async {
    final row = _ref.read(sessionsDataProvider).getById(sessionId);
    final externalId = row?.externalSessionId;
    const none = (<TranscriptMessage>[], 0);
    if (externalId == null || externalId.isEmpty) return none;
    final served = await serverSessionTurns(
      _ref,
      sessionId,
      enough: (held) {
        var bytes = 0;
        for (final turn in held) {
          bytes += _line(turn).length + 1;
          if (bytes > kMaxTranscriptTextBytes) return true;
        }
        return false;
      },
    );
    if (served != null) return (served.turns, served.from);
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) return none;
    return (await readCliTranscript(path, agentId), 0);
  }

  static String _line(TranscriptMessage turn) =>
      '${turn.role}: ${turn.text.trim()}';

  /// The conversation as one document, newest-first-fitted and bounded; when
  /// anything is left out the document says so in its own first line.
  /// [earlier] turns before [turns] were never read.
  String _blob(List<TranscriptMessage> turns, {int earlier = 0}) {
    final kept = <String>[];
    var bytes = 0;
    for (var i = turns.length - 1; i >= 0; i--) {
      final line = _line(turns[i]);
      final cost = line.length + 1;
      if (bytes + cost > kMaxTranscriptTextBytes) {
        final omitted = earlier + i + 1;
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

/// The recap [sessionId] holds, or null when nobody has asked for one — read
/// from the copy, and again whenever a recap changes here or elsewhere.
final sessionRecapProvider = Provider.autoDispose.family<SessionRecap?, String>(
  (ref, sessionId) {
    final records = ref.watch(sessionRecordsProvider);
    final changed = records.recapChanges.listen((_) => ref.invalidateSelf());
    ref.onDispose(changed.cancel);
    return records.recapFor(sessionId);
  },
);
