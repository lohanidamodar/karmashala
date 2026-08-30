import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/remote_access_controller.dart';
import '../domain/paired_device.dart';
import '../pairing/host_pairing.dart';
import '../pairing/pairing_payload.dart';
import '../protocol.dart';
import 'qr_painter.dart';

/// The pairing dialog: what the phone may do, then the QR code, then the
/// confirmation that a phone proved the key and was stored.
class PairingDialog extends ConsumerStatefulWidget {
  const PairingDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const PairingDialog());

  @override
  ConsumerState<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends ConsumerState<PairingDialog> {
  /// Granted at pairing time; all five v1 capabilities by default.
  final Set<Capability> _granted = {...Capability.values};

  /// Saved in [initState]: `ref` is unusable inside [dispose].
  late final RemoteAccessController _access;

  HostPairingSession? _session;
  PairedDevice? _paired;
  String? _error;
  bool _copied = false;
  bool _showCode = false;

  @override
  void initState() {
    super.initState();
    _access = ref.read(remoteAccessControllerProvider);
    _begin();
  }

  @override
  void dispose() {
    if (_paired == null) {
      // The secret dies with the dialog.
      _access.cancelPairing();
    }
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _session = null;
      _paired = null;
      _error = null;
      _copied = false;
    });
    try {
      final session = await _access.beginPairing(
        capabilities: CapabilitySet.of(_granted),
      );
      if (!mounted) return;
      setState(() => _session = session);
      final device = await session.done;
      if (!mounted) return;
      setState(() => _paired = device);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PairingException catch (error) {
      if (mounted && _paired == null) setState(() => _error = error.message);
    }
  }

  /// A capability changed: the shown code no longer says what it grants, so
  /// it is spent and a fresh one is generated.
  void _toggle(Capability capability, bool granted) {
    setState(() {
      granted ? _granted.add(capability) : _granted.remove(capability);
    });
    _begin();
  }

  static String _label(Capability capability) => switch (capability) {
    Capability.viewSessions => 'View sessions',
    Capability.readTranscript => 'Read transcripts',
    Capability.sendPrompt => 'Send prompts',
    Capability.approve => 'Answer approvals',
    Capability.receiveNotifications => 'Notifications',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            AppIcons.deviceMobile,
            size: Chrome.iconTitle,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: Insets.sm),
          const Text('Pair a device'),
        ],
      ),
      // Scrolls rather than overflowing: a QR plus five chips is taller than
      // a small window's dialog.
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_paired == null) ...[
                Text(
                  'The phone may only do what you grant here. Scan with the '
                  'Chitragupta companion app.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Insets.sm),
                Wrap(
                  spacing: Insets.xs,
                  runSpacing: Insets.xs,
                  children: [
                    for (final capability in Capability.values)
                      FilterChip(
                        label: Text(_label(capability)),
                        selected: _granted.contains(capability),
                        onSelected: (value) => _toggle(capability, value),
                      ),
                  ],
                ),
                const SizedBox(height: Insets.md),
              ],
              Center(child: _body(theme)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_paired == null ? 'Cancel' : 'Done'),
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    final paired = _paired;
    if (paired != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.checkCircle,
              size: 40,
              color: SemanticColors.of(context).idle,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Paired with ${paired.name}',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.warning, size: 24, color: theme.colorScheme.error),
            const SizedBox(height: Insets.sm),
            Text(
              error,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: Insets.sm),
            OutlinedButton(onPressed: _begin, child: const Text('Try again')),
          ],
        ),
      );
    }
    final session = _session;
    if (session == null) {
      return const Padding(
        padding: EdgeInsets.all(Insets.xl),
        child: CircularProgressIndicator(),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The QR stays black-on-white in both themes: scanners want contrast.
        CustomPaint(
          size: const Size.square(320),
          painter: QrPainter(session.payload.encode()),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'One phone, once — the code expires in '
          '${kPairingTtl.inMinutes} minutes.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.sm),
        // The same payload, for when a camera won't cooperate: reveal it here
        // and type it into the phone's "Paste the code instead" screen (or
        // copy it for a device that can receive a paste).
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => setState(() => _showCode = !_showCode),
              child: Text(_showCode ? 'Hide code' : 'Show pairing code'),
            ),
            OutlinedButton.icon(
              icon: Icon(
                _copied ? AppIcons.checkCircle : AppIcons.copy,
                size: 16,
              ),
              label: Text(_copied ? 'Copied' : 'Copy'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: session.payload.encode()),
                );
                if (mounted) setState(() => _copied = true);
              },
            ),
          ],
        ),
        if (_showCode) ...[
          const SizedBox(height: Insets.xs),
          Container(
            padding: const EdgeInsets.all(Insets.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: SelectableText(
              session.payload.encode(),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
