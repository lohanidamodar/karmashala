import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ssh/connection.dart';

/// What a connection that needs a person fails with when no desktop client
/// is connected to ask.
String nobodyToAsk(SshHost host, String what) =>
    '${host.address} needs $what, and no Karmashala window is connected to '
    'ask for it. Open Karmashala on any device connected to this server and '
    'try again.';

/// **The questions the server's SSH connections put to a person** — an
/// unknown host key, a password, a key passphrase. The connection is the
/// server's; the question is UI, so it is told to every desktop client
/// ([SshPromptOpened]) and the first `ssh.answerPrompt` wins; the rest are
/// told it closed. With nobody connected it is not asked at all: the
/// connection fails in words saying where to answer ([nobodyToAsk]).
///
/// A secret is handed to the connection that asked, once, and kept nowhere:
/// not in a change, a log line or this object once answered.
class SshPrompts {
  SshPrompts({
    required this.tell,
    required this.canAsk,
    this.wait = const Duration(minutes: 5),
  });

  /// Tells every desktop client.
  final void Function(List<DataChange> changes) tell;

  /// Whether a desktop client is connected to show a prompt.
  final bool Function() canAsk;

  /// How long a question stays open before it is refused.
  final Duration wait;

  final _open = <String, _Prompt>{};
  var _last = 0;

  /// Every prompt still waiting, for a client that connects late.
  List<SshPromptOpened> get open => [for (final p in _open.values) p.opened];

  /// Asks whether to trust [presentation], an unknown key [host] presented.
  /// Any other verdict is refused without asking: a changed key is never a
  /// question. Throws [SshConnectionException] when nobody can be asked.
  Future<bool> askHostKey(
    SshHost host,
    HostKeyPresentation presentation,
  ) async {
    if (presentation.verdict != HostKeyVerdict.unknown) return false;
    final answer = await _ask(
      host,
      SshPromptKind.hostKey,
      'its host key trusted (${presentation.keyType} '
      '${presentation.fingerprint})',
      presentation: presentation,
    );
    return answer.trust ?? false;
  }

  /// Asks for [host]'s password or its key's passphrase; null is "cancelled".
  /// Throws [SshConnectionException] when nobody can be asked.
  Future<String?> askSecret(SshHost host, SshPromptKind kind) async {
    final answer = await _ask(
      host,
      kind,
      kind == SshPromptKind.password ? 'a password' : 'a key passphrase',
    );
    return answer.secret;
  }

  /// Answers [request]'s prompt. Refused `notFound` when it is over already
  /// — answered by another client, or given up on.
  void answer(SshAnswerPrompt request) {
    final prompt = _open.remove(request.promptId);
    if (prompt == null) {
      throw const DataRefused.notFound(
        'that question is no longer open — another window answered it, or '
        'the connection gave up',
      );
    }
    prompt.timer.cancel();
    prompt.done.complete((trust: request.trust, secret: request.secret));
    tell([SshPromptClosed(prompt.opened.promptId)]);
  }

  /// Refuses every open prompt: the server is stopping.
  void close() {
    for (final prompt in _open.values) {
      prompt.timer.cancel();
      prompt.done.complete((trust: false, secret: null));
    }
    _open.clear();
  }

  Future<({bool? trust, String? secret})> _ask(
    SshHost host,
    SshPromptKind kind,
    String what, {
    HostKeyPresentation? presentation,
  }) {
    if (!canAsk()) {
      throw SshConnectionException(nobodyToAsk(host, what));
    }
    final id = 'ssh-prompt-${++_last}';
    final opened = SshPromptOpened(
      promptId: id,
      hostId: host.id,
      hostName: host.name,
      address: host.address,
      kind: kind,
      presentation: presentation,
    );
    final done = Completer<({bool? trust, String? secret})>();
    final timer = Timer(wait, () {
      if (_open.remove(id) == null) return;
      done.complete((trust: false, secret: null));
      tell([SshPromptClosed(id)]);
    });
    _open[id] = _Prompt(opened, done, timer);
    tell([opened]);
    return done.future;
  }
}

class _Prompt {
  _Prompt(this.opened, this.done, this.timer);

  final SshPromptOpened opened;
  final Completer<({bool? trust, String? secret})> done;
  final Timer timer;
}
