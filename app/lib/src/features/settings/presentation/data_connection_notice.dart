import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../terminal/application/local_host_providers.dart';
import 'settings_notice.dart';

/// Says so when notes, todos and settings cannot reach the Karmashala server:
/// it is starting, or it is not running and why, with Retry. Nothing while
/// connected. Shown where that data is — the Notes and Todos panels and
/// Settings — since the app never keeps it itself.
class DataConnectionNotice extends ConsumerWidget {
  const DataConnectionNotice({
    this.padding = const EdgeInsets.only(bottom: Insets.sm),
    super.key,
  });

  /// Around the notice when it is shown; nothing is drawn otherwise.
  final EdgeInsets padding;

  /// Under a panel's header.
  static const inPanel = EdgeInsets.fromLTRB(
    Insets.sm,
    Insets.xs,
    Insets.sm,
    Insets.xs,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(dataClientProvider);
    final connection =
        ref.watch(dataConnectionProvider).value ?? client.connection;
    final message = dataConnectionText(connection);
    if (message == null) return const SizedBox.shrink();
    final unavailable = connection.state == DataLinkState.unavailable;
    return Padding(
      padding: padding,
      child: SettingsNotice(
        key: const ValueKey('data_connection_notice'),
        tone: unavailable
            ? SettingsNoticeTone.danger
            : SettingsNoticeTone.attention,
        icon: AppIcons.warning,
        message: message,
        action: unavailable
            ? TextButton(
                key: const ValueKey('data_connection_retry'),
                onPressed: () => _retry(ref, client),
                child: const Text('Retry'),
              )
            : null,
      ),
    );
  }

  /// Starts the server again when it is down, and dials it now.
  void _retry(WidgetRef ref, DataClient client) {
    client.retry();
    if (ref.read(localHostSessionAccessProvider) == null) return;
    unawaited(
      ref
          .read(localHostStatusProvider.notifier)
          .start()
          .whenComplete(client.retry),
    );
  }
}

/// The sentence for [connection], or null when there is nothing to say.
String? dataConnectionText(DataConnection connection) =>
    switch (connection.state) {
      DataLinkState.connected => null,
      DataLinkState.connecting =>
        'Starting the Karmashala server… Notes, todos and settings changes '
            'wait for it.',
      DataLinkState.unavailable =>
        'The Karmashala server isn\'t running: '
            '${connection.reason ?? 'no reason given'}. Notes, todos and '
            'settings are unavailable until it is.',
    };
