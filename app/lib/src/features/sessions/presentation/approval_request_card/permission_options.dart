part of '../approval_request_card.dart';

/// **The answers an ACP agent offered to its own permission request**, in its
/// words and order — allow once, allow always, reject once, reject always —
/// each choosing exactly that option (`ApprovalAnswerRequest.optionId`).
class _PermissionOptions extends ConsumerStatefulWidget {
  const _PermissionOptions({
    required this.sessionId,
    required this.answers,
    required this.command,
  });

  final String sessionId;

  /// The agent's options, from [_openAnswers].
  final List<_OpenAnswer> answers;
  final Widget? command;

  @override
  ConsumerState<_PermissionOptions> createState() => _PermissionOptionsState();
}

class _PermissionOptionsState extends ConsumerState<_PermissionOptions> {
  bool _busy = false;

  Future<void> _choose(_OpenAnswer answer) async {
    if (_busy) return;
    final answers = ref.read(sessionPromptAnswersProvider);
    final messenger = ScaffoldMessenger.of(context);
    final said = _AnswerSaid.of(context);
    setState(() => _busy = true);
    try {
      await answers.answer(answer.request);
      said?.say(answer.said);
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(approvalRefusalText(refusal, touch: said != null)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final idle = !_busy;
    return _DockColumn(
      children: [
        ?widget.command,
        _DockButtonRow(
          sessionId: widget.sessionId,
          buttons: [
            for (final answer in widget.answers)
              _DockButton(
                key: ValueKey('dock-option-${answer.id}'),
                label: answer.label,
                tooltip: answer.tooltip,
                primary: answer.primary,
                onPressed: idle ? () => _choose(answer) : null,
              ),
          ],
        ),
      ],
    );
  }
}
