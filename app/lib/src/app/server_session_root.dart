import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../core/capabilities/capabilities.dart';
import '../core/lifecycle/server_switcher.dart';
import '../core/util/failure_words.dart';
import '../features/remote/presentation/pair_machine_page.dart';
import '../features/remote/presentation/phone_grant_page.dart';

/// The window's root (plan step 14): the open server session's app under its
/// own container, keyed by the session so a switch builds a fresh tree and
/// nothing of the old server's widgets survives it — or, between sessions,
/// the switch's own screen.
class ServerSessionRoot extends StatelessWidget {
  const ServerSessionRoot({
    super.key,
    required this.switcher,
    required this.app,
    required this.client,
  });

  final ServerSwitcher switcher;

  /// The app one server's container runs.
  final Widget app;

  /// This client, for the pairing [NoServer] shows.
  final ClientCapabilities client;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ServerRoot>(
    valueListenable: switcher.root,
    builder: (context, root, _) => switch (root) {
      ServingServer(:final session) => UncontrolledProviderScope(
        key: ObjectKey(session),
        container: session.container,
        child: PhoneGrantGate(child: app),
      ),
      // Keyed by kind: each screen gets its own Navigator, so a pairing
      // route pushed on NoServer's cannot stay on top of the switch after it.
      SwitchingServer(:final name) => _BetweenServers(
        key: const ValueKey('switching'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: Insets.lg),
            Text('Switching to $name…'),
          ],
        ),
      ),
      ServerOpenFailed() => _BetweenServers(
        key: const ValueKey('failed'),
        child: _OpenFailed(failure: root, switcher: switcher),
      ),
      NoServer() => _BetweenServers(
        key: const ValueKey('none'),
        child: PairMachinePage(
          title: 'Pair this phone with a machine',
          leading: _SavedMachines(switcher: switcher),
          pairer: MachinePairer(
            machines: switcher.machines,
            client: client,
            // This tree goes with the switch; nothing here is touched after.
            onPaired: (record) => unawaited(switcher.switchTo(record)),
          ),
        ),
      ),
    },
  );
}

/// A bare app for the screens between sessions: no container is open, so
/// nothing here may read a provider.
class _BetweenServers extends StatelessWidget {
  const _BetweenServers({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Karmashala',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// The machines already paired, each with Open: after "Pair again instead" or
/// a failed open, a saved pairing needs no new code. Nothing while none exist.
class _SavedMachines extends StatefulWidget {
  const _SavedMachines({required this.switcher});

  final ServerSwitcher switcher;

  @override
  State<_SavedMachines> createState() => _SavedMachinesState();
}

class _SavedMachinesState extends State<_SavedMachines> {
  late final Future<List<CompanionPairing>> _saved = widget.switcher.machines
      .remote()
      .catchError((Object _) => const <CompanionPairing>[]);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<CompanionPairing>>(
      future: _saved,
      builder: (context, snapshot) {
        final saved = snapshot.data ?? const <CompanionPairing>[];
        if (saved.isEmpty) return const SizedBox.shrink();
        return Column(
          key: const Key('saved-machines'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Paired machines', style: theme.textTheme.titleSmall),
            const SizedBox(height: Insets.xs),
            for (final record in saved)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        serverNameForSwitch(record),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    OutlinedButton(
                      onPressed: () =>
                          unawaited(widget.switcher.switchTo(record)),
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Insets.lg),
            Text('Or pair another', style: theme.textTheme.titleSmall),
            const SizedBox(height: Insets.xs),
          ],
        );
      },
    );
  }
}

/// Opening a server failed: what failed, and every way out — back to the
/// server in use before, another try, this computer's own, or Quit. Never a
/// window with nothing to press.
class _OpenFailed extends StatelessWidget {
  const _OpenFailed({required this.failure, required this.switcher});

  final ServerOpenFailed failure;
  final ServerSwitcher switcher;

  @override
  Widget build(BuildContext context) {
    final target = failure.target;
    final previous = failure.previous;
    final name = serverNameForSwitch(target);
    final backDiffers = previous?.hostId.value != target?.hostId.value;
    // Only a client with a server of its own has "this computer" to offer;
    // without one, null is the pairing screen.
    final offerLocal =
        switcher.hostsServer && target != null && previous != null;
    final back = previous == null && !switcher.hostsServer
        ? 'Back to pairing'
        : 'Back to ${serverNameForSwitch(previous)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Could not open $name',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: Insets.md),
        Flexible(
          child: SingleChildScrollView(
            child: SelectableText(describeFailure(failure.error)),
          ),
        ),
        const SizedBox(height: Insets.lg),
        Wrap(
          spacing: Insets.md,
          runSpacing: Insets.sm,
          children: [
            if (backDiffers)
              FilledButton(
                onPressed: () => unawaited(switcher.retry(previous)),
                child: Text(back),
              ),
            OutlinedButton(
              onPressed: () => unawaited(switcher.retry(target)),
              child: const Text('Try again'),
            ),
            if (offerLocal)
              OutlinedButton(
                onPressed: () => unawaited(switcher.retry(null)),
                child: const Text('Use this computer'),
              ),
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: 'Could not open $name.\n\n${failure.error}'),
              ),
              child: const Text('Copy details'),
            ),
            TextButton(
              onPressed: () => unawaited(switcher.quit()),
              child: const Text('Quit'),
            ),
          ],
        ),
      ],
    );
  }
}
