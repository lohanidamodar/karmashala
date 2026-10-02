import 'dart:async';

import '../errors.dart';
import '../json.dart';
import '../peer/acp_peer.dart';
import '../peer/peer_messages.dart';
import '../types/capabilities.dart';
import '../types/content_block.dart';
import '../types/enums.dart';
import '../types/permission.dart';
import '../types/session_config.dart';
import '../types/session_update.dart';
import '../vocabulary.dart';
import 'fake_script.dart';

/// An ACP agent driven by a script, over in-memory streams. Build a client
/// with [clientPeer] and talk to it as to a real agent; what it was told is
/// recorded on the public lists.
class FakeAcpAgent {
  FakeAcpAgent({
    List<FakeTurn> turns = const [],
    this.protocolVersion = AcpVocabulary.protocolVersion,
    this.requireAuthentication = false,
    this.authMethods = const [AuthMethod(id: 'fake-login', name: 'Fake login')],
    this.modes,
    this.configOptions,
    this.sessionIdPrefix = 'fake-session',
    this.supportsLoadSession = true,
    this.loadReplay = const [],
    this.agentInfo = const AgentInfo(name: 'fake-acp-agent', version: '0.0.1'),
  }) : _turns = List.of(turns) {
    _peer = AcpPeer(_fromClient.stream, _toClient.sink);
    _peer.requests.listen(_onRequest);
    _peer.notifications.listen(_onNotification);
  }

  final int protocolVersion;

  /// `session/new` fails -32000 until `authenticate` has been called.
  final bool requireAuthentication;
  final List<AuthMethod> authMethods;
  final SessionModeState? modes;

  /// The options `session/new` and `session/load` answer with;
  /// `session/set_config_option` moves the one it names and answers them all.
  List<ConfigOption>? configOptions;
  final String sessionIdPrefix;
  final bool supportsLoadSession;

  /// Updates replayed, in order, before `session/load` is answered.
  final List<SessionUpdate> loadReplay;
  final AgentInfo agentInfo;

  final List<FakeTurn> _turns;
  final _fromClient = StreamController<List<int>>();
  final _toClient = StreamController<List<int>>();
  late final AcpPeer _peer;
  var _sessions = 0;
  _ActiveTurn? _activeTurn;

  // What the client said, for assertions.
  JsonMap? initializeParams;
  String? authenticatedWith;
  final newSessionParams = <JsonMap>[];
  final loadSessionParams = <JsonMap>[];
  final prompts = <List<ContentBlock>>[];
  final permissionOutcomes = <PermissionOutcome>[];
  final readFileResults = <String>[];

  /// Errors the client answered `fs/*` requests with.
  final fsErrors = <AcpException>[];
  final modeChanges = <String>[];
  final configChanges = <JsonMap>[];
  var cancels = 0;

  /// Every request received, in order, by method.
  final receivedMethods = <String>[];

  /// Bytes the agent writes; a client reads them.
  Stream<List<int>> get toClient => _toClient.stream;

  /// Bytes the client writes; the agent reads them.
  StreamSink<List<int>> get fromClient => _fromClient.sink;

  /// A fresh client-side peer wired to this agent.
  AcpPeer clientPeer() => AcpPeer(toClient, fromClient);

  /// The agent's own peer, for sending anything the script cannot.
  AcpPeer get peer => _peer;

  bool get isInTurn => _activeTurn != null;

  Future<void> close() => _peer.close();

