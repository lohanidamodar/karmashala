import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh/connection.dart';

/// Which secret a connection is asking for. Neither is ever persisted — both
/// are held for one connection attempt and then dropped.
enum SshSecretKind {
  password,
  passphrase;

  String get label => switch (this) {
    SshSecretKind.password => 'password',
    SshSecretKind.passphrase => 'key passphrase',
  };
}

/// Something the SSH layer cannot decide alone and must ask a human. Requests
/// are values, not dialogs: a test can answer one without pumping a frame.
sealed class SshPromptRequest {
  /// Identity for list keys — two prompts for the same host are still two
  /// prompts.
  final Object key = Object();

  /// Completed when the user answers, or when the UI goes away.
  bool get isAnswered;
}

/// "This host presented a key we have never seen. Trust it?"
final class HostKeyPromptRequest extends SshPromptRequest {
  HostKeyPromptRequest(this.presentation);

  final HostKeyPresentation presentation;
  final Completer<bool> _answer = Completer<bool>();

  Future<bool> get answer => _answer.future;

  @override
  bool get isAnswered => _answer.isCompleted;

  void complete(bool trusted) {
    if (!_answer.isCompleted) _answer.complete(trusted);
  }
}

/// "This host needs a password / a passphrase for its key."
final class SshSecretPromptRequest extends SshPromptRequest {
  SshSecretPromptRequest({required this.host, required this.kind});

  final SshHost host;
  final SshSecretKind kind;
  final Completer<String?> _answer = Completer<String?>();

  Future<String?> get answer => _answer.future;

  @override
  bool get isAnswered => _answer.isCompleted;

  void complete(String? secret) {
    if (!_answer.isCompleted) _answer.complete(secret);
  }
}

/// The queue of questions the SSH layer waits on. It keeps the safe default: an
/// unrecognised host is **refused** whenever nothing is mounted to show it.
class SshPromptController extends Notifier<List<SshPromptRequest>> {
  SshPromptController({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('ssh.prompt');

  final AppLogger _logger;

  /// How many prompt hosts are mounted. Counted, not a bool, so a rebuild that
  /// mounts the new host before disposing the old never blocks an ask.
  int _mounted = 0;

  @override
  List<SshPromptRequest> build() => const [];

  /// Whether a UI is present to show prompts. When false every ask is refused.
  bool get canAsk => _mounted > 0;

  /// Called by the widget that displays prompts when it is mounted.
  void attach() => _mounted++;

  /// Called when that widget goes away. Anything queued is refused rather than
  /// left hanging on a dialog that no longer exists.
  void detach() {
    if (_mounted > 0) _mounted--;
    if (_mounted == 0 && state.isNotEmpty) {
      for (final request in state) {
        _refuse(request);
      }
      state = const [];
    }
  }

  /// Asks the user whether to trust an unrecognised host key. Refuses without
  /// asking for any other verdict — a changed key is never a question.
  Future<bool> askHostKey(HostKeyPresentation presentation) {
    if (presentation.verdict != HostKeyVerdict.unknown) {
      _logger.error(
        'Refusing to prompt for a ${presentation.verdict.name} host key on '
        '${presentation.host}:${presentation.port}. ${presentation.describe()}',
      );
      return Future.value(false);
    }
    if (!canAsk) {
      _logger.warning(
        '${presentation.describe()} Refusing: no window is open to show the '
        'fingerprint, and an unknown host is never trusted unattended.',
      );
      return Future.value(false);
    }
    final request = HostKeyPromptRequest(presentation);
    state = [...state, request];
    return request.answer;
  }

  /// Asks the user for a password or a key passphrase.
  Future<String?> askSecret(SshHost host, SshSecretKind kind) {
    if (!canAsk) {
      _logger.warning(
        '${host.address} needs a ${kind.label} and no window is open to ask '
        'for one.',
      );
      return Future.value(null);
    }
    final request = SshSecretPromptRequest(host: host, kind: kind);
    state = [...state, request];
    return request.answer;
  }

  /// Records the user's decision and dequeues it. Accepting is what pins the
  /// key: the verifier writes `ssh_known_hosts` only after this returns true.
  void answerHostKey(HostKeyPromptRequest request, {required bool trusted}) {
    request.complete(trusted);
    _dequeue(request);
  }

  /// Records a secret (or `null` for "cancelled") and dequeues the request.
  void answerSecret(SshSecretPromptRequest request, String? secret) {
    request.complete(secret);
    _dequeue(request);
  }

  void _dequeue(SshPromptRequest request) {
    state = [
      for (final queued in state)
        if (!identical(queued, request)) queued,
    ];
  }

  void _refuse(SshPromptRequest request) => switch (request) {
    HostKeyPromptRequest r => r.complete(false),
    SshSecretPromptRequest r => r.complete(null),
  };
}

/// The app-wide prompt queue.
final sshPromptControllerProvider =
    NotifierProvider<SshPromptController, List<SshPromptRequest>>(
      SshPromptController.new,
    );
