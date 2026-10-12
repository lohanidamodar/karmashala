import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        AcpAuthMethod,
        AcpLoginProgress,
        DataRefused,
        kAcpAgentLoginPatience,
        kAcpLoginQuietPatience;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/acp_login_controller.dart';
import 'acp_login_method_tile.dart';
import 'acp_login_progress_view.dart';

/// **Log in to an ACP agent**: the methods it advertises, read from the agent
/// itself. A terminal method opens a terminal tab on its machine and waits
/// for it to end, an API-key method asks for the key first, any other asks
/// the agent to `authenticate`. While a login is under way it shows the
/// method, the link and code the agent gave, and Cancel; a login the agent
/// says nothing of for [kAcpLoginQuietPatience] is ended with Retry. Pops
/// with the sentence to show once logged in, or null when cancelled.
class AcpLoginDialog extends ConsumerStatefulWidget {
  const AcpLoginDialog({
    required this.installationId,
    required this.agentName,
    super.key,
  });

  final String installationId;
  final String agentName;

  /// What a person is told of what is kept: ACP v1 has no accounts.
  static const String methodsNote =
      'The agent tells Karmashala which way it was logged in, not as whom.';

  /// Said while the agent completes [method] itself, before it gave a link.
  static String waitingNote(String method) =>
      'Waiting for $method. If a browser opened, finish signing in there.';

  /// Said once the agent gave a link: how long the server waits on it.
  static String linkNote() =>
      'Waiting for you to finish signing in. The login ends after '
      '${kAcpAgentLoginPatience.inMinutes} minutes.';

  /// Said while a terminal login runs.
  static String terminalNote(String title) =>
      'Finish signing in in the terminal tab "$title". This continues when '
      'it ends.';

  /// Said when an agent gave no word for [kAcpLoginQuietPatience].
  static String quietNote(String agent, String method) =>
      '$agent said nothing for ${kAcpLoginQuietPatience.inMinutes} minutes '
      'after $method started (no link, no code), so the login was ended. If '
      'a browser opened on its machine, it may be waiting there.';

  static Future<String?> show(
    BuildContext context, {
    required String installationId,
    required String agentName,
  }) => showDialog<String>(
    context: context,
    builder: (_) =>
        AcpLoginDialog(installationId: installationId, agentName: agentName),
  );

  @override
  ConsumerState<AcpLoginDialog> createState() => _AcpLoginDialogState();
}

class _AcpLoginDialogState extends ConsumerState<AcpLoginDialog> {
  final _key = TextEditingController();
  late final AcpLoginActions _actions;
  StreamSubscription<AcpLoginProgress>? _progress;
  Timer? _quiet;

  /// The API-key method waiting for its key.
  AcpAuthMethod? _keyFor;

  /// The login under way, and what the agent has said of it.
  AcpAuthMethod? _doing;
  AcpLoginProgress? _heard;

  /// Each login is numbered: the answer to one already ended is dropped.
  int _attempt = 0;
  String? _error;

  /// The method a failed or quiet login can be retried with.
  AcpAuthMethod? _retry;

  bool get _busy => _doing != null;

  @override
  void initState() {
    super.initState();
    _actions = ref.read(acpLoginActionsProvider);
    _progress = _actions.progress(widget.installationId).listen(_onProgress);
  }

  @override
  void dispose() {
    if (_busy) unawaited(_cancelQuietly());
    _quiet?.cancel();
    unawaited(_progress?.cancel());
    _key.dispose();
    super.dispose();
  }

  Future<void> _cancelQuietly() async {
    try {
      await _actions.cancel(widget.installationId);
    } on Object {
      // The login ends at the server's own patience anyway.
    }
  }

  void _onProgress(AcpLoginProgress progress) {
    final doing = _doing;
    if (!mounted || doing == null || progress.methodId != doing.id) return;
    _quiet?.cancel();
    setState(() => _heard = progress);
  }

  void _pick(AcpAuthMethod method) {
    if (method.apiKeyVariable != null) {
      setState(() {
        _keyFor = method;
        _error = null;
        _retry = null;
      });
      return;
    }
    _logIn(method);
  }

