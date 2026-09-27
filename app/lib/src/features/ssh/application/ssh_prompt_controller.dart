import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';

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

/// Something an SSH connection cannot decide alone and must ask a person.
/// Requests are values, not dialogs: a test can answer one without pumping a
/// frame. Most come from the **server's** connections ([ServerSshPrompt]);
/// the rest from this app's own pool, which still dials the terminal panes,
/// a deploy and a relay set-up.
sealed class SshPromptRequest {
  /// Identity for list keys — two prompts for the same host are still two
  /// prompts.
  final Object key = Object();

  /// Completed when the user answers, or when the UI goes away.
  bool get isAnswered;
}

/// "This host presented a key we have never seen. Trust it?" — this app's
/// own connection.
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

/// "This host needs a password / a passphrase for its key." — this app's
/// own connection.
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

/// A question one of the server's connections put to every window. Answered
/// with `ssh.answerPrompt`; the first window to answer wins, and [closed]
/// completes when it is over — here or elsewhere — so a dialog still showing
/// it can go.
final class ServerSshPrompt extends SshPromptRequest {
  ServerSshPrompt(this.opened);

  final SshPromptOpened opened;
  final Completer<void> _closed = Completer<void>();

  Future<void> get closed => _closed.future;

  @override
  bool get isAnswered => _closed.isCompleted;

  void _close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// The queue of questions SSH connections wait on: the server's, told on the
/// data link, and this app's own pool's. It keeps the safe default for its
/// own: an unrecognised host is **refused** whenever nothing is mounted to
/// show it. The server's are refused by the server when no window is there.
class SshPromptController extends Notifier<List<SshPromptRequest>> {
  SshPromptController({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('ssh.prompt');

  final AppLogger _logger;

  /// How many prompt hosts are mounted. Counted, not a bool, so a rebuild that
  /// mounts the new host before disposing the old never blocks an ask.
  int _mounted = 0;

  @override
  List<SshPromptRequest> build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.sshChanges.listen(_serverSaid);
    final links = client.connectionChanges.listen((connection) {
      // A link that dropped took its questions with it.
      if (connection.state != DataLinkState.connected) _closeServerPrompts();
    });
    ref.onDispose(() {
      unawaited(changes.cancel());
      unawaited(links.cancel());
    });
    return const [];
  }

  /// Whether a UI is present to show prompts. When false every ask is refused.
  bool get canAsk => _mounted > 0;

  /// Called by the widget that displays prompts when it is mounted.
  void attach() => _mounted++;

  /// Called when that widget goes away. Anything of this app's own queued is
  /// refused rather than left hanging on a dialog that no longer exists.
  void detach() {
    if (_mounted > 0) _mounted--;
    // The host widget's `dispose` can run after this provider was torn down —
    // the window closing takes both, in that order. Reading `state` then
    // throws, and there is no longer anyone to refuse a prompt to.
    if (!ref.mounted) return;
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

  /// Answers the server's question: [trust] for a host key, [secret] for a
  /// password or passphrase (null for cancelled). One another window answered
  /// first is already over; the server says so, and nothing more is done.
  Future<void> answerServer(
    ServerSshPrompt request, {
    bool? trust,
    String? secret,
  }) async {
    request._close();
    _dequeue(request);
    try {
      await ref
          .read(dataClientProvider)
          .send(
            SshAnswerPrompt(
              request.opened.promptId,
              trust: trust,
              secret: secret,
            ),
          );
    } on DataRefused catch (refusal) {
      _logger.info('An SSH question was already over: ${refusal.message}');
    }
  }

  void _serverSaid(SshChange change) {
    switch (change) {
      case final SshPromptOpened opened:
        if (state.any(
          (r) => r is ServerSshPrompt && r.opened.promptId == opened.promptId,
        )) {
          return;
        }
        state = [...state, ServerSshPrompt(opened)];
      case SshPromptClosed(:final promptId):
        final closing = [
          for (final r in state)
            if (r is ServerSshPrompt && r.opened.promptId == promptId) r,
        ];
        for (final r in closing) {
          r._close();
          _dequeue(r);
        }
      case SshConnectionChanged():
        break;
    }
  }

  void _closeServerPrompts() {
    final server = state.whereType<ServerSshPrompt>().toList();
    if (server.isEmpty) return;
    for (final r in server) {
      r._close();
    }
    state = [
      for (final r in state)
        if (r is! ServerSshPrompt) r,
    ];
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
    // The server's: another window may still answer it.
    ServerSshPrompt() => null,
  };
}

/// The app-wide prompt queue.
final sshPromptControllerProvider =
    NotifierProvider<SshPromptController, List<SshPromptRequest>>(
      SshPromptController.new,
    );
