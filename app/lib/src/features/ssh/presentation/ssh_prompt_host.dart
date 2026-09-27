import 'package:flutter/material.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SshPromptKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/ssh_prompt_controller.dart';
import 'host_key_dialog.dart';
import 'ssh_secret_dialog.dart';

/// Mounts the SSH layer's ability to ask the user anything. Prompts are shown
/// one at a time: answering the wrong fingerprint is the failure to prevent.
class SshPromptHost extends ConsumerStatefulWidget {
  const SshPromptHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SshPromptHost> createState() => _SshPromptHostState();
}

class _SshPromptHostState extends ConsumerState<SshPromptHost> {
  /// Held rather than re-read: `ref` is not usable from `dispose`, and skipping
  /// the detach leaves waiting connections hanging on a queue nobody answers.
  late final SshPromptController _prompts;
  bool _showing = false;

  /// The server's question on screen now, if one is.
  ServerSshPrompt? _shownServer;

  @override
  void initState() {
    super.initState();
    _prompts = ref.read(sshPromptControllerProvider.notifier);
    _prompts.attach();
    WidgetsBinding.instance.addPostFrameCallback((_) => _drain());
  }

  @override
  void dispose() {
    _prompts.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sshPromptControllerProvider, (_, next) {
      final shown = _shownServer;
      if (shown != null && !next.contains(shown)) {
        // Answered in another window, or given up on: its dialog goes.
        _shownServer = null;
        Navigator.of(context, rootNavigator: true).pop();
      }
      _drain();
    });
    return widget.child;
  }

  Future<void> _drain() async {
    if (_showing) return;
    _showing = true;
    try {
      while (true) {
        if (!mounted) break;
        final queue = ref.read(sshPromptControllerProvider);
        if (queue.isEmpty) break;
        await _present(queue.first);
      }
    } finally {
      _showing = false;
    }
  }

  Future<void> _present(SshPromptRequest request) async {
    switch (request) {
      case HostKeyPromptRequest r:
        final trusted = await HostKeyTrustDialog.show(context, r.presentation);
        _prompts.answerHostKey(r, trusted: trusted);
      case SshSecretPromptRequest r:
        final secret = await SshSecretDialog.show(
          context,
          hostName: r.host.name,
          address: r.host.address,
          kind: r.kind,
        );
        _prompts.answerSecret(r, secret);
      case ServerSshPrompt r:
        await _presentServer(r);
    }
  }

  /// The server's question, until it is answered here or closed elsewhere —
  /// another window answered first, or the connection gave up ([build] takes
  /// the dialog down when it leaves the queue).
  Future<void> _presentServer(ServerSshPrompt request) async {
    final opened = request.opened;
    _shownServer = request;
    switch (opened.kind) {
      case SshPromptKind.hostKey:
        final presentation = opened.presentation;
        final trusted =
            presentation != null &&
            await HostKeyTrustDialog.show(context, presentation);
        if (!identical(_shownServer, request)) return;
        _shownServer = null;
        await _prompts.answerServer(request, trust: trusted);
      case SshPromptKind.password || SshPromptKind.passphrase:
        final secret = await SshSecretDialog.show(
          context,
          hostName: opened.hostName,
          address: opened.address,
          kind: opened.kind == SshPromptKind.password
              ? SshSecretKind.password
              : SshSecretKind.passphrase,
        );
        if (!identical(_shownServer, request)) return;
        _shownServer = null;
        await _prompts.answerServer(request, secret: secret);
    }
  }
}
