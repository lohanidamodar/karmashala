import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';
import '../application/remote_access_controller.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import '../pairing/pairing_relay_endpoints.dart';

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

  HostPairingSession? _session;
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
        setState(() => _error = 'Pairing could not start: $error');
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

  /// The 32 base32 characters as two typeable lines of four groups.
  static String _typedCodeLines(List<int> typedSecret) {
    final groups = PairingCode.groups(typedSecret);
    final half = groups.length ~/ 2;
    return '${groups.take(half).join('-')}\n${groups.skip(half).join('-')}';
  }

  static String _label(Capability capability) => switch (capability) {
    Capability.viewSessions => 'View sessions',
    Capability.readTranscript => 'Read transcripts',
    Capability.sendPrompt => 'Send prompts',
    Capability.approve => 'Answer approvals',
    Capability.receiveNotifications => 'Notifications',
    Capability.startSession => 'Start new sessions',
    Capability.addProject => 'Add projects',
    Capability.viewActivity => 'See what is running',
    Capability.sendAttachment => 'Send files',
  };

  /// The local-vs-internet relay tabs. With one endpoint there is nothing to
  /// choose, so no chrome at all — the dialog looks exactly as before.
  Widget? _endpointTabs(List<PairingRelayEndpoint> endpoints) {
    if (endpoints.length < 2) return null;
    final selected = _endpoint.clamp(0, endpoints.length - 1);
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < endpoints.length; i++)
          ButtonSegment<int>(
            value: i,
            icon: Icon(
              endpoints[i].kind == PairingRelayKind.local
                  ? AppIcons.linkSimple
                  : AppIcons.globe,
              size: Chrome.iconAction,
            ),
            label: Text(endpoints[i].label),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (choice) {
        setState(() => _endpoint = choice.first);
        // The shown code names the old relay; root a fresh one here.
        _begin();
      },
    );
  }

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
      // Scrolls rather than overflowing: a QR plus nine chips is taller than
      // a small window's dialog. Its own traversal group, so Tab walks the
      // chips, the tabs and the QR's buttons once before reaching Cancel.
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_paired == null) ...[
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
                      label: Text(_label(capability)),
                      selected: _granted.contains(capability),
                      onSelected: (value) => _toggle(capability, value),
                    ),
                ],
              ),
              const SizedBox(height: Insets.md),
              if (_endpointTabs(ref.watch(pairingRelayEndpointsProvider))
                  case final tabs?) ...[
                Center(child: tabs),
                const SizedBox(height: Insets.md),
              ],
            ],
            Center(child: _body(theme)),
          ],
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
              size: Chrome.iconHero,
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
            Icon(
              AppIcons.warning,
              size: Chrome.iconHero,
              color: theme.colorScheme.error,
            ),
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
        if (session.payload.typedSecret case final typed?) ...[
          const SizedBox(height: Insets.md),
          Text(
            'No camera? Type this code on the phone:',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
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
                letterSpacing: 1.5,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: Insets.sm),
        // The full QR payload, for a device that can paste. A Wrap, not a Row:
        // the two buttons overflow 340px in some locales and scales.
        Wrap(
          alignment: WrapAlignment.center,
          spacing: Insets.xs,
          children: [
            TextButton(
              onPressed: () => setState(() => _showCode = !_showCode),
              child: Text(_showCode ? 'Hide payload' : 'Show full payload'),
            ),
            OutlinedButton.icon(
              icon: Icon(_copied ? AppIcons.checkCircle : AppIcons.copy),
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