  Future<void> _onRequest(AcpIncomingRequest request) async {
    receivedMethods.add(request.method);
    final params = request.paramsMap;
    try {
      switch (request.method) {
        case AcpMethods.initialize:
          initializeParams = params;
          request.respond(
            InitializeResultJson.of(
              protocolVersion: protocolVersion,
              loadSession: supportsLoadSession,
              authMethods: authMethods,
              agentInfo: agentInfo,
            ),
          );
        case AcpMethods.authenticate:
          authenticatedWith = params.string('methodId');
          request.respond(const <String, Object?>{});
        case AcpMethods.sessionNew:
          newSessionParams.add(params);
          if (requireAuthentication && authenticatedWith == null) {
            request.fail(
              JsonRpcErrorCodes.authRequired,
              'Authentication required',
            );
            return;
          }
          _sessions++;
          request.respond(
            withoutNulls({
              'sessionId': _sessions == 1
                  ? sessionIdPrefix
                  : '$sessionIdPrefix-$_sessions',
              'modes': modes?.toJson(),
              'configOptions': switch (configOptions) {
                final options? => [for (final o in options) o.toJson()],
                null => null,
              },
            }),
          );
        case AcpMethods.sessionLoad:
          loadSessionParams.add(params);
          final sessionId = params.string('sessionId') ?? '';
          for (final update in loadReplay) {
            _sendUpdate(sessionId, update.toJson());
          }
          request.respond(
            withoutNulls({
              'modes': modes?.toJson(),
              'configOptions': switch (configOptions) {
                final options? => [for (final o in options) o.toJson()],
                null => null,
              },
            }),
          );
        case AcpMethods.sessionPrompt:
          prompts.add(contentBlocksFromJson(params.objects('prompt')));
          await _runTurn(request, params.string('sessionId') ?? '');
        case AcpMethods.sessionSetMode:
          final modeId = params.string('modeId') ?? '';
          modeChanges.add(modeId);
          request.respond(const <String, Object?>{});
          _sendUpdate(
            params.string('sessionId') ?? '',
            CurrentModeUpdate(modeId).toJson(),
          );
        case AcpMethods.sessionSetConfigOption:
          configChanges.add(params);
          _moveConfigOption(params.string('configId'), params['value']);
          request.respond({
            'configOptions': [
              for (final o in configOptions ?? const <ConfigOption>[])
                o.toJson(),
            ],
          });
        default:
          request.fail(
            JsonRpcErrorCodes.methodNotFound,
            'Method not found: ${request.method}',
          );
      }
    } catch (e) {
      request.fail(JsonRpcErrorCodes.internalError, '$e');
    }
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method != AcpMethods.sessionCancel) return;
    cancels++;
    _activeTurn?.cancel();
  }

  /// The option [configId] now holds [value]; one this agent does not hold
  /// is left alone, as the list it answers with says.
  void _moveConfigOption(String? configId, Object? value) {
    final options = configOptions;
    if (options == null || configId == null) return;
    configOptions = [
      for (final option in options)
        if (option.id == configId)
          ConfigOption(
            id: option.id,
            name: option.name,
            type: option.type,
            description: option.description,
            category: option.category,
            currentValue: value,
            options: option.options,
          )
        else
          option,
    ];
  }

  Future<void> _runTurn(AcpIncomingRequest request, String sessionId) async {
    final turn = _turns.isEmpty ? const FakeTurn([]) : _turns.removeAt(0);
    final active = _ActiveTurn();
    _activeTurn = active;
    var reason = turn.stopReason;
    try {
      for (final step in turn.steps) {
        if (active.isCancelled) break;
        final keepGoing = await _run(step, sessionId, active);
        if (!keepGoing) break;
      }
    } finally {
      if (active.isCancelled) reason = StopReason.cancelled;
      _activeTurn = null;
      request.respond({'stopReason': reason.toJson()});
    }
  }

  /// Runs one step; false when the turn must stop here.
  Future<bool> _run(FakeStep step, String sessionId, _ActiveTurn turn) async {
    switch (step) {
      case FakeMessageStep(:final text, :final messageId):
        _sendUpdate(
          sessionId,
          AgentMessageChunk(
            ContentBlock.text(text),
            messageId: messageId,
          ).toJson(),
        );
      case FakeThoughtStep(:final text, :final messageId):
        _sendUpdate(
          sessionId,
          AgentThoughtChunk(
            ContentBlock.text(text),
            messageId: messageId,
          ).toJson(),
        );
      case FakePlanStep(:final entries):
        _sendUpdate(sessionId, PlanUpdate(entries).toJson());
      case FakeModeStep(:final modeId):
        _sendUpdate(sessionId, CurrentModeUpdate(modeId).toJson());
      case FakeUpdateStep(:final update):
        _sendUpdate(sessionId, update.toJson());
      case FakeRawUpdateStep(:final update):
        _sendUpdate(sessionId, update);
      case FakeWaitForCancelStep():
        await turn.cancelled;
        return false;
      case FakeReadFileStep(:final path, :final line, :final limit):
        final result = await turn.race(
          _peer.call(
            AcpMethods.fsReadTextFile,
            withoutNulls({
              'sessionId': sessionId,
              'path': path,
              'line': line,
              'limit': limit,
            }),
          ),
        );
        if (result.cancelled) return false;
        if (result.error case final error?) {
          fsErrors.add(error);
        } else {
          readFileResults.add(asJsonMap(result.value)?.string('content') ?? '');
        }
      case FakeWriteFileStep(:final path, :final content):
        final result = await turn.race(
          _peer.call(AcpMethods.fsWriteTextFile, {
            'sessionId': sessionId,
            'path': path,
            'content': content,
          }),
        );
        if (result.cancelled) return false;
        if (result.error case final error?) fsErrors.add(error);
      case FakeToolCallStep():
        return _runToolCall(step, sessionId, turn);
    }
    return true;
  }

  Future<bool> _runToolCall(
    FakeToolCallStep step,
    String sessionId,
    _ActiveTurn turn,
  ) async {
    final opening = step.opening;
    _sendUpdate(sessionId, opening.toJson());
    var allowed = true;
    if (step.permissionOptions case final options?) {
      final call = _peer.call(AcpMethods.sessionRequestPermission, {
        'sessionId': sessionId,
        'toolCall': opening.toToolCallJson(),
        'options': [for (final o in options) o.toJson()],
      });
      // Recorded off the raw call, so an answer that lands beside a cancel
      // is still seen.
      unawaited(
        call.then(
          (answer) => permissionOutcomes.add(_outcomeOf(answer)),
          onError: (Object _) {},
        ),
      );
      final answer = await turn.race(call);
      if (answer.cancelled || answer.error != null) {
        turn.cancel();
        return false;
      }
      switch (_outcomeOf(answer.value)) {
        case PermissionCancelled():
          turn.cancel();
          return false;
        case PermissionSelected(:final optionId):
          allowed = options
              .where((o) => o.optionId == optionId)
              .any((o) => o.kind.allows);
      }
    }
    _sendUpdate(
      sessionId,
      ToolCallUpdate(
        toolCallId: step.toolCallId,
        status: allowed ? ToolCallStatus.inProgress : ToolCallStatus.failed,
      ).toJson(),
    );
    if (allowed) {
      _sendUpdate(
        sessionId,
        ToolCallUpdate(
          toolCallId: step.toolCallId,
          status: ToolCallStatus.completed,
          content: step.completedContent,
          rawOutput: step.rawOutput,
        ).toJson(),
      );
    }
    return true;
  }

  static PermissionOutcome _outcomeOf(Object? answer) =>
      PermissionOutcome.fromJson(
        asJsonMap(answer)?.object('outcome') ?? const {},
      );

  void _sendUpdate(String sessionId, JsonMap update) {
    _peer.notify(AcpMethods.sessionUpdate, {
      'sessionId': sessionId,
      'update': update,
    });
  }
}