  Future<void> _logIn(AcpAuthMethod method, {String? apiKey}) async {
    final attempt = ++_attempt;
    _quiet?.cancel();
    // Only a login the agent completes itself can go quiet: a terminal one
    // waits on a person typing, and a key is answered at once.
    if (!method.terminal && method.apiKeyVariable == null) {
      _quiet = Timer(kAcpLoginQuietPatience, () => _endQuiet(method, attempt));
    }
    setState(() {
      _doing = method;
      _heard = null;
      _error = null;
      _retry = null;
    });
    try {
      final said = await _actions.logIn(
        widget.installationId,
        method,
        apiKey: apiKey,
      );
      if (mounted && attempt == _attempt) Navigator.of(context).pop(said);
    } on Object catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _error = error is DataRefused ? error.message : '$error';
        _retry = method;
      });
    } finally {
      if (attempt == _attempt) _quiet?.cancel();
      if (mounted && attempt == _attempt) setState(() => _doing = null);
    }
  }

  void _endQuiet(AcpAuthMethod method, int attempt) {
    if (!mounted || attempt != _attempt || _heard != null) return;
    _attempt++;
    unawaited(_cancelQuietly());
    setState(() {
      _doing = null;
      _error = AcpLoginDialog.quietNote(widget.agentName, method.name);
      _retry = method;
    });
  }

  Future<void> _cancel() async {
    if (_busy) {
      _attempt++;
      _doing = null;
      await _cancelQuietly();
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final keyFor = _keyFor;
    final doing = _doing;
    final retry = _retry;
    final current = ref
        .watch(acpAuthStateProvider(widget.installationId))
        .asData
        ?.value
        ?.methodId;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.lockSimple,
        title: 'Log in to ${widget.agentName}',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: DesktopErrorBanner(error),
              ),
            if (doing != null)
              AcpLoginProgressView(
                method: doing,
                heard: _heard,
                note: _noteFor(doing),
              )
            else if (keyFor != null)
              _KeyField(method: keyFor, controller: _key, onSubmit: _submit)
            else
              _methods(current),
            const SizedBox(height: Insets.md),
            Text(
              AcpLoginDialog.methodsNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        if (!_busy && retry != null)
          FilledButton.icon(
            onPressed: () => _pick(retry),
            icon: const Icon(AppIcons.arrowClockwise, size: Chrome.iconAction),
            label: const Text('Retry'),
          )
        else if (!_busy && keyFor != null)
          FilledButton(onPressed: _submit, child: const Text('Log in')),
      ],
    );
  }

  String _noteFor(AcpAuthMethod method) {
    final heard = _heard;
    if (heard?.terminal case final title?) {
      return AcpLoginDialog.terminalNote(title);
    }
    if (heard?.link != null) return AcpLoginDialog.linkNote();
    return method.terminal
        ? 'Opening a terminal for ${method.name}…'
        : AcpLoginDialog.waitingNote(method.name);
  }

  void _submit() {
    final method = _keyFor;
    final key = _key.text.trim();
    if (method == null || key.isEmpty || _busy) return;
    _logIn(method, apiKey: key);
  }

  Widget _methods(String? current) => ref
      .watch(acpAuthMethodsProvider(widget.installationId))
      .when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: Insets.md),
          child: LinearProgressIndicator(),
        ),
        error: (error, _) => DesktopErrorBanner(
          'Could not read how ${widget.agentName} logs in: '
          '${error is DataRefused ? error.message : error}',
        ),
        data: (read) => read.methods.isEmpty
            ? Text('${widget.agentName} advertises no way to log in.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final method in read.methods)
                    AcpLoginMethodTile(
                      method: method,
                      current: method.id == current,
                      onPick: () => _pick(method),
                    ),
                ],
              ),
      );
}

/// The key an API-key method reads, typed once and kept in the server's
/// vault under the variable the agent documents.
class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.method,
    required this.controller,
    required this.onSubmit,
  });

  final AcpAuthMethod method;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: true,
    obscureText: true,
    onSubmitted: (_) => onSubmit(),
    decoration: InputDecoration(
      labelText: method.apiKeyVariable,
      helperText:
          'Kept in Variables and secrets on the server and handed to the '
          'agent for ${method.name}.',
      helperMaxLines: 2,
    ),
  );
}
