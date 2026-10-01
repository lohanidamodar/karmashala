import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/bare_app.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/lifecycle/server_switcher.dart';
import '../../../core/server/remote_server_access.dart';
import '../../../core/server/server_link.dart';
import '../../terminal/application/local_host_providers.dart';
import '../application/machines_providers.dart';

/// Shows [child], or — on a phone whose server refuses it the app (a pairing
/// the old companion made, Stage 1 step 12) — the page that says how to grant
/// it. The data link keeps redialling underneath, so a grant made on the
/// server is picked up without a press.
class PhoneGrantGate extends ConsumerWidget {
  const PhoneGrantGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(serverAccessProvider);
    final client = ref.watch(clientCapabilitiesProvider);
    if (access is! RemoteServerAccess || client.hostsServer) {
      return child;
    }
    return ValueListenableBuilder<bool>(
      valueListenable: access.needsGrant,
      builder: (context, needsGrant, _) {
        if (!needsGrant) return child;
        return BareApp(
          density: client.density,
          home: Scaffold(
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.xl),
                    child: PhoneGrantPage(hostName: access.hostName),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "This phone needs to be granted the app on `server`": the desktop's
/// **Grant**, or `karmashala_host grant <id> --add=phone`, then *Try again*.
class PhoneGrantPage extends ConsumerWidget {
  const PhoneGrantPage({super.key, required this.hostName});

  final String hostName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final server = hostName.isEmpty ? 'the server' : hostName;
    final deviceId = ref.watch(activeMachineProvider)?.deviceId.value;
    // Eight hex digits: `grant` takes any prefix only this device's id has.
    final prefix = deviceId == null || deviceId.length <= 8
        ? (deviceId ?? '<device>')
        : deviceId.substring(0, 8);
    final command = 'karmashala_host grant $prefix --add=phone';
    final switcher = ref.watch(serverSwitcherProvider);
    return SingleChildScrollView(
      child: Column(
        key: const Key('phone-grant'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This phone needs to be granted the app on $server',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: Insets.md),
          Text(
            'It is paired the way the old companion was, and $server has not '
            'let it use the Karmashala app yet. Nothing is granted on its '
            'own: allow it once, in either of these ways.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          Text('On $server\'s desktop', style: theme.textTheme.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(
            'Settings → Remote and pairing, then this phone\'s row → Grant.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          Text(
            'On a server with no desktop',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              Expanded(child: SelectableText(command, style: MonoStyles.label)),
              IconButton(
                tooltip: 'Copy the command',
                icon: const Icon(AppIcons.copy),
                onPressed: () =>
                    unawaited(Clipboard.setData(ClipboardData(text: command))),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'If the server does not know `phone`, it is older than this app: '
            'update it first.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.xl),
          Consumer(
            builder: (context, ref, _) {
              final checking =
                  ref.watch(serverLinkProvider).state ==
                  DataLinkState.connecting;
              return FilledButton(
                key: const Key('phone-grant-retry'),
                onPressed: checking ? null : ref.read(serverLinkRetryProvider),
                child: Text(checking ? 'Checking…' : 'Try again'),
              );
            },
          ),
          if (switcher != null) ...[
            const SizedBox(height: Insets.sm),
            OutlinedButton(
              onPressed: () => unawaited(switcher.switchTo(null)),
              child: const Text('Pair again instead'),
            ),
          ],
        ],
      ),
    );
  }
}
