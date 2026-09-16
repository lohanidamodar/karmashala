import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/host_session_providers.dart';

/// Invites a phone to one machine: opens the port, asks the host for a code,
/// and shows both halves of what the phone needs.
///
/// Both halves, because a phone needs both and neither can be discovered. The
/// address is the one this desktop connected with — a box cannot read its own
/// public address — and the code is the host's, minted on the machine the phone
/// will actually pair with.
class PairPhoneDialog extends ConsumerStatefulWidget {
  const PairPhoneDialog._({required this.host});

  final SshHost host;

  static Future<void> show(BuildContext context, {required SshHost host}) =>
      showDialog<void>(
        context: context,
        builder: (_) => PairPhoneDialog._(host: host),
      );

  @override
  ConsumerState<PairPhoneDialog> createState() => _PairPhoneDialogState();
}

class _PairPhoneDialogState extends ConsumerState<PairPhoneDialog> {
  ({CompanionEndpoint endpoint, PairingWindow window})? _invitation;
  String? _failure;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The dialog opens already working: everything it shows takes a round trip
    // to the machine, and a person who has just asked to pair a phone has not
    // got a second decision to make first.
    unawaited(_invite());
  }

  Future<void> _invite() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final setup = await ref.read(sshCompanionSetupProvider(widget.host).future);
      // Everything the phone is granted. A desktop that offered less than the
      // person chose would be deciding something nobody asked it to.
      final result = await setup.invite(capabilities: CapabilitySet.all.bits);
      if (mounted) setState(() => _invitation = result);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invitation = _invitation;
    return AlertDialog(
      title: Text('Pair a phone with ${widget.host.name}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Insets.lg),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: Insets.sm),
                    Text('Opening the port and asking the host for a code…'),
                  ],
                ),
              )
            else if (_failure != null)
              Text(
                _failure!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (invitation != null) ...[
              Text(
                'On the phone, choose "Add a machine by address" and enter:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Insets.md),
              _Copyable(
                label: 'Address',
                value: invitation.endpoint.authority,
              ),
              const SizedBox(height: Insets.sm),
              if (invitation.window.code != null)
                _Copyable(label: 'Code', value: invitation.window.code!)
              else
                Text(
                  invitation.window.reason,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              const SizedBox(height: Insets.md),
              // Both readings, always: a code that works and a port that does
              // not is the failure somebody would otherwise chase in the phone.
              _Note(
                ok: invitation.endpoint.reachable,
                text: invitation.endpoint.reason,
              ),
              if (invitation.window.expiresAt != null)
                _Note(
                  ok: true,
                  text: 'The code stops working at '
                      '${TimeOfDay.fromDateTime(invitation.window.expiresAt!.toLocal()).format(context)}.',
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _invite,
          child: const Text('New code'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A value somebody has to get exactly right, so it is copyable rather than
/// retyped from a screen.
class _Copyable extends StatelessWidget {
  const _Copyable({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(width: 72, child: Text(label, style: theme.textTheme.labelMedium)),
        Expanded(
          child: SelectableText(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(AppIcons.copy),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? AppIcons.checkCircle : AppIcons.warningCircle,
            size: Chrome.iconSmall,
            color: ok
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
