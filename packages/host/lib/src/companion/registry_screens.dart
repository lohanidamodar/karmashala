import 'dart:convert';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/host_session.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';

/// The write token's holder while a phone types, for as long as the typing
/// takes. A pane that attaches meanwhile is refused the token for that moment
/// and no longer.
const String kCompanionWriterId = 'companion';

/// The sessions this host runs, as the companion server shows them to a phone
/// while no desktop app is connected: their screens, their output offset, and
/// typing into them.
class RegistryScreens implements CompanionScreens {
  RegistryScreens(
    this.registry, {
    this.enterDelay = const Duration(milliseconds: 150),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final SessionRegistry registry;

  /// The pause between the text and its Enter. A TUI reads text and CR that
  /// arrive in one read as a paste, and a pasted CR is a newline in the draft,
  /// not a submit.
  final Duration enterDelay;
  final DateTime Function() _now;

  @override
  List<HostedSessionView> sessions() => [
    for (final session in registry.sessions) _view(session),
  ];

  @override
  HostedSessionView? find(String hostSessionId) {
    final session = registry.find(hostSessionId);
    return session == null ? null : _view(session);
  }

  @override
  String? screenText(String hostSessionId) =>
      registry.find(hostSessionId)?.screenText();

  @override
  int? outputOffset(String hostSessionId) =>
      registry.find(hostSessionId)?.backlog.totalBytes;

  @override
  Future<void> type(String hostSessionId, String text) async {
    final session = registry.find(hostSessionId);
    if (session == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'this session is not running on this machine',
      );
    }
    if (session.lifecycle.hasEnded) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session has ended; resume it from the desktop app',
      );
    }
    final refusal = session.token.claim(kCompanionWriterId, _now());
    if (refusal != null) {
      throw RemoteApiRefusal(ErrorCode.badRequest, refusal.message);
    }
    try {
      _write(session, text);
      await Future<void>.delayed(enterDelay);
      if (!session.lifecycle.hasEnded) _write(session, '\r');
    } finally {
      session.token.release(kCompanionWriterId);
    }
  }

  void _write(HostSession session, String text) {
    final refusal = session.write(
      kCompanionWriterId,
      utf8.encode(text),
      _now(),
    );
    if (refusal != null) {
      throw RemoteApiRefusal(ErrorCode.badRequest, refusal.message);
    }
  }

  static HostedSessionView _view(HostSession session) => (
    hostSessionId: session.id,
    command: session.request.argv.join(' '),
    running: session.lifecycle is SessionRunning,
    exitCode: session.lifecycle.exitCode,
    startedAt: session.startedAt,
  );
}
