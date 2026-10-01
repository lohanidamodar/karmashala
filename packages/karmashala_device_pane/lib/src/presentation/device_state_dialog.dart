import 'package:flutter/material.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_ui/tokens.dart';

/// Applies one change and answers what the device said it did.
typedef DeviceStateApplier = Future<String> Function(DeviceStateChange change);

/// The system settings an app under test reads, changed by hand through the
/// same `changeState` the agent tools call — so a refusal reads the same here.
Future<void> showDeviceStateDialog(
  BuildContext context, {
  required String deviceLabel,
  required DeviceStateApplier apply,
}) => showDialog<void>(
  context: context,
  builder: (context) =>
      _DeviceStateDialog(deviceLabel: deviceLabel, apply: apply),
);

class _DeviceStateDialog extends StatefulWidget {
  const _DeviceStateDialog({required this.deviceLabel, required this.apply});

  final String deviceLabel;
  final DeviceStateApplier apply;

  @override
  State<_DeviceStateDialog> createState() => _DeviceStateDialogState();
}

class _DeviceStateDialogState extends State<_DeviceStateDialog> {
  final _appId = TextEditingController();
  final _locale = TextEditingController();
  final _permission = TextEditingController();
  bool _busy = false;
  String? _said;

  @override
  void dispose() {
    _appId.dispose();
    _locale.dispose();
    _permission.dispose();
    super.dispose();
  }

  String? get _app => _appId.text.trim().isEmpty ? null : _appId.text.trim();

  Future<void> _run(DeviceStateChange Function() change) async {
    if (_busy) return;
    setState(() => _busy = true);
    String said;
    try {
      said = await widget.apply(change());
    } on DeviceRefusal catch (refusal) {
      said = refusal.message;
    } on StateError catch (error) {
      said = error.message;
    } on Object catch (error) {
      said = '$error';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _said = said;
      });
    }
  }

  Future<void> _clearData() async {
    final app = _app;
    if (app == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear app data?'),
        content: Text(
          'Everything $app stored on ${widget.deviceLabel} — accounts, files, '
          'preferences — is deleted. There is no undo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear data'),
          ),
        ],
      ),
    );
    if (sure == true) await _run(() => ClearAppDataChange(app));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, Widget control) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: control),
        ],
      ),
    );
    Widget menu<T>(
      List<T> values,
      String Function(T) name,
      void Function(T) on,
    ) => Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<T>(
        enabled: !_busy,
        tooltip: 'Choose',
        onSelected: on,
        itemBuilder: (_) => [
          for (final value in values)
            PopupMenuItem(value: value, child: Text(name(value))),
        ],
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: Insets.xs),
          child: Text('Choose…'),
        ),
      ),
    );

    return AlertDialog(
      title: Text('Device settings · ${widget.deviceLabel}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(
                'Font scale',
                menu<double>(
                  const [0.85, 1.0, 1.15, 1.3, 1.5, 2.0],
                  (scale) => '$scale×',
                  (scale) => _run(() => FontScaleChange(scale)),
                ),
              ),
              row(
                'Rotation',
                menu<DeviceRotation>(
                  DeviceRotation.values,
                  (rotation) => rotation.name,
                  (rotation) => _run(() => RotationChange(rotation)),
                ),
              ),
              row(
                'Network',
                menu<NetworkProfile>(
                  NetworkProfile.values,
                  (profile) => profile.name,
                  (profile) => _run(() => NetworkChange(profile)),
                ),
              ),
              const Divider(),
              row(
                'App id',
                TextField(
                  controller: _appId,
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'com.example.app',
                    helperText: 'For locale (Android), permissions and data.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              row(
                'Locale',
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _locale,
                        style: theme.textTheme.bodySmall,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'fr-FR',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => LocaleChange(_locale.text, appId: _app),
                            ),
                      child: const Text('Set'),
                    ),
                  ],
                ),
              ),
              row(
                'Permission',
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _permission,
                        style: theme.textTheme.bodySmall,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'CAMERA, or photos on iOS',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy || _app == null
                          ? null
                          : () => _run(
                              () => PermissionChange(
                                appId: _app!,
                                permission: _permission.text,
                                grant: true,
                              ),
                            ),
                      child: const Text('Grant'),
                    ),
                    TextButton(
                      onPressed: _busy || _app == null
                          ? null
                          : () => _run(
                              () => PermissionChange(
                                appId: _app!,
                                permission: _permission.text,
                                grant: false,
                              ),
                            ),
                      child: const Text('Revoke'),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy || _app == null ? null : _clearData,
                  child: const Text('Clear app data…'),
                ),
              ),
              if (_said != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.sm),
                  child: SelectableText(
                    _said!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
