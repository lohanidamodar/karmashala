import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_core/apps.dart';
import '../../../core/apps/installed_applications_providers.dart';

/// Picks one of the applications this desktop already lists, or `null` when the
/// user backs out. [what] completes "Choose …" and the empty-list sentence.
Future<InstalledApplication?> chooseInstalledApplication(
  BuildContext context, {
  required String what,
}) => showDialog<InstalledApplication>(
  context: context,
  builder: (context) => _ChooseApplicationDialog(what: what),
);

class _ChooseApplicationDialog extends ConsumerStatefulWidget {
  const _ChooseApplicationDialog({required this.what});

  final String what;

  @override
  ConsumerState<_ChooseApplicationDialog> createState() =>
      _ChooseApplicationDialogState();
}

class _ChooseApplicationDialogState
    extends ConsumerState<_ChooseApplicationDialog> {
  /// The list's height at its tallest; the dialog shrinks it to the window.
  static const _listHeight = 420.0;

  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final applications = ref.watch(installedApplicationsProvider);

    return AlertDialog(
      title: Text('Choose ${widget.what}'),
      content: SizedBox(
        width: DialogWidth.regular,
        height: _listHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                hintText: 'Search installed applications',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Insets.sm),
            Expanded(
              child: applications.when(
                loading: () => const Center(
                  child: InlineSpinner(size: InlineSpinnerSize.large),
                ),
                // The list is read, never assumed: a desktop that would not
                // answer says so rather than reading as a machine with nothing
                // installed on it.
                error: (error, _) => _Message(
                  'The list of installed applications could not be read '
                  '($error). Browse for the program instead.',
                ),
                data: (all) {
                  final matches = matchingApplications(all, _query.text);
                  if (all.isEmpty) {
                    return const _Message(
                      'Nothing was found in this desktop’s application list. '
                      'Browse for the program instead.',
                    );
                  }
                  if (matches.isEmpty) {
                    return _Message('Nothing matches “${_query.text}”.');
                  }
                  return ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final app = matches[index];
                      return ListTile(
                        dense: true,
                        title: Text(app.name),
                        subtitle: Text(
                          app.launchPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall,
                        ),
                        onTap: () => Navigator.of(context).pop(app),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => ref.invalidate(installedApplicationsProvider),
          icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
          label: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
