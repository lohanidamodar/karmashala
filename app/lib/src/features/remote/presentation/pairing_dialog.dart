import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../ssh/application/ssh_failure.dart';
import '../application/pairing_in_progress.dart';
import '../application/remote_access_controller.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import '../pairing/pairing_relay_endpoints.dart';
import 'capability_labels.dart';

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
  /// Granted at pairing time; everything this build knows by default, and
  /// every one of them untickable before the code is generated.
  final Set<Capability> _granted = {...Capability.values};

  /// Saved in [initState]: `ref` is unusable inside [dispose].
  late final RemoteAccessController _access;

  PairingInProgress? _session;
  PairedDevice? _paired;
  String? _error;
  bool _copied = false;
  bool _showCode = false;

  /// Which relay endpoint tab the shown code is rooted in.
  int _endpoint = 0;

  /// Regenerating spends the old session, whose "pairing was cancelled" must
  /// not paint over the fresh code: only the newest attempt may touch state.
  int _beginSerial = 0;

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

  /// The endpoint the current tab names, or null when the list is empty.
  PairingRelayEndpoint? _selectedEndpoint() {
    final endpoints = ref.read(pairingRelayEndpointsProvider);
    if (endpoints.isEmpty) return null;
    return endpoints[_endpoint.clamp(0, endpoints.length - 1)];
  }

  Future<void> _begin() async {
    final serial = ++_beginSerial;
    setState(() {
      _session = null;
      _paired = null;
      _error = null;
      _copied = false;
    });
    final endpoint = _selectedEndpoint();
    if (endpoint == null && ref.read(pairingRelayEndpointsProvider).isEmpty) {
      // Every relay is switched off: a code nothing listens on cannot pair.
      if (mounted && serial == _beginSerial) {
        setState(() {
          _error =
              'No relay is switched on. Turn on the local relay or the '
              'hosted one in Remote access first.';
        });
      }
      return;
    }
    try {
      final session = await _access.beginPairing(
        capabilities: CapabilitySet.of(_granted),
        relay: endpoint?.url,
        relayIsLocal: endpoint?.kind == PairingRelayKind.local,
      );
      if (!mounted || serial != _beginSerial) return;
      setState(() => _session = session);
      final device = await session.done;
      if (!mounted || serial != _beginSerial) return;
      setState(() => _paired = device);
    } on StateError catch (error) {
      if (mounted && serial == _beginSerial) {
        setState(() => _error = error.message);
      }
    } on PairingException catch (error) {
      if (mounted && serial == _beginSerial && _paired == null) {
        setState(() => _error = error.message);
      }
    } on Object catch (error) {
      // Anything else would leave the spinner up for good.
      if (mounted && serial == _beginSerial && _paired == null) {
        setState(
          () =>
              _error = 'Pairing could not start: ${describeSshFailure(error)}',
        );
      }
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

  void _selectEndpoint(int index) {
    setState(() => _endpoint = index);
    // The shown code names the old relay; root a fresh one here.
    _begin();
  }

  Future<void> _copyPayload(PairingPayload payload) async {
    await Clipboard.setData(ClipboardData(text: payload.encode()));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoints = ref.watch(pairingRelayEndpointsProvider);
    final paired = _paired;
    final error = _error;
    final session = _session;
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
      // Scrolls rather than overflowing: a QR plus nine chips is taller than
      // a small window's dialog. Its own traversal group, so Tab walks the
      // chips, the tabs and the QR's buttons once before reaching Cancel.
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (paired == null) ...[
              Text(
                'The phone may only do what you grant here. Scan with the '
                'Karmashala companion app, or type the code.',
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
                      label: Text(capabilityLabel(capability)),
                      selected: _granted.contains(capability),
                      onSelected: (value) => _toggle(capability, value),
                    ),
                ],
              ),
              const SizedBox(height: Insets.md),
              // With one endpoint there is nothing to choose, so no chrome.
              if (endpoints.length > 1) ...[
                Center(
                  child: _RelayEndpointTabs(
                    endpoints: endpoints,
                    selected: _endpoint.clamp(0, endpoints.length - 1),
                    onSelected: _selectEndpoint,
                  ),
                ),
                const SizedBox(height: Insets.md),
              ],
            ],
            Center(
              child: switch ((paired, error, session)) {
                (final PairedDevice device, _, _) => _PairedView(
                  name: device.name,
                ),
                (_, final String message, _) => _PairingError(
                  message: message,
                  onRetry: _begin,
                ),
                (_, _, null) => const Padding(
                  padding: EdgeInsets.all(Insets.xl),
                  child: InlineSpinner(size: InlineSpinnerSize.large),
                ),
                (_, _, final PairingInProgress session) => _PairingCodeView(
                  payload: session.payload,
                  showPayload: _showCode,
                  copied: _copied,
                  onTogglePayload: () => setState(() => _showCode = !_showCode),
                  onCopy: () => _copyPayload(session.payload),
                ),
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(paired == null ? 'Cancel' : 'Done'),
        ),
      ],
    );
  }
}

