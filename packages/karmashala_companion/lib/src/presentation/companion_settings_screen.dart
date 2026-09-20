import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_core/logging.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_session/resume.dart' show describeAge;
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_log_screen.dart';
import 'companion_states.dart';
import 'connections_section.dart';

/// The companion's settings: who this phone is paired with, whether the link
/// is up, what was granted, and the way out.
class CompanionSettingsScreen extends ConsumerWidget {
  const CompanionSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final pairing = ref.watch(companionPairingProvider).asData?.value;
    final link =
        ref.watch(companionLinkProvider).asData?.value ??
        CompanionLinkState.disconnected;
    final path = ref.watch(companionLinkPathProvider).asData?.value;
    // A phone keeps several relays and picks one per reconnect, so "Relay"
    // alone is not an answer.
    final relayHost = ref.read(companionGatewayProvider).activeRelay?.host;
    final since = ref.watch(companionLinkSinceProvider).asData?.value;
    final age = since == null
        ? null
        : ref.read(companionClockProvider).nowUtc().difference(since);

    // §19: every reading carries its age, worded for its state, and a state
    // nothing has stamped admits that rather than reading "just now".
    String withAge(String label) {
      if (age == null) return '$label · age unknown';
      return link == CompanionLinkState.disconnected
          ? '$label · since ${describeAge(age)}'
          : '$label · ${compactAge(age)}';
    }

    if (pairing == null) {
      // Only reachable in the moment after an unpair, which is exactly when a
      // relay may need changing before the next code is typed.
      return ListView(
        padding: companionListInsets(context, EdgeInsets.all(density.padX)),
        children: [
          Text('Not paired.', style: density.muted(theme)),
          const SizedBox(height: Insets.lg),
          const ConnectionsSection(),
          const SizedBox(height: Insets.lg),
          const _PairingRelayField(),
        ],
      );
    }

    final (linkIcon, linkLabel, linkColour) = switch (link) {
      // The direct socket skips the relay entirely, and that is worth seeing.
      CompanionLinkState.connected => (
        AppIcons.linkSimple,
        withAge(switch ((path, relayHost)) {
          (null, _) => 'Connected',
          (final p?, final host?) => 'Connected · ${p.label} ($host)',
          (final p?, _) => 'Connected · ${p.label}',
        }),
        SemanticColors.of(context).idle,
      ),
      CompanionLinkState.connecting => (
        AppIcons.arrowsClockwise,
        withAge('Connecting…'),
        SemanticColors.of(context).working,
      ),
      CompanionLinkState.disconnected => (
        AppIcons.linkBreak,
        withAge('Host unreachable'),
        SemanticColors.of(context).failure,
      ),
    };

    return ListView(
      // Capped at a phone's measure past the compact breakpoint, or a tablet
      // stretches these cards edge to edge (CLAUDE.md §6).
      padding: companionListInsets(context, EdgeInsets.all(density.padX)),
      children: [
        // The saved desktops first: every other row here is about which one
        // this phone is on.
        const ConnectionsSection(),
        const SizedBox(height: Insets.lg),
        const CompanionSectionHeader('THIS CONNECTION'),
        _ThisConnectionCard(
          hostName: pairing.hostName ?? 'Desktop',
          hostId: pairing.hostId?.value,
          linkIcon: linkIcon,
          linkLabel: linkLabel,
          linkColour: linkColour,
          grants: companionGrantsSentence(pairing.capabilities),
          onReconnect: link == CompanionLinkState.disconnected
              ? () => ref.read(companionGatewayProvider).reconnect()
              : null,
        ),
        const SizedBox(height: Insets.lg),
        const _PairingRelayField(),
        const SizedBox(height: Insets.lg),
        const _DiagnosticsRow(),
        const SizedBox(height: Insets.lg),
        Text(
          'Karmashala companion — a remote view of the sessions your '
          'desktop holds. The desktop is the source of truth; revoking this '
          'phone there cuts it off immediately.',
          style: density.muted(theme),
        ),
      ],
    );
  }
}

/// The desktop this phone is on: its name, the link and its age, its id, what
/// it granted, and — only while unreachable — a way to try again.
class _ThisConnectionCard extends StatelessWidget {
  const _ThisConnectionCard({
    required this.hostName,
    required this.linkIcon,
    required this.linkLabel,
    required this.linkColour,
    required this.grants,
    this.hostId,
    this.onReconnect,
  });

  final String hostName;
  final String? hostId;
  final IconData linkIcon;
  final String linkLabel;
  final Color linkColour;
  final String grants;

  /// Null hides the button: a link that is up or dialling needs no nudge.
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final hostId = this.hostId;
    final onReconnect = this.onReconnect;
    return Container(
      padding: EdgeInsets.all(density.padX),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(
          density.isTouch ? Radii.lg : Radii.sm,
        ),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.deviceMobile,
                size: density.icon,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
              Expanded(
                child: Text(
                  hostName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: density.title(theme),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // Its own line: beside the machine's name it overflowed the card at
          // phone width.
          Row(
            children: [
              Icon(linkIcon, size: density.iconSmall, color: linkColour),
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text(
                  linkLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted?.copyWith(
                    color: linkColour,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (hostId != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              'Host id: $hostId',
              style: muted?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ],
          const SizedBox(height: Insets.sm),
          Text('This phone may: $grants.', style: muted),
          if (onReconnect != null) ...[
            const SizedBox(height: Insets.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onReconnect,
                icon: const Icon(AppIcons.arrowsClockwise),
                label: const Text('Try to reconnect'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The relay a typed pairing code dials — the code itself carries only the
/// secret, so the relay must be this phone's own setting (default: the same
/// relay the desktop ships with). LAN pairing works even when it is wrong.
class _PairingRelayField extends ConsumerStatefulWidget {
  const _PairingRelayField();

  @override
  ConsumerState<_PairingRelayField> createState() => _PairingRelayFieldState();
}

class _PairingRelayFieldState extends ConsumerState<_PairingRelayField> {
  final _relay = TextEditingController();
  String? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await ref.read(companionGatewayProvider).pairingRelay();
    if (!mounted) return;
    setState(() {
      _relay.text = url.toString();
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  Future<void> _apply(String text) async {
    final gateway = ref.read(companionGatewayProvider);
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      // Empty returns to the default, and the field shows what that is.
      await gateway.setPairingRelay(null);
      if (!mounted) return;
      setState(() {
        _relay.text = kDefaultCompanionRelayUrl;
        _error = null;
      });
      return;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme) {
      setState(() => _error = 'Enter a full URL, like wss://relay.example.com');
      return;
    }
    await gateway.setPairingRelay(parsed);
    if (mounted) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CompanionSectionHeader('PAIRING RELAY'),
        TextField(
          controller: _relay,
          enabled: _loaded,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: _apply,
          onEditingComplete: () => _apply(_relay.text),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: kMonoFamily,
            fontFamilyFallback: kMonoFallback,
          ),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: kDefaultCompanionRelayUrl,
            helperText:
                'Used when pairing with a typed code (the QR names its own). '
                'Leave empty for the default.',
            helperMaxLines: 3,
            errorText: _error,
          ),
        ),
      ],
    );
  }
}

/// The way into the phone's own log, on this screen because it is wanted
/// exactly when the link is not working. Says the build version too: a phone
/// can be several releases behind the desktop it is talking to.
class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CompanionSectionHeader('DIAGNOSTICS'),
        Text(buildIdentity(), style: density.muted(theme)),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => CompanionLogScreen.show(context),
            icon: const Icon(AppIcons.article),
            label: const Text('View log'),
          ),
        ),
      ],
    );
  }
}
