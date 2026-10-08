import 'dart:async';

import '../errors.dart';
import '../json.dart';
import '../peer/acp_peer.dart';
import '../peer/peer_messages.dart';
import '../types/capabilities.dart';
import '../types/content_block.dart';
import '../types/enums.dart';
import '../types/mcp_server.dart';
import '../types/permission.dart';
import '../types/results.dart';
import '../types/session_config.dart';
import '../types/session_update.dart';
import '../vocabulary.dart';
import 'acp_client_handler.dart';

/// The client side of ACP over one [AcpPeer]: typed calls to the agent,
/// its `session/update` stream, and its requests routed to a handler.
///
/// Spec: https://agentclientprotocol.com/protocol/v1/overview
class AcpAgentClient {
  AcpAgentClient(
    this.peer, {
    required this._handler,
    this.protocolVersion = AcpVocabulary.protocolVersion,
  }) {
    _requestSubscription = peer.requests.listen(_onRequest);
    _notificationSubscription = peer.notifications.listen(
      _onNotification,
      onDone: () => unawaited(_updates.close()),
    );
  }

  final AcpPeer peer;
  final int protocolVersion;
  final AcpClientHandler _handler;
  final _updates = StreamController<SessionUpdateEvent>.broadcast();
  final _pendingPermissions = <String, Set<AcpIncomingRequest>>{};
  late final StreamSubscription<AcpIncomingRequest> _requestSubscription;
  late final StreamSubscription<AcpNotification> _notificationSubscription;

  /// Broadcast: subscribe before the prompt whose updates you want. Done once
  /// the peer has closed, whichever side ended it.
  Stream<SessionUpdateEvent> get updates => _updates.stream;

  /// Throws [AcpVersionMismatch] unless the agent answers [protocolVersion].
  Future<InitializeResult> initialize({
    required ClientInfo clientInfo,
    ClientCapabilities clientCapabilities = const ClientCapabilities(),
  }) async {
    final result = InitializeResult.fromJson(
      await _call(AcpMethods.initialize, {
        'protocolVersion': protocolVersion,
        'clientCapabilities': clientCapabilities.toJson(),
        'clientInfo': clientInfo.toJson(),
      }),
    );
    if (result.protocolVersion != protocolVersion) {
      throw AcpVersionMismatch(
        ours: protocolVersion,
        theirs: result.protocolVersion,
      );
    }
    return result;
  }

  Future<void> authenticate(String methodId) async {
    await _call(AcpMethods.authenticate, {'methodId': methodId});
  }

  /// Ends the agent's authenticated session; only an agent whose
  /// capabilities say `auth.logout` answers it.
  Future<void> logout() async {
    await _call(AcpMethods.logout, const {});
  }

  /// Throws [AcpAuthenticationRequired] when the agent wants
  /// [authenticate] first.
  Future<NewSessionResult> newSession({
    required String cwd,
    List<McpServerEntry> mcpServers = const [],
  }) async => NewSessionResult.fromJson(
    await _call(AcpMethods.sessionNew, {
      'cwd': cwd,
      'mcpServers': [for (final s in mcpServers) s.toJson()],
    }),
  );

  /// The agent replays the session's updates on [updates] before answering.
  /// [meta] goes as the request's `_meta`, for an agent that reads one.
  Future<LoadSessionResult> loadSession({
    required String sessionId,
    required String cwd,
    List<McpServerEntry> mcpServers = const [],
    Map<String, Object?>? meta,
  }) async => LoadSessionResult.fromJson(
    await _call(AcpMethods.sessionLoad, {
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': [for (final s in mcpServers) s.toJson()],
      '_meta': ?meta,
    }),
  );

  /// Completes when the turn ends; its updates arrive on [updates] meanwhile.
  Future<StopReason> prompt(String sessionId, List<ContentBlock> prompt) async {
    final result = await _call(AcpMethods.sessionPrompt, {
      'sessionId': sessionId,
      'prompt': [for (final block in prompt) block.toJson()],
    });
    return StopReason.fromJson(result.requireString('stopReason'));
  }

