import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/environment_health.dart';

class EnvironmentHealthDialog extends ConsumerWidget {
  const EnvironmentHealthDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const EnvironmentHealthDialog(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(environmentHealthProvider);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(AppIcons.checkCircle, size: Chrome.iconTitle),
          SizedBox(width: Insets.sm),
          Text('Environment health'),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 420,
        child: health.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('$error')),
          data: (items) => items.isEmpty
              ? const Center(
                  child: Text('No execution environments configured.'),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final semantic = SemanticColors.of(context);
                    final color = switch (item.level) {
                      HealthLevel.healthy => semantic.idle,
                      HealthLevel.warning => semantic.attention,
                      HealthLevel.failed => semantic.failure,
                    };
                    return ListTile(
                      leading: Icon(
                        item.level == HealthLevel.healthy
                            ? AppIcons.checkCircle
                            : AppIcons.warningCircle,
                        color: color,
                      ),
                      title: Text(item.environment.name),
                      subtitle: Text(
                        [
                          item.summary,
                          ?item.gitVersion,
                          if (item.installations.isNotEmpty)
                            item.installations.map((i) => i.agentId).join(', '),
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                    );
                  },
                ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => ref.invalidate(environmentHealthProvider),
          icon: const Icon(AppIcons.arrowsClockwise),
          label: const Text('Check again'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
