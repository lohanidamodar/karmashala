import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../terminal/application/local_host_providers.dart';
import 'settings_notice.dart';

/// Says so when notes, todos and settings are not going through the
/// Karmashala server: it is reconnecting (writes wait), or it could not be
/// reached at launch and the temporary in-process fallback is writing the
/// database directly. Nothing while connected, or where no server can run.
class DataConnectionNotice extends ConsumerWidget {
  const DataConnectionNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(localHostSessionAccessProvider) == null) {
      return const SizedBox.shrink();
    }
    final connection =
        ref.watch(dataConnectionProvider).value ??
        ref.watch(dataClientProvider).connection;
    final message = dataConnectionText(connection);
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: SettingsNotice(
        tone: SettingsNoticeTone.attention,
        icon: AppIcons.warning,
        message: message,
      ),
    );
  }
}

/// The sentence for [connection], or null when there is nothing to say.
String? dataConnectionText(DataConnection connection) =>
    switch (connection.state) {
      DataLinkState.connected => null,
      DataLinkState.reconnecting =>
        'Reconnecting to the Karmashala server. Changes to notes, todos and '
            'settings wait for it.',
      DataLinkState.inProcess =>
        'The Karmashala server was not reachable at launch '
            '(${connection.reason ?? 'no reason given'}). Notes, todos and '
            'settings are read and written straight to its database until '
            'the app is restarted with the server running.',
    };