  /// Asks the agent to stop the turn; the pending [prompt] then answers
  /// `cancelled`. Permission requests still open for the session are
  /// answered `cancelled` here, as the protocol asks of the client.
  void cancel(String sessionId) {
    // Answered before the notification goes out, so the agent never sees a
    // cancel while it still waits on us.
    final open = _pendingPermissions.remove(sessionId);
    for (final request in open ?? const <AcpIncomingRequest>{}) {
      request.respond({'outcome': const PermissionCancelled().toJson()});
    }
    peer.notify(AcpMethods.sessionCancel, {'sessionId': sessionId});
  }

  Future<void> setMode(String sessionId, String modeId) async {
    await _call(AcpMethods.sessionSetMode, {
      'sessionId': sessionId,
      'modeId': modeId,
    });
  }

  /// A `select` option takes [valueId]; a `boolean` one takes [flag]. Exactly
  /// one must be given. Returns the options as they stand afterwards.
  Future<List<ConfigOption>> setConfigOption(
    String sessionId,
    String configId, {
    String? valueId,
    bool? flag,
  }) async {
    if ((valueId == null) == (flag == null)) {
      throw ArgumentError('give exactly one of valueId or flag');
    }
    final result = await _call(AcpMethods.sessionSetConfigOption, {
      'sessionId': sessionId,
      'configId': configId,
      if (flag != null) 'type': 'boolean',
      'value': flag ?? valueId,
    });
    return configOptionsFromJson(result.objects('configOptions')) ?? const [];
  }

  Future<void> close() async {
    await _requestSubscription.cancel();
    await _notificationSubscription.cancel();
    await _updates.close();
    await peer.close();
  }

  Future<JsonMap> _call(String method, JsonMap params) async {
    final result = await peer.call(method, params);
    // A result that is not an object (notably `null` for an empty response)
    // is an empty one; every caller reads optional fields off it.
    return asJsonMap(result) ?? const {};
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method != AcpMethods.sessionUpdate) return;
    final params = notification.paramsMap;
    if (params.object('update') == null) return;
    _updates.add(SessionUpdateEvent.fromJson(params));
  }

  Future<void> _onRequest(AcpIncomingRequest request) async {
    try {
      final result = await _dispatch(request);
      request.respond(result);
    } on AcpRpcError catch (e) {
      request.fail(e.code, e.message, data: e.data);
    } on AcpMethodNotSupported catch (e) {
      request.fail(
        JsonRpcErrorCodes.methodNotFound,
        'Method not found: ${e.method}',
      );
    } on FormatException catch (e) {
      request.fail(JsonRpcErrorCodes.invalidParams, e.message);
    } catch (e) {
      request.fail(JsonRpcErrorCodes.internalError, '$e');
    }
  }

  Future<Object?> _dispatch(AcpIncomingRequest request) async {
    final params = request.paramsMap;
    switch (request.method) {
      case AcpMethods.sessionRequestPermission:
        final sessionId = params.requireString('sessionId');
        final toolCall = ToolCallUpdate.fromJson(
          params.requireObject('toolCall'),
          isNew: false,
        );
        final options = [
          for (final o in params.objects('options') ?? const <JsonMap>[])
            PermissionOption.fromJson(o),
        ];
        _pendingPermissions.putIfAbsent(sessionId, () => {}).add(request);
        try {
          final outcome = await _handler.requestPermission(
            sessionId,
            toolCall,
            options,
          );
          return {'outcome': outcome.toJson()};
        } finally {
          _pendingPermissions[sessionId]?.remove(request);
        }
      case AcpMethods.fsReadTextFile:
        final content = await _handler.readTextFile(
          params.requireString('sessionId'),
          params.requireString('path'),
          line: params.integer('line'),
          limit: params.integer('limit'),
        );
        return {'content': content};
      case AcpMethods.fsWriteTextFile:
        await _handler.writeTextFile(
          params.requireString('sessionId'),
          params.requireString('path'),
          params.string('content') ?? '',
        );
        return const <String, Object?>{};
      default:
        if (request.method.startsWith('terminal/')) {
          return _handler.terminal(request.method, request.params);
        }
        throw AcpMethodNotSupported(request.method);
    }
  }
}
