import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/wireless_pairing_controller.dart';

/// Which of Android's two pairing screens this dialog is talking to.
enum WirelessPairingMethod {
  qrCode('QR code'),
  pairingCode('Pairing code');

  const WirelessPairingMethod(this.label);
  final String label;
}

/// Pairs a phone over Wi-Fi, both ways Android offers. On the device toolbar
/// because a paired phone joins the same `adb devices` list — not a setting.
class WirelessPairingDialog extends ConsumerStatefulWidget {
  const WirelessPairingDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const WirelessPairingDialog(),
  );

  @override
  ConsumerState<WirelessPairingDialog> createState() =>
      _WirelessPairingDialogState();
}

class _WirelessPairingDialogState
    extends ConsumerState<WirelessPairingDialog> {
  WirelessPairingMethod _method = WirelessPairingMethod.qrCode;

  final _pairingAddress = TextEditingController();
  final _pairingCode = TextEditingController();
  final _connectAddress = TextEditingController();

  /// The host the last successful pair reported, so the connect field can be
  /// prefilled once rather than on every rebuild — the user may edit it.
  String? _prefilledFor;

  @override
  void initState() {
    super.initState();
    // After the first build, so the watch below is holding the controller
    // before it starts spawning anything.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_showQrCode());
    });
  }

  @override
  void dispose() {
    _pairingAddress.dispose();
    _pairingCode.dispose();
    _connectAddress.dispose();
    super.dispose();
  }

  WirelessPairingController get _controller =>
      ref.read(wirelessPairingProvider.notifier);

  Future<void> _showQrCode() => _controller.showQrCode();

  void _chooseMethod(WirelessPairingMethod method) {
    if (method == _method) return;
    setState(() => _method = method);
    // Leaving the QR behind spends its invite: a code nobody can see is a
    // secret with no purpose, and its poll would go on creating processes.
    _controller.cancel();
    if (method == WirelessPairingMethod.qrCode) unawaited(_showQrCode());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(wirelessPairingProvider);

    if (state is WirelessPairingPaired && _prefilledFor != state.host) {
      _prefilledFor = state.host;
      // A port, not an address: the phone shows both, and only the port
      // differs from what was just paired.
      _connectAddress.text = '${state.host}:';
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            AppIcons.wifiHigh,
            size: Chrome.iconTitle,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: Insets.sm),
          // Expanded, because a dialog title is `headlineSmall`: in a
          // phone-sized window a bare Text in a Row overflows rather than wraps.
          const Expanded(child: Text('Pair over Wi-Fi')),
        ],
      ),
      content: ConstrainedBox(
        // Bounded rather than fixed: at a phone-like window width a fixed 340
        // would overflow the dialog's own inset padding.
        constraints: const BoxConstraints(maxWidth: 340),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A `Wrap` of chips rather than a `SegmentedButton`: at 260 px
              // two labelled segments overflow by 124, and a Wrap takes a line.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: [
                  for (final method in WirelessPairingMethod.values)
                    ChoiceChip(
                      key: Key('wireless-pairing-method-${method.name}'),
                      avatar: Icon(
                        method == WirelessPairingMethod.qrCode
                            ? AppIcons.qrCode
                            : AppIcons.numpad,
                        size: Chrome.iconAction,
                      ),
                      label: Text(method.label),
                      selected: _method == method,
                      onSelected: (on) {
                        if (on) _chooseMethod(method);
                      },
                    ),
                ],
              ),
              const SizedBox(height: Insets.md),
              Text(
                _method == WirelessPairingMethod.qrCode
                    ? 'On the phone: Developer options → Wireless debugging → '
                          'Pair device with QR code, then point it at this.'
                    : 'On the phone: Developer options → Wireless debugging → '
                          'Pair device with pairing code, then copy what it '
                          'shows here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.md),
              if (_method == WirelessPairingMethod.pairingCode) ...[
                _codeForm(theme, state),
                const SizedBox(height: Insets.md),
              ],
              _outcome(theme, state),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            state is WirelessPairingConnected ? 'Done' : 'Cancel',
          ),
        ),
      ],
    );
  }

  /// The address-and-code form. Always on screen while its tab is chosen, so
  /// a failed attempt can be corrected where it was made.
  Widget _codeForm(ThemeData theme, WirelessPairingState state) {
    final busy = state is WirelessPairingBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('wireless-pairing-address'),
          controller: _pairingAddress,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'IP address & Port',
            helperText: 'From the pairing dialog, not the screen behind it',
            hintText: '192.168.1.24:41733',
          ),
        ),
        const SizedBox(height: Insets.sm),
        TextField(
          key: const Key('wireless-pairing-code'),
          controller: _pairingCode,
          enabled: !busy,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(
            labelText: 'Wi-Fi pairing code',
            hintText: '123456',
          ),
        ),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const Key('wireless-pairing-submit'),
            onPressed: busy
                ? null
                : () => unawaited(
                    _controller.pairWithCode(
                      address: _pairingAddress.text,
                      code: _pairingCode.text,
                    ),
                  ),
            child: const Text('Pair'),
          ),
        ),
      ],
    );
  }

  /// How big the QR may be drawn: off `MediaQuery`, since `AlertDialog` asks
  /// for intrinsic sizes. 128 is its chrome — 40 inset and 24 content a side.
  static double _qrSide(BuildContext context) =>
      (MediaQuery.sizeOf(context).width - 128).clamp(120.0, 260.0);

  Widget _outcome(ThemeData theme, WirelessPairingState state) => switch (state) {
    WirelessPairingIdle() => _method == WirelessPairingMethod.qrCode
        ? const _Working(label: 'Starting…')
        : const SizedBox.shrink(),
    WirelessPairingWatching(:final invite, :final scansLeft) => Column(
      children: [
        // Black on white in both themes: a camera wants contrast and many
        // scanners refuse an inverted QR. Never wider than the dialog.
        CustomPaint(
          key: const Key('wireless-pairing-qr'),
          size: Size.square(_qrSide(context)),
          painter: QrPainter(invite.encode()),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'Waiting for a phone to scan it — $scansLeft checks left.',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
    WirelessPairingBusy(:final step) => _Working(
      label: switch (step) {
        WirelessPairingStep.pairing => 'Pairing…',
        WirelessPairingStep.connecting => 'Connecting…',
      },
    ),
    WirelessPairingConnected(:final address) => _Verdict(
      icon: AppIcons.checkCircle,
      colour: SemanticColors.of(context).idle,
      message:
          'Connected to $address. It is in the device list with everything '
          'else.',
    ),
    WirelessPairingPaired(:final message) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Verdict(
          icon: AppIcons.warning,
          colour: theme.colorScheme.tertiary,
          message: message,
        ),
        const SizedBox(height: Insets.sm),
        TextField(
          key: const Key('wireless-pairing-connect-address'),
          controller: _connectAddress,
          decoration: const InputDecoration(
            labelText: 'IP address & Port',
            helperText: 'From the Wireless debugging screen itself',
          ),
        ),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const Key('wireless-pairing-connect'),
            onPressed: () =>
                unawaited(_controller.connectTo(_connectAddress.text)),
            child: const Text('Connect'),
          ),
        ),
      ],
    ),
    WirelessPairingFailed(:final message) => Column(
      children: [
        _Verdict(
          icon: AppIcons.warning,
          colour: theme.colorScheme.error,
          message: message,
        ),
        if (_method == WirelessPairingMethod.qrCode) ...[
          const SizedBox(height: Insets.sm),
          OutlinedButton(
            key: const Key('wireless-pairing-retry'),
            onPressed: () => unawaited(_showQrCode()),
            child: const Text('Try again'),
          ),
        ],
      ],
    ),
  };
}

class _Working extends StatelessWidget {
  const _Working({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
    child: Column(
      children: [
        InlineSpinner(size: InlineSpinnerSize.large, semanticsLabel: label),
        const SizedBox(height: Insets.sm),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}

class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.icon,
    required this.colour,
    required this.message,
  });

  final IconData icon;
  final Color colour;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, size: Chrome.iconHero, color: colour),
      const SizedBox(height: Insets.sm),
      Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
