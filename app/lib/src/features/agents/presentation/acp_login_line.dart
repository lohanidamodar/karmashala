import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpAuthState, DataRefused;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/acp_login_controller.dart';
import 'acp_login_dialog.dart';

/// What an ACP installation's row says of its login: the method remembered
/// — "logged in via" only once the agent confirmed it — with Log in, Switch
/// method and Forget. Never who: ACP v1 exposes no account.
class AcpLoginLine extends ConsumerWidget {
  const AcpLoginLine({
    required this.installationId,
    required this.agentName,
    this.machine,
    super.key,
  });

  final String installationId;
  final String agentName;

  /// The machine's name, when the row lists more than one.
  final String? machine;

  static String describe(AcpAuthState? state) => switch (state) {
    null => 'Not logged in through Karmashala',
    final s when s.confirmed => 'Logged in via ${s.methodName}',
    final s =>
      'Chose ${s.methodName}, finished in a terminal (the agent '
          'cannot confirm it here)',
  };

  Future<void> _logIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final said = await AcpLoginDialog.show(
      context,
      installationId: installationId,
      agentName: agentName,
    );
    if (said != null) messenger?.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await showConfirmDialog(
      context,
      title: 'Forget the login for $agentName?',
      message:
          'Karmashala stops using this method at the next start, and asks the '
          'agent to log out where it offers that.',
      confirmLabel: 'Forget',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await ref
          .read(acpLoginActionsProvider)
          .forget(installationId, logout: true);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(acpAuthStateProvider(installationId));
    final remembered = state.asData?.value;
    final words = state.hasError
        ? 'The remembered login could not be read'
        : describe(remembered);
    return Wrap(
      spacing: Insets.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          machine == null ? words : '$machine: $words',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton(
          onPressed: state.isLoading ? null : () => _logIn(context),
          child: Text(remembered == null ? 'Log in…' : 'Switch method…'),
        ),
        if (remembered != null)
          TextButton(
            onPressed: () => _forget(context, ref),
            child: const Text('Forget'),
          ),
      ],
    );
  }
}
