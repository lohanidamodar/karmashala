import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/phone_more_page.dart' show phoneUsagePageOpener;
import '../../../app/shell/workbench_tabs.dart' show openUsageTab;
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'usage_tokens_card.dart';

/// **Usage & limits**, across every agent: what the numbers on the account
/// rows mean, the Usage tab for their history, and the token count over
/// recent sessions. The per-account bars live on each agent's card.
class UsageAndLimitsSection extends ConsumerWidget {
  const UsageAndLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSection(
      title: SettingsAnchor.usage.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'Usage belongs to the account, so machines signed in to one share '
            'its limits. The server reads each account on its own schedule; '
            'each terminal agent’s accounts show the latest reading.',
          ),
          SettingsRow(
            label: 'Usage over time',
            help:
                'Every account’s windows, their history, and what spent them.',
            control: OutlinedButton(
              onPressed: () {
                final phoneUsage = phoneUsagePageOpener(context, ref);
                if (phoneUsage != null) {
                  phoneUsage();
                } else {
                  openUsageTab(ref);
                }
              },
              child: const Text('Open Usage tab'),
            ),
          ),
          const UsageTokensCard(),
        ],
      ),
    );
  }
}
