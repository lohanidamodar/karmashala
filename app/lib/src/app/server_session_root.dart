import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../core/lifecycle/server_switcher.dart';
import '../core/util/failure_words.dart';

/// The window's root (plan step 14): the open server session's app under its
/// own container, keyed by the session so a switch builds a fresh tree and
/// nothing of the old server's widgets survives it — or, between sessions,
/// the switch's own screen.
class ServerSessionRoot extends StatelessWidget {
  const ServerSessionRoot({
    super.key,
    required this.switcher,
    required this.app,
  });

  final ServerSwitcher switcher;

  /// The app one server's container runs.
  final Widget app;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ServerRoot>(
    valueListenable: switcher.root,
    builder: (context, root, _) => switch (root) {
      ServingServer(:final session) => UncontrolledProviderScope(
        key: ObjectKey(session),
        container: session.container,
        child: app,
      ),
      SwitchingServer(:final name) => _BetweenServers(
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
        child: _OpenFailed(failure: root, switcher: switcher),
      ),
    },
  );
}

/// A bare app for the screens between sessions: no container is open, so
/// nothing here may read a provider.
class _BetweenServers extends StatelessWidget {
  const _BetweenServers({required this.child});

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
    final offerLocal = target != null && previous != null;
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
                child: Text('Back to ${serverNameForSwitch(previous)}'),
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
