import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'connections_section.dart';

/// The companion's settings: who this phone is paired with, whether the link
/// is up, what was granted, and the way out.
class CompanionSettingsScreen extends ConsumerWidget {
  const CompanionSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final pairing = ref.watch(companionPairingProvider).asData?.value;
    final link =
        ref.watch(companionLinkProvider).asData?.value ??
        CompanionLinkState.disconnected;
    final path = ref.watch(companionLinkPathProvider).asData?.value;

    if (pairing == null) {
      // The shell shows the pairing flow before the tabs exist, so this is
      // only reachable in the moment after an unpair — exactly when a relay
      // may need changing before typing the next code.
      return ListView(
        padding: EdgeInsets.all(density.padX),
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
      // Which path carries the link matters at home: the direct socket skips
      // the relay entirely, and the user deserves to see that it did.
      CompanionLinkState.connected => (
        AppIcons.linkSimple,
        path == null ? 'Connected' : 'Connected · ${path.label}',
        SemanticColors.of(context).idle,
      ),
      CompanionLinkState.connecting => (
        AppIcons.arrowsClockwise,
        'Connecting…',
        SemanticColors.of(context).working,
      ),
      CompanionLinkState.disconnected => (
        AppIcons.linkBreak,
        'Host unreachable',
        SemanticColors.of(context).failure,
      ),
    };

    return ListView(
      padding: EdgeInsets.all(density.padX),
      children: [
        // The saved desktops first: which one this phone is on is the fact
        // every other row here is about.
        const ConnectionsSection(),
        const SizedBox(height: Insets.lg),
        Text('THIS CONNECTION', style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.sm),
        Container(
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
                      pairing.hostName ?? 'Desktop',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.title(theme),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              // Its own line: "Connected · Direct (LAN)" is a sentence, and
              // squeezing it beside the machine's name is what overflowed the
              // card at phone width.
              Row(
                children: [
                  Icon(linkIcon, size: density.iconSmall, color: linkColour),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      linkLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density
                          .muted(theme)
                          ?.copyWith(
                            color: linkColour,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              if (pairing.hostId != null) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  'Host id: ${pairing.hostId!.value}',
                  style: density
                      .muted(theme)
                      ?.copyWith(fontFamily: kMonoFamily),
                ),
              ],
              const SizedBox(height: Insets.sm),
              Text(
                'This phone may: '
                '${pairing.capabilities.granted.map((c) => c.wire.replaceAll('_', ' ')).join(', ')}.',
                style: density.muted(theme),
              ),
              if (link == CompanionLinkState.disconnected) ...[
                const SizedBox(height: Insets.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(companionGatewayProvider).reconnect(),
                    icon: const Icon(AppIcons.arrowsClockwise),
                    label: const Text('Try to reconnect'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Insets.lg),
        const _PairingRelayField(),
        const SizedBox(height: Insets.lg),
        Text(
          'Chitragupta companion — a remote view of the sessions your '
          'desktop holds. The desktop is the source of truth; revoking this '
          'phone there cuts it off immediately.',
          style: density.muted(theme),
        ),
      ],
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
        Text('PAIRING RELAY', style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.sm),
        TextField(
          controller: _relay,
          enabled: _loaded,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: _apply,
          onEditingComplete: () => _apply(_relay.text),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: kMonoFamily,
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