/// The `initialize` result as the fake writes it.
abstract final class InitializeResultJson {
  static JsonMap of({
    required int protocolVersion,
    required bool loadSession,
    required List<AuthMethod> authMethods,
    required AgentInfo agentInfo,
  }) => {
    'protocolVersion': protocolVersion,
    'agentCapabilities': {
      'loadSession': loadSession,
      'promptCapabilities': {
        'image': false,
        'audio': false,
        'embeddedContext': true,
      },
      'mcpCapabilities': {'http': true, 'sse': false},
    },
    'authMethods': [for (final m in authMethods) m.toJson()],
    'agentInfo': agentInfo.toJson(),
  };
}

class _ActiveTurn {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// [call]'s answer, or that the turn was cancelled first.
  Future<_Answer> race(Future<Object?> call) {
    final answered = call.then(
      _Answer.new,
      onError: (Object e) => e is AcpException ? _Answer.failed(e) : throw e,
    );
    return Future.any([
      answered,
      cancelled.then((_) => const _Answer.cancelled()),
    ]);
  }
}

class _Answer {
  const _Answer(this.value, {this.error, this.cancelled = false});
  const _Answer.cancelled() : this(null, cancelled: true);
  const _Answer.failed(AcpException error) : this(null, error: error);

  final Object? value;
  final AcpException? error;
  final bool cancelled;
}
