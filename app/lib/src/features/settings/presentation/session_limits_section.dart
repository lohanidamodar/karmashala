import 'package:agent_cli/usage.dart' show usageAccountKey;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../environments/application/environments_controller.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/capacity_providers.dart';
import '../application/settings_controller.dart';
import 'agent_label.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'settings_theme.dart';

/// Settings → General → Session limits: how many agent sessions may run at
/// once — in all, per machine, per agent account, per project — and the
/// pause on new background work. Blank is no limit; the server holds them.
class SessionLimitsSection extends ConsumerWidget {
  const SessionLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limits = ref.watch(
      settingsControllerProvider.select((s) => s.launchLimits),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    final capacity = ref.watch(capacityNowProvider);
    final machines = ref.watch(environmentsControllerProvider);
    final installs = ref.watch(agentInstallationsControllerProvider);
    final projects = [
      for (final project in ref.watch(projectsControllerProvider))
        if (project.kind != 'scratch') project,
    ];
    final accounts = <String, String>{
      for (final install in installs)
        usageAccountKey(install):
            '${agentLabel(ref, install.agentId)} on '
            '${ref.watch(environmentLabelForIdProvider(install.environmentId))}',
    };
    String? used(CapacityScope scope, String key) {
      for (final use in capacity.scopes) {
        if (use.scope == scope && use.key == key) {
          return '${use.used} of ${use.limit} in use';
        }
      }
      return null;
    }

    void set(LaunchLimits next) => controller.setLaunchLimits(next);
    Map<String, int> put(Map<String, int> map, String key, int? value) => {
      for (final entry in map.entries)
        if (entry.key != key) entry.key: entry.value,
      key: ?value,
    };

    Widget group(String title) => Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      child: Text(title, style: SettingsStyles.sectionLabel(context)),
    );

    return SettingsSection(
      title: SettingsAnchor.sessionLimits.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(kLaunchSlotRule),
          SettingsRow(
            key: const ValueKey('limits-global'),
            label: 'All sessions',
            help:
                used(CapacityScope.global, '') ??
                'Blank is no limit. A lower limit never stops a session; '
                    'new starts wait.',
            control: CountField(
              value: limits.global,
              onChanged: (value) => set(limits.copyWith(global: () => value)),
            ),
            controlMaxWidth: CountField.widthOf(context),
            stackedFit: SettingsControlFit.start,
          ),
          SettingsSwitchRow(
            key: const ValueKey('limits-pause'),
            label: 'Pause new background work',
            help:
                'Automations, webhooks, scheduled resumes and sessions '
                'agents start wait until this is off. Running sessions '
                'carry on.',
            value: limits.pauseBackground,
            onChanged: controller.setBackgroundPaused,
          ),
          SettingsRow(
            key: const ValueKey('limits-hold'),
            label: 'Hold background work above this much of a 5-hour window',
            help:
                'Percent, per account. Blank is off. An account whose usage '
                'is unknown is never held.',
            control: CountField(
              value: limits.holdBackgroundAbovePercent,
              max: 100,
              onChanged: (value) =>
                  set(limits.copyWith(holdBackgroundAbovePercent: () => value)),
            ),
            controlMaxWidth: CountField.widthOf(context),
            stackedFit: SettingsControlFit.start,
          ),
          if (machines.isNotEmpty) group('Per machine'),
          for (final machine in machines)
            SettingsRow(
              key: ValueKey('limits-machine-${machine.id}'),
              label: ref.watch(environmentLabelForIdProvider(machine.id)),
              help: used(CapacityScope.machine, machine.id),
              control: CountField(
                value: limits.machines[machine.id],
                onChanged: (value) => set(
                  limits.copyWith(
                    machines: put(limits.machines, machine.id, value),
                  ),
                ),
              ),
              controlMaxWidth: CountField.widthOf(context),
              stackedFit: SettingsControlFit.start,
            ),
          if (accounts.isNotEmpty) group('Per agent account'),
          for (final account in accounts.entries)
            SettingsRow(
              key: ValueKey('limits-account-${account.key}'),
              label: account.value,
              help: used(CapacityScope.account, account.key),
              control: CountField(
                value: limits.accounts[account.key],
                onChanged: (value) => set(
                  limits.copyWith(
                    accounts: put(limits.accounts, account.key, value),
                  ),
                ),
              ),
              controlMaxWidth: CountField.widthOf(context),
              stackedFit: SettingsControlFit.start,
            ),
          if (projects.isNotEmpty) group('Per project'),
          for (final project in projects)
            SettingsRow(
              key: ValueKey('limits-project-${project.id}'),
              label: project.name,
              help: used(CapacityScope.project, project.id),
              control: CountField(
                value: limits.projects[project.id],
                onChanged: (value) => set(
                  limits.copyWith(
                    projects: put(limits.projects, project.id, value),
                  ),
                ),
              ),
              controlMaxWidth: CountField.widthOf(context),
              stackedFit: SettingsControlFit.start,
            ),
        ],
      ),
    );
  }
}

/// A compact field for a whole number from 1 to [max]; blank is none.
class CountField extends StatefulWidget {
  const CountField({
    required this.value,
    required this.onChanged,
    this.max = 999,
    super.key,
  });

  final int? value;
  final int max;
  final ValueChanged<int?> onChanged;

  /// Its width at the text size in force, so large text does not cut
  /// "No limit" short.
  static double widthOf(BuildContext context) => WidthClass.scaleBreakpoint(
    Chrome.countField,
    MediaQuery.textScalerOf(context),
  );

  @override
  State<CountField> createState() => _CountFieldState();
}

class _CountFieldState extends State<CountField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value?.toString() ?? '',
  );

  @override
  void didUpdateWidget(CountField old) {
    super.didUpdateWidget(old);
    final shown = int.tryParse(_text.text.trim());
    if (widget.value != shown) _text.text = widget.value?.toString() ?? '';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed(String raw) {
    final value = int.tryParse(raw.trim());
    widget.onChanged(
      value == null || value < 1 ? null : value.clamp(1, widget.max),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: CountField.widthOf(context),
    child: TextField(
      controller: _text,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(widget.max.toString().length),
      ],
      textAlign: TextAlign.end,
      style: SettingsStyles.control(context),
      decoration: const InputDecoration(isDense: true, hintText: 'No limit'),
      onChanged: _changed,
    ),
  );
}
