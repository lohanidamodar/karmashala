import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/ssh_prompt_controller.dart';
import 'host_key_dialog.dart';
import 'ssh_secret_dialog.dart';

/// Mounts the SSH layer's ability to ask the user anything.
///
/// Wrapped around the app's home so that a connection started from *anywhere* —
/// a settings screen, a background agent discovery — can put a host key
/// fingerprint in front of the user. While this is mounted, an unknown host is
/// a question; while it is not, an unknown host is refused, which is exactly the
/// unattended behaviour Loop 37 chose.
///
/// Prompts are shown one at a time, in arrival order: two hosts connecting at
/// once must not race two dialogs onto the screen, and a user answering the
/// wrong fingerprint because it appeared under another is the failure mode this
/// whole feature exists to prevent.
class SshPromptHost extends ConsumerStatefulWidget {
  const SshPromptHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SshPromptHost> createState() => _SshPromptHostState();
}

class _SshPromptHostState extends ConsumerState<SshPromptHost> {
  /// Held rather than re-read: `ref` is not usable from `dispose`, and detaching
  /// is the step that must not be skipped — a queue nobody can answer would
  /// leave every waiting connection hanging.
  late final SshPromptController _prompts;
  bool _showing = false;

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
    ref.listen(sshPromptControllerProvider, (_, _) => _drain());
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
          host: r.host,
          kind: r.kind,
        );
        _prompts.answerSecret(r, secret);
    }
  }
}
