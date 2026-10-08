part of '../approval_request_card.dart';

/// **An agent asking for a secret**, in the ask dock's amber panel: its label
/// and reason, a masked field, Save securely and Decline. The value goes to
/// the server once; the agent is given a single-use reference, never it.
/// Nothing at all while the session's agent is not asking.
class SecretRequestCard extends ConsumerWidget {
  const SecretRequestCard({
    required this.sessionId,
    this.touch = false,
    super.key,
  });

  final String sessionId;

  /// A phone's sizes: full-width answers at the touch target's height.
  final bool touch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(sessionSecretRequestsProvider(sessionId));
    if (requests.isEmpty) return const SizedBox.shrink();
    return _Docked(
      touch: touch,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final request in requests)
            _SecretAsk(
              key: ValueKey('secret-ask:${request.id}'),
              request: request,
            ),
        ],
      ),
    );
  }
}

class _SecretAsk extends ConsumerStatefulWidget {
  const _SecretAsk({required this.request, super.key});

  final SecretRequest request;

  @override
  ConsumerState<_SecretAsk> createState() => _SecretAskState();
}

class _SecretAskState extends ConsumerState<_SecretAsk> {
  final _value = TextEditingController();
  bool _visible = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _answer(Future<void> Function() send) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await send();
    } on DataRefused catch (refused) {
      if (mounted) setState(() => _error = refused.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() {
    final value = _value.text;
    if (value.isEmpty) {
      setState(() => _error = 'Enter the secret to save.');
      return Future.value();
    }
    return _answer(() async {
      await ref
          .read(secretRequestsProvider.notifier)
          .provide(widget.request.id, value);
      _value.clear();
    });
  }

  Future<void> _decline() => _answer(
    () => ref.read(secretRequestsProvider.notifier).decline(widget.request.id),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final density = UiDensity.of(context);
    final attention = SemanticColors.of(context).attention;
    final request = widget.request;
    final touch = _Docked.touchOf(context);
    final buttons = [
      _DockButton(
        key: const ValueKey('secret-save'),
        label: 'Save securely',
        primary: true,
        onPressed: _busy ? null : _save,
      ),
      _DockButton(
        key: const ValueKey('secret-decline'),
        label: 'Decline',
        onPressed: _busy ? null : _decline,
      ),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, _dockGap),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.md,
      ),
      decoration: BoxDecoration(
        color: tones.attentionSurface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: tones.attentionEdge,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: _DockColumn(
        children: [
          Row(
            children: [
              Icon(AppIcons.lockSimple, size: Chrome.icon, color: attention),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  'The agent asks for ${request.label}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: density.rowTitle(theme, strong: true),
                ),
              ),
              const SizedBox(width: Insets.sm),
              _WaitingFor(since: request.requestedAt),
            ],
          ),
          Text(request.reason, style: theme.textTheme.bodyMedium),
          TextField(
            key: const ValueKey('secret-value'),
            controller: _value,
            obscureText: !_visible,
            enableSuggestions: false,
            autocorrect: false,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              isDense: true,
              hintText: request.label,
              errorText: _error,
              errorMaxLines: 3,
              helperText:
                  'Kept by the Karmashala server. The agent gets a one-time '
                  'reference, never the value.',
              helperMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _visible ? 'Hide' : 'Show',
                icon: Icon(_visible ? AppIcons.eyeSlash : AppIcons.eye),
                onPressed: () => setState(() => _visible = !_visible),
              ),
            ),
          ),
          if (touch)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(height: Touch.gap),
                  buttons[i],
                ],
              ],
            )
          else
            Wrap(spacing: Insets.sm, runSpacing: 6, children: buttons),
        ],
      ),
    );
  }
}
