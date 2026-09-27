import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';
import '../data/ssh_client.dart';

/// A question one of the server's SSH connections put to every window — an
/// unknown host key, a password, a key's passphrase (slice 3a). The app has
/// no connection of its own to ask about (slice 5d). Answered with
/// `ssh.answerPrompt`; the first window to answer wins, and [closed]
/// completes when it is over — here or elsewhere — so a dialog still showing
/// it can go.
final class ServerSshPrompt {
  ServerSshPrompt(this.opened);

  final SshPromptOpened opened;
  final Completer<void> _closed = Completer<void>();

  Future<void> get closed => _closed.future;

  bool get isAnswered => _closed.isCompleted;

  void _close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// The queue of the server's questions, told on the data link. The server
/// refuses one itself when no window is there to ask.
class SshPromptController extends Notifier<List<ServerSshPrompt>> {
  SshPromptController({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('ssh.prompt');

  final AppLogger _logger;

  @override
  List<ServerSshPrompt> build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.sshChanges.listen(_serverSaid);
    final links = client.connectionChanges.listen((connection) {
      // A link that dropped took its questions with it.
      if (connection.state != DataLinkState.connected) _closeAll();
    });
    ref.onDispose(() {
      unawaited(changes.cancel());
      unawaited(links.cancel());
    });
    return const [];
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
          .read(sshClientProvider)
          .answerPrompt(request.opened.promptId, trust: trust, secret: secret);
    } on DataRefused catch (refusal) {
      _logger.info('An SSH question was already over: ${refusal.message}');
    }
  }

  void _serverSaid(SshChange change) {
    switch (change) {
      case final SshPromptOpened opened:
        if (state.any((r) => r.opened.promptId == opened.promptId)) return;
        state = [...state, ServerSshPrompt(opened)];
      case SshPromptClosed(:final promptId):
        for (final r in [
          for (final r in state)
            if (r.opened.promptId == promptId) r,
        ]) {
          r._close();
          _dequeue(r);
        }
      case SshConnectionChanged():
        break;
    }
  }

  void _closeAll() {
    if (state.isEmpty) return;
    for (final r in state) {
      r._close();
    }
    state = const [];
  }

  void _dequeue(ServerSshPrompt request) {
    state = [
      for (final queued in state)
        if (!identical(queued, request)) queued,
    ];
  }
}

/// The app-wide prompt queue.
final sshPromptControllerProvider =
    NotifierProvider<SshPromptController, List<ServerSshPrompt>>(
      SshPromptController.new,
    );
