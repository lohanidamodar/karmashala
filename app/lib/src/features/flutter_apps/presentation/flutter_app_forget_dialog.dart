import 'package:flutter/material.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';

/// "Forget all not answering", said with how many it is. True to go ahead.
Future<bool> confirmForgetAll(BuildContext context, int count) =>
    showConfirmDialog(
      context,
      title: count == 1
          ? 'Forget 1 app that does not answer?'
          : 'Forget $count apps that do not answer?',
      message:
          'They leave the list. A run that starts again is found again; an '
          'address typed by hand has to be attached again.',
      confirmLabel: 'Forget $count',
      destructive: true,
    );

/// Several of [apps] picked to forget together: every one checked to start,
/// unchecked one by one. The ids picked, or null when nothing was forgotten.
Future<Set<String>?> chooseAppsToForget(
  BuildContext context,
  List<AttachedApp> apps, {
  required String Function(AttachedApp app) detailOf,
}) => showAdaptiveModal<Set<String>>(
  context: context,
  title: 'Forget apps that do not answer',
  builder: (_) => ForgetAppsChecklist(apps: apps, detailOf: detailOf),
);

/// The checklist and its "Forget N". Public so a test can pump it alone.
class ForgetAppsChecklist extends StatefulWidget {
  const ForgetAppsChecklist({
    required this.apps,
    required this.detailOf,
    super.key,
  });

  final List<AttachedApp> apps;
  final String Function(AttachedApp app) detailOf;

  @override
  State<ForgetAppsChecklist> createState() => _ForgetAppsChecklistState();
}

class _ForgetAppsChecklistState extends State<ForgetAppsChecklist> {
  late final Set<String> _picked = {for (final app in widget.apps) app.id};

  bool get _all => _picked.length == widget.apps.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _picked.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const ValueKey('forget-select-all'),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          // Some picked is neither all nor none, and the box says so.
          tristate: true,
          value: _all ? true : (count == 0 ? false : null),
          onChanged: (_) => setState(() {
            if (_all) {
              _picked.clear();
            } else {
              _picked.addAll(widget.apps.map((app) => app.id));
            }
          }),
          title: Text(
            'All ${widget.apps.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Divider(height: 1),
        for (final app in widget.apps)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: _picked.contains(app.id),
            onChanged: (on) => setState(
              () => on ?? false ? _picked.add(app.id) : _picked.remove(app.id),
            ),
            title: Text(
              app.label ?? app.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            subtitle: Text(
              widget.detailOf(app),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: Insets.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              DestructiveButton(
                icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
                onPressed: count == 0
                    ? null
                    : () => Navigator.of(context).pop(Set<String>.of(_picked)),
                child: Text('Forget $count'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
