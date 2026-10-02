import 'dart:async';
import '../../../core/util/failure_words.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/client.dart' show kNoHostedRelayMessage;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../remote/application/remote_access_controller.dart';
import '../../remote/application/remote_access_settings.dart';
import '../../settings/presentation/settings_notice.dart';
import '../application/companion_route_store.dart';
import '../data/ssh_client.dart';
import '../application/ssh_terminal_opener.dart';
import 'copyable_command.dart';
import 'host_deploy_failure_notice.dart';
import 'privileged_command_block.dart';

/// Invites a phone to one machine: proves the port, settles the route, asks the
/// host for a code, and shows what the phone needs — as one QR, and as values.
///
/// The address is the one this desktop connected with — a box cannot read its
/// own public address — and the code is the host's, minted on the machine the
/// phone will actually pair with. One implementation, opened from everywhere
/// the machine is shown.
class PairPhoneDialog extends ConsumerStatefulWidget {
  const PairPhoneDialog._({required this.host});

  final SshHost host;

  /// Codes this dialog fetches on its own after one expires. A dialog left
  /// open must not mint pairing windows on somebody's server all night.
  static const maxAutoRenewals = 2;

  static Future<void> show(BuildContext context, {required SshHost host}) =>
      showDialog<void>(
        context: context,
        builder: (_) => PairPhoneDialog._(host: host),
      );

  @override
  ConsumerState<PairPhoneDialog> createState() => _PairPhoneDialogState();
}

class _PairPhoneDialogState extends ConsumerState<PairPhoneDialog> {
  CompanionEndpoint? _endpoint;
  PairingWindow? _window;
  HostRoute? _route;
  String? _failure;

  /// The deploy that put no host on the machine, when that is the failure: a
  /// sentence, a remedy and an Install button rather than an exception's text.
  HostDeployment? _notDeployed;
  bool _busy = false;
  bool _showQr = false;
  bool _expired = false;
  int _autoRenewals = 0;

  /// Only the newest request may paint: a route change overtakes a slow one.
  int _serial = 0;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    // The dialog opens already working: everything it shows takes a round trip
    // to the machine, and a person who has just asked to pair a phone has not
    // got a second decision to make first.
    unawaited(_invite());
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// The relay a box is met at when it cannot be dialled: the one this desktop
  /// is configured with, so there is one hosted relay and one place to set it.
  Uri? get _hostedRelay =>
      hostedRelayOf(ref.read(remoteAccessSettingsProvider));

  Future<void> _invite({
    bool probe = true,
    bool ruleAddedByHand = false,
  }) async {
    final serial = ++_serial;
    _expiry?.cancel();
    setState(() {
      _busy = true;
      _failure = null;
      _notDeployed = null;
      _expired = false;
      // A QR is never carried over to a code it was not drawn from.
      _showQr = false;
      _window = null;
    });
    try {
      // Asked of the server, which reaches the box (slice 5d).
      final ssh = ref.read(sshClientProvider);
      CompanionEndpoint? endpoint = _endpoint;
      if (probe || endpoint == null) {
        final prepared = await ssh.companionEndpoint(
          widget.host.id,
          // Reopened after the terminal step: the rule is presumed added,
          // so a port still shut is not answered with the same command.
          ruleAddedByHand:
              ruleAddedByHand ||
              ref
                  .read(sudoTerminalsOpenedProvider.notifier)
                  .openedForPort(widget.host.id, kHostCompanionPort),
        );
        if (prepared.value == null) {
          if (mounted && serial == _serial) {
            setState(() => _notDeployed = prepared.deployment);
          }
          return;
        }
        endpoint = prepared.value!;
      }
      final route = routeFor(
        chosen: ref.read(companionRouteStoreProvider).read(widget.host.id),
        reachable: endpoint.reachable,
      );
      final hosted = _hostedRelay;
      if (route == HostRoute.relay && hosted == null) {
        // Nothing to meet at; the direct route stays choosable.
        if (mounted && serial == _serial) {
          setState(() {
            _endpoint = endpoint;
            _route = route;
            _failure = kNoHostedRelayMessage;
          });
        }
        return;
      }
      // Everything the phone is granted. A desktop that offered less than the
      // person chose would be deciding something nobody asked it to.
      final opened = await ssh.pairPhone(
        widget.host.id,
        capabilities: CapabilitySet.all.bits,
        relay: route == HostRoute.relay ? '$hosted' : '',
      );
      if (!mounted || serial != _serial) return;
      final window = opened.value;
      if (window == null) {
        setState(() => _notDeployed = opened.deployment);
        return;
      }
      setState(() {
        _endpoint = endpoint;
        _route = route;
        _window = window;
      });
      _armExpiry(window);
    } on Object catch (error) {
      if (mounted && serial == _serial) {
        setState(() => _failure = describeFailure(error));
      }
    } finally {
      if (mounted && serial == _serial) setState(() => _busy = false);
    }
  }

