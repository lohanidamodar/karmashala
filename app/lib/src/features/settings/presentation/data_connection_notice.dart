import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/server/remote_server_access.dart';
import '../../terminal/application/local_host_providers.dart';
import 'settings_notice.dart';

/// Says so when notes, todos and settings cannot reach the Karmashala server:
/// it is starting, or it is not running and why, with Retry; for a remote
/// server, the link is not up. Nothing while connected. Shown where that data
/// is — the Notes and Todos panels and Settings — since the app never keeps
/// it itself.
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
    final access = ref.watch(serverAccessProvider);
    final remote = access is RemoteServerAccess ? access : null;
    final message = dataConnectionText(
      connection,
      remoteHost: remote?.hostName,
    );
    if (message == null) return const SizedBox.shrink();
    if (remote == null) return _notice(ref, client, connection, message);
    // The phone shell's `RemoteResumingStrip` already says "Reconnecting…" or
    // "Not connected", with the reason and *Try again*: one notice, not two.
    final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
    if (compact && connection.state == DataLinkState.unavailable) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<bool>(
      valueListenable: remote.resuming,
      builder: (context, resuming, _) => compact && resuming
          ? const SizedBox.shrink()
          : _notice(ref, client, connection, message),
    );
  }

  Widget _notice(
    WidgetRef ref,
    DataClient client,
    DataConnection connection,
    String message,
  ) {
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

/// The sentence for [connection], or null when there is nothing to say. With
/// [remoteHost], the server is that machine's: this app neither starts it
/// nor knows it stopped, only that the link is not up.
String? dataConnectionText(DataConnection connection, {String? remoteHost}) =>
    switch ((connection.state, remoteHost)) {
      (DataLinkState.connected, _) => null,
      (DataLinkState.connecting, null) =>
        'Starting the Karmashala server… Notes, todos and settings changes '
            'wait for it.',
      (DataLinkState.connecting, final host?) =>
        'Connecting to $host… Notes, todos and settings changes wait for it.',
      (DataLinkState.unavailable, null) =>
        'The Karmashala server isn\'t running: '
            '${connection.reason ?? 'no reason given'}. Notes, todos and '
            'settings are unavailable until it is.',
      (DataLinkState.unavailable, final host?) =>
        'Not connected to $host: '
            '${connection.reason ?? 'no reason given'}. Notes, todos and '
            'settings are unavailable until it is reached.',
    };
