part of '../approval_request_card.dart';

/// **The answers an ACP agent offered to its own permission request**, in its
/// words and order — allow once, allow always, reject once, reject always —
/// each choosing exactly that option (`ApprovalAnswerRequest.optionId`).
class _PermissionOptions extends ConsumerStatefulWidget {
  const _PermissionOptions({
    required this.sessionId,
    required this.report,
    required this.options,
    required this.command,
  });

  final String sessionId;
  final AgentStatusReport report;
  final List<AgentToolAskOption> options;
  final Widget? command;

  @override
  ConsumerState<_PermissionOptions> createState() =>
      _PermissionOptionsState();
}

class _PermissionOptionsState extends ConsumerState<_PermissionOptions> {
  bool _busy = false;

  Future<void> _choose(AgentToolAskOption option) async {
    if (_busy) return;
    final answers = ref.read(sessionPromptAnswersProvider);
    final messenger = ScaffoldMessenger.of(context);
    final said = _AnswerSaid.of(context);
    setState(() => _busy = true);
    try {
      await answers.answer(
        ApprovalAnswerRequest(
          sessionId: widget.sessionId,
          approve: option.allows,
          optionId: option.id,
          ask: PromptAsk.drawnFrom(widget.report),
        ),
      );
      said?.say('${option.name}.');
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_approvalRefusalText(refusal, touch: said != null)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _effect(AgentToolAskOption option) => switch (option.kind) {
    'allow_once' => 'Lets the agent make this call.',
    'allow_always' =>
      'Lets the agent make this call, and calls like it from now on without '
          'asking.',
    'reject_once' => 'Refuses this call; the agent carries on without it.',
    'reject_always' => 'Refuses this call, and calls like it from now on.',
    _ => 'Answers with the agent\'s own "${option.name}".',
  };

  @override
  Widget build(BuildContext context) {
    final idle = !_busy;
    final primary = widget.options
        .where((o) => o.kind == 'allow_once')
        .firstOrNull;
    return _DockColumn(
      children: [
        ?widget.command,
        _DockButtonRow(
          sessionId: widget.sessionId,
          buttons: [
            for (final option in widget.options)
              _DockButton(
                key: ValueKey('dock-option-${option.id}'),
                label: option.name,
                tooltip: _effect(option),
                primary: identical(option, primary),
                onPressed: idle ? () => _choose(option) : null,
              ),
          ],
        ),
      ],
    );
  }
}