  /// The code and its QR leave the screen the moment the host stops honouring
  /// them, and a fresh one is fetched — hidden again — a bounded number of times.
  void _armExpiry(PairingWindow window) {
    final expiresAt = window.expiresAt;
    if (window.code == null || expiresAt == null) return;
    final left = expiresAt.toUtc().difference(ref.read(clockProvider).nowUtc());
    _expiry = Timer(left.isNegative ? Duration.zero : left, () {
      if (!mounted) return;
      setState(() {
        _window = null;
        _showQr = false;
        _expired = true;
      });
      if (_autoRenewals >= PairPhoneDialog.maxAutoRenewals) return;
      _autoRenewals++;
      unawaited(_invite(probe: false));
    });
  }

  void _chooseRoute(HostRoute route) {
    if (route == _route) return;
    chooseCompanionRoute(ref, widget.host.id, route);
    // The host attaches to the relay — or to nothing — when the window opens,
    // so the shown code belongs to the old route and is replaced.
    unawaited(_invite(probe: false));
  }

  HostPairingInvite? _inviteFor(
    CompanionEndpoint endpoint,
    PairingWindow window,
    HostRoute route,
  ) {
    final code = window.code;
    final expiresAt = window.expiresAt;
    if (code == null || expiresAt == null) return null;
    try {
      return HostPairingInvite(
        endpoint: endpoint.authority,
        code: code,
        hostName: widget.host.name,
        route: route,
        relay: route == HostRoute.relay ? _hostedRelay : null,
        expiresAt: expiresAt,
      );
    } on ArgumentError {
      // A loopback address, or a code this build cannot read: the values below
      // still say what is known, and a QR that cannot work is not drawn.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoint = _endpoint;
    final window = _window;
    final route = _route;
    return AlertDialog(
      title: Text('Pair a phone with ${widget.host.name}'),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (endpoint != null && route != null) ...[
              _RouteChoice(
                route: route,
                enabled: !_busy,
                onChanged: _chooseRoute,
              ),
              const SizedBox(height: Insets.xs),
              _RouteStory(route: route, relay: _hostedRelay),
              // Both readings, always: a code that works and a port that does
              // not is the failure somebody would otherwise chase in the phone.
              _Note(
                ok: endpoint.reachable,
                // Shut is only a warning on the relay route — it is why that
                // route was chosen — and the whole problem on the direct one.
                soft: route == HostRoute.relay,
                text: endpoint.reason,
              ),
              if (!_busy && !endpoint.reachable)
                if (endpoint.privileged case final step?)
                  PrivilegedCommandBlock(
                    host: widget.host,
                    step: step,
                    // Reopening this dialog dials again, which is the check.
                    closeDialogFirst: true,
                    onCheckAgain: () {
                      _autoRenewals = 0;
                      _invite(ruleAddedByHand: true);
                    },
                  )
                else if (endpoint.command case final command?)
                  CopyableCommand(command: command),
              const SizedBox(height: Insets.md),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Insets.lg),
                child: Row(
                  children: [
                    InlineSpinner(size: InlineSpinnerSize.medium),
                    SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        'Opening the port and asking the host for a code…',
                      ),
                    ),
                  ],
                ),
              )
            else if (_notDeployed case final deployment?)
              HostDeployFailureNotice(
                host: widget.host,
                deployment: deployment,
                closeDialogFirst: true,
                onInstalled: () {
                  _autoRenewals = 0;
                  _invite();
                },
              )
            else if (_failure != null)
              Text(
                _failure!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (_expired && window == null)
              const _Note(
                ok: false,
                soft: true,
                text:
                    'The code expired, so it and its QR were taken down. '
                    'Choose "New code" when the phone is in your hand.',
              )
            else if (endpoint != null && window != null && route != null)
              ..._invitation(context, endpoint, window, route),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  _autoRenewals = 0;
                  _invite();
                },
          child: const Text('New code'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  List<Widget> _invitation(
    BuildContext context,
    CompanionEndpoint endpoint,
    PairingWindow window,
    HostRoute route,
  ) {
    final theme = Theme.of(context);
    final code = window.code;
    if (code == null) {
      return [
        Text(
          window.reason,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ];
    }
    final invite = _inviteFor(endpoint, window, route);
    return [
      if (invite != null)
        _QrReveal(
          invite: invite,
          shown: _showQr,
          onToggle: () => setState(() => _showQr = !_showQr),
        )
      else
        const _Note(
          ok: false,
          soft: true,
          text:
              'No QR for this one: the address only means something on this '
              'computer, so a phone could not use it.',
        ),
      const SizedBox(height: Insets.md),
      Text(
        route == HostRoute.direct
            ? 'No camera? On the phone choose "Add a machine by address" and '
                  'enter:'
            : 'No camera? On the phone choose "Paste the code instead" and '
                  'paste the pairing link, or type the code:',
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: Insets.sm),
      if (route == HostRoute.direct) ...[
        _Copyable(label: 'Address', value: endpoint.authority),
        const SizedBox(height: Insets.sm),
      ],
      _Copyable(label: 'Code', value: code),
      if (route == HostRoute.relay && invite != null) ...[
        const SizedBox(height: Insets.xs),
        _CopyLink(invite: invite),
      ],
      if (window.expiresAt case final expiresAt?)
        _Note(
          ok: true,
          text:
              'One phone, once. The code stops working at '
              '${TimeOfDay.fromDateTime(expiresAt.toLocal()).format(context)}.',
        ),
    ];
  }
}

/// "Connect through: This host · Hosted relay". Two routes and no third: a box
/// is reached at itself, or met at the one hosted relay.
class _RouteChoice extends StatelessWidget {
  const _RouteChoice({
    required this.route,
    required this.enabled,
    required this.onChanged,
  });

  final HostRoute route;
  final bool enabled;
  final ValueChanged<HostRoute> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A Wrap: at the minimum window with bigger text the label goes above.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      children: [
        Text('Connect through', style: theme.textTheme.labelMedium),
        SegmentedButton<HostRoute>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: HostRoute.direct,
              icon: Icon(AppIcons.linkSimple, size: Chrome.iconAction),
              label: Text('This host'),
            ),
            ButtonSegment(
              value: HostRoute.relay,
              icon: Icon(AppIcons.globe, size: Chrome.iconAction),
              label: Text('Hosted relay'),
            ),
          ],
          selected: {route},
          onSelectionChanged: enabled
              ? (choice) => onChanged(choice.first)
              : null,
        ),
      ],
    );
  }
}