/// The local-vs-internet relay tabs, for a list of two or more.
class _RelayEndpointTabs extends StatelessWidget {
  const _RelayEndpointTabs({
    required this.endpoints,
    required this.selected,
    required this.onSelected,
  });

  final List<PairingRelayEndpoint> endpoints;
  final int selected;
  final ValueChanged<int> onSelected;

  /// A box is named by whoever added it, and three segments share a narrow
  /// dialog: the tab says the start of the name and the tooltip all of it.
  static const _labelLimit = 14;

  static String _short(String label) => label.length <= _labelLimit
      ? label
      : '${label.substring(0, _labelLimit - 1)}…';

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < endpoints.length; i++)
          ButtonSegment<int>(
            value: i,
            icon: Icon(switch (endpoints[i].kind) {
              PairingRelayKind.local => AppIcons.linkSimple,
              PairingRelayKind.sshHost => AppIcons.terminal,
              PairingRelayKind.internet => AppIcons.globe,
            }, size: Chrome.iconAction),
            label: Text(_short(endpoints[i].label)),
            tooltip: endpoints[i].label,
          ),
      ],
      selected: {selected},
      onSelectionChanged: (choice) => onSelected(choice.first),
    );
  }
}

/// A phone proved the key and was stored.
class _PairedView extends StatelessWidget {
  const _PairedView({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.checkCircle,
            size: Chrome.iconHero,
            color: SemanticColors.of(context).idle,
          ),
          const SizedBox(height: Insets.sm),
          Text('Paired with $name', style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

/// Pairing could not start or was refused, with a way to try again.
class _PairingError extends StatelessWidget {
  const _PairingError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.warning,
            size: Chrome.iconHero,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: Insets.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: Insets.sm),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

/// The QR, the typeable code under it, and the full payload for a device that
/// can paste.
class _PairingCodeView extends StatelessWidget {
  const _PairingCodeView({
    required this.payload,
    required this.showPayload,
    required this.copied,
    required this.onTogglePayload,
    required this.onCopy,
  });

  final PairingPayload payload;
  final bool showPayload;
  final bool copied;
  final VoidCallback onTogglePayload;
  final VoidCallback onCopy;

  /// The side of the QR. Fixed: a scanner wants it big, and the dialog's
  /// narrow width holds it.
  static const qrSize = 320.0;

  /// The 32 base32 characters as two typeable lines of four groups.
  static String _typedCodeLines(List<int> typedSecret) {
    final groups = PairingCode.groups(typedSecret);
    final half = groups.length ~/ 2;
    return '${groups.take(half).join('-')}\n${groups.skip(half).join('-')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final encoded = payload.encode();
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The QR stays black-on-white in both themes: scanners want contrast.
        CustomPaint(
          size: const Size.square(qrSize),
          painter: QrPainter(encoded),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'One phone, once — the code expires in '
          '${kPairingTtl.inMinutes} minutes.',
          style: muted,
        ),
        if (payload.typedSecret case final typed?) ...[
          const SizedBox(height: Insets.md),
          Text('No camera? Type this code on the phone:', style: muted),
          const SizedBox(height: Insets.xs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            // Two rows of four groups: big enough to read across the room.
            child: SelectableText(
              _typedCodeLines(typed),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                letterSpacing: 1.5,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: Insets.sm),
        // A Wrap, not a Row: the two buttons overflow in some locales and
        // scales.
        Wrap(
          alignment: WrapAlignment.center,
          spacing: Insets.xs,
          children: [
            TextButton(
              onPressed: onTogglePayload,
              child: Text(showPayload ? 'Hide payload' : 'Show full payload'),
            ),
            OutlinedButton.icon(
              icon: Icon(copied ? AppIcons.checkCircle : AppIcons.copy),
              label: Text(copied ? 'Copied' : 'Copy'),
              onPressed: onCopy,
            ),
          ],
        ),
        if (showPayload) ...[
          const SizedBox(height: Insets.xs),
          Container(
            padding: const EdgeInsets.all(Insets.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: SelectableText(
              encoded,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
