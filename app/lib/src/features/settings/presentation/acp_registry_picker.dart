import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_providers.dart';
import '../../agents/application/acp_install_controller.dart';

/// The registry's agents, filterable, each with the launch this machine would
/// use; one with no build for it is listed but cannot be picked.
class AcpRegistryPicker extends ConsumerStatefulWidget {
  const AcpRegistryPicker({
    required this.picked,
    required this.onPick,
    super.key,
  });

  final AcpRegistryEntry? picked;
  final ValueChanged<AcpRegistryEntry> onPick;

  @override
  ConsumerState<AcpRegistryPicker> createState() => _AcpRegistryPickerState();
}

class _AcpRegistryPickerState extends ConsumerState<AcpRegistryPicker> {
  final _filter = TextEditingController();

  /// Rows shown before the list scrolls, in row heights.
  static const double _listHeight = 5 * Chrome.menuRowTall;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(acpRegistryCatalogProvider);
    final platform = ref.watch(acpRegistryPlatformProvider);
    // By field, not by state: a value or an error is shown whatever else the
    // provider is doing.
    if (catalog.value case final value?) return _list(theme, value, platform);
    if (catalog.error case final error?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopErrorBanner(
            'The registry could not be fetched: $error. '
            'A custom agent can still be added.',
          ),
          const SizedBox(height: Insets.xs),
          // The fetch is one per dialog; this asks again without closing it.
          TextButton.icon(
            onPressed: () => ref.invalidate(acpRegistryCatalogProvider),
            icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
            label: const Text('Fetch again'),
          ),
        ],
      );
    }
    return Row(
      children: [
        const InlineSpinner(),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            'Fetching the registry…',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _list(ThemeData theme, AcpRegistryCatalog catalog, String platform) {
    if (catalog.agents.isEmpty) {
      return Text(
        'The registry lists no agents.',
        style: theme.textTheme.bodySmall,
      );
    }
    final query = _filter.text.trim().toLowerCase();
    final shown = [
      for (final entry in catalog.agents)
        if (query.isEmpty ||
            entry.label.toLowerCase().contains(query) ||
            (entry.description?.toLowerCase().contains(query) ?? false))
          entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _filter,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                  hintText: 'Filter agents',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            IconButton(
              tooltip: 'Fetch the registry again',
              icon: const Icon(
                AppIcons.arrowsClockwise,
                size: Chrome.iconAction,
              ),
              onPressed: () => ref.invalidate(acpRegistryCatalogProvider),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        SizedBox(
          height: _listHeight,
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    'No agent matches.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  primary: false,
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final entry = shown[index];
                    final launch = entry.launch;
                    final binary = acpInstallableBinary(entry, platform);
                    final detail = [
                      ?entry.version,
                      if (launch != null)
                        [launch.command, ...launch.args].join(' ')
                      else if (binary != null)
                        'installs ${acpArchiveName(binary)} on this machine'
                      else
                        'no build for this machine',
                    ].join(' · ');
                    final usable = launch != null || binary != null;
                    return ListTile(
                      key: ValueKey('acp-registry-${entry.id ?? index}'),
                      dense: true,
                      enabled: usable,
                      selected: identical(entry, widget.picked),
                      selectedTileColor: theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.4),
                      title: Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MonoStyles.small.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: usable ? () => widget.onPick(entry) : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