/// Who sees what on the chosen route, in one sentence.
class _RouteStory extends StatelessWidget {
  const _RouteStory({required this.route, required this.relay});

  final HostRoute route;
  final Uri? relay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      switch ((route, relay)) {
        (HostRoute.direct, _) =>
          'The phone dials this machine itself. Nothing else is involved.',
        (HostRoute.relay, null) => kNoHostedRelayMessage,
        (HostRoute.relay, final Uri relay) =>
          'The phone and this machine meet at ${relay.host}. Frames are sealed '
              'end to end; the relay sees both addresses, sizes and timing, '
              'and nothing inside.',
      },
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The QR, behind a button: whoever can see this screen could pair a phone
/// with the machine, so it is drawn only when somebody is ready to scan it.
class _QrReveal extends StatelessWidget {
  const _QrReveal({
    required this.invite,
    required this.shown,
    required this.onToggle,
  });

  final HostPairingInvite invite;
  final bool shown;
  final VoidCallback onToggle;

  /// Smaller than the desktop pairing's 320: this payload is a fifth the size,
  /// and the values sit under it in a window that may be 560 tall.
  static const qrSize = 220.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (shown)
            Semantics(
              label: 'Pairing QR code',
              image: true,
              child: CustomPaint(
                size: const Size.square(qrSize),
                painter: QrPainter(invite.encode()),
              ),
            )
          else
            Container(
              width: qrSize,
              height: qrSize / 2,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(
                AppIcons.qrCode,
                size: Chrome.iconHero,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: Insets.xs),
          OutlinedButton.icon(
            onPressed: onToggle,
            icon: Icon(shown ? AppIcons.eyeSlash : AppIcons.eye),
            label: Text(shown ? 'Hide QR' : 'Show QR'),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Scan it with the Karmashala companion: address, code and route '
            'in one go.',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The relay is part of the relay route, and a typed code does not carry one —
/// so a phone without a camera is offered the QR's own text, to paste.
class _CopyLink extends StatelessWidget {
  const _CopyLink({required this.invite});

  final HostPairingInvite invite;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () =>
            Clipboard.setData(ClipboardData(text: invite.encode())),
        icon: const Icon(AppIcons.copy),
        label: const Text('Copy pairing link'),
      ),
    );
  }
}

/// A value somebody has to get exactly right, so it is copyable rather than
/// retyped from a screen.
class _Copyable extends StatelessWidget {
  const _Copyable({required this.label, required this.value});

  final String label;
  final String value;

  /// The label column at 1x text; it grows with the text so "Address" still
  /// fits on its line when the user has made text bigger.
  static const labelWidth = 72.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: MediaQuery.textScalerOf(context).scale(labelWidth),
          child: Text(label, style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy ${label.toLowerCase()}',
          icon: const Icon(AppIcons.copy),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.ok, required this.text, this.soft = false});

  final bool ok;

  /// Not ok, and not the end of the road either.
  final bool soft;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: SettingsNotice(
        tone: ok
            ? SettingsNoticeTone.neutral
            : soft
            ? SettingsNoticeTone.attention
            : SettingsNoticeTone.danger,
        icon: ok ? AppIcons.checkCircle : AppIcons.warningCircle,
        message: text,
      ),
    );
  }
}
