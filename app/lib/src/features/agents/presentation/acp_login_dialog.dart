import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpAuthMethod, DataRefused;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/acp_login_controller.dart';
import 'acp_login_method_tile.dart';

/// **Log in to an ACP agent**: the methods it advertises, read from the agent
/// itself. A terminal method opens a terminal tab on its machine, an API-key
/// method asks for the key first, any other asks the agent to
/// `authenticate`. Pops with the sentence to show, or null when cancelled.
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

  /// The API-key method waiting for its key.
  AcpAuthMethod? _keyFor;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _pick(AcpAuthMethod method) {
    if (method.apiKeyVariable != null) {
      setState(() {
        _keyFor = method;
        _error = null;
      });
      return;
    }
    _logIn(method);
  }

  Future<void> _logIn(AcpAuthMethod method, {String? apiKey}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final said = await ref
          .read(acpLoginActionsProvider)
          .logIn(widget.installationId, method, apiKey: apiKey);
      if (mounted) Navigator.of(context).pop(said);
    } on DataRefused catch (refusal) {
      if (mounted) setState(() => _error = refusal.message);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyFor = _keyFor;
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
            if (keyFor != null)
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
        if (_busy) const InlineSpinner(),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (keyFor != null)
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Log in'),
          ),
      ],
    );
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
                      onPick: _busy ? null : () => _pick(method),
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
