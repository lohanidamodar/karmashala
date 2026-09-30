import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_notice.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../application/store_credentials.dart';
import '../application/stores_dashboard.dart';
import 'stores_format.dart';

/// Settings → Stores: import, edit, replace and remove the two credentials
/// the Stores tab reads with. A private key is taken in and never shown.
class StoresSettingsSection extends ConsumerWidget {
  const StoresSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credentials = ref.watch(storeCredentialsProvider).value;
    return SettingsSection(
      title: SettingsAnchor.storeCredentials.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'Read-only: nothing here changes a listing, a release or a '
            'review. Each key is kept in this device’s system keystore, and '
            'its file is read once, when it is imported.',
          ),
          if (credentials == null)
            const SettingsNote('Reading the keystore…')
          else ...[
            // Keyed by presence, so a form's typed text does not outlive the
            // credential it was typed for.
            _AppleCard(
              key: ValueKey(('apple', credentials.apple?.keyId)),
              current: credentials.apple,
            ),
            _PlayCard(
              key: ValueKey(('play', credentials.play?.clientEmail)),
              current: credentials.play,
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks a credential file on this device and answers its text, or a sentence
/// saying why there is none. Null when the dialog was cancelled.
Future<({String? name, String? text, String? problem})?> _pickCredential(
  BuildContext context,
  WidgetRef ref, {
  required String what,
  required XTypeGroup type,
}) async {
  final read = ref.read(credentialFileReaderProvider);
  final file = await pickDeviceFile(
    context: context,
    what: what,
    acceptedTypeGroups: [type],
  );
  if (file == null) return null;
  try {
    return (name: file.name, text: await read(file.path), problem: null);
  } on CredentialFileException catch (error) {
    return (name: null, text: null, problem: error.message);
  }
}

/// iOS refuses a group with no type identifier; `.p8` has none of its own.
const _p8Files = XTypeGroup(
  label: 'Private key',
  extensions: ['p8'],
  uniformTypeIdentifiers: ['public.data'],
);

const _jsonFiles = XTypeGroup(
  label: 'Service-account key',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

Future<bool> _confirmRemoval(BuildContext context, String what) =>
    showConfirmDialog(
      context,
      title: 'Remove the $what?',
      message:
          'It is deleted from this device’s keystore, and that store leaves '
          'the Stores tab. To connect again you would import the file again.',
      confirmLabel: 'Remove',
      destructive: true,
    );

/// A card's name, and whether the last time the store was asked for its apps
/// with this credential worked, and when.
class _CardTitle extends ConsumerWidget {
  const _CardTitle(this.store, {required this.imported});

  final StoreKind store;
  final bool imported;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = imported
        ? ref.watch(storesDashboardProvider).value?.stores[store]
        : null;
    final now = ref.watch(clockProvider).nowUtc();
    String age(DateTime at) => formatDataAge(now.difference(at));
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            store == StoreKind.appStore ? 'App Store Connect' : store.label,
            style: SettingsStyles.rowLabel(context),
          ),
          switch (reading) {
            ReadingMissing(:final checkedAt, :final message) => Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: SettingsNotice(
                tone: SettingsNoticeTone.attention,
                message: 'The last check failed, ${age(checkedAt)}.',
                detail: message,
              ),
            ),
            ReadingValue(:final checkedAt) => Text(
              'The last check worked, ${age(checkedAt)}.',
              style: SettingsStyles.rowHelp(context),
            ),
            null => Text(
              imported ? 'Imported. Not checked yet.' : 'Not imported.',
              style: SettingsStyles.rowHelp(context),
            ),
          },
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.lines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final int lines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.sm),
    child: TextField(
      controller: controller,
      minLines: lines,
      maxLines: lines,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
      ),
    ),
  );
}

/// The chosen file's name beside the button that chooses it. The name only:
/// never the path's contents.
class _FileChoice extends StatelessWidget {
  const _FileChoice({
    required this.label,
    required this.chosen,
    required this.onChoose,
  });

  final String label;
  final String? chosen;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.sm),
    child: Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton(onPressed: onChoose, child: Text(label)),
        Text(
          chosen ?? 'No file chosen',
          style: SettingsStyles.rowHelp(context),
        ),
      ],
    ),
  );
}

class _Problem extends StatelessWidget {
  const _Problem(this.message);

  final String? message;

  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: Insets.sm),
          child: SettingsNotice(
            tone: SettingsNoticeTone.danger,
            message: message!,
          ),
        );
}

class _AppleCard extends ConsumerStatefulWidget {
  const _AppleCard({required this.current, super.key});

  final AppleApiKey? current;

  @override
  ConsumerState<_AppleCard> createState() => _AppleCardState();
}

class _AppleCardState extends ConsumerState<_AppleCard> {
  late final _keyId = TextEditingController();
  late final _issuerId = TextEditingController();
  late final _vendor = TextEditingController(
    text: widget.current?.vendorNumber ?? '',
  );

  /// The picked `.p8`'s text, held only until Save hands it to the vault.
  String? _pem;
  String? _fileName;
  String? _problem;
  bool _replacing = false;
  bool _busy = false;

  @override
  void dispose() {
    _keyId.dispose();
    _issuerId.dispose();
    _vendor.dispose();
    super.dispose();
  }

  StoreCredentialsController get _controller =>
      ref.read(storeCredentialsProvider.notifier);

  Future<void> _run(Future<String?> Function() change) async {
    setState(() => _busy = true);
    final problem = await change();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  Future<void> _choose() async {
    final picked = await _pickCredential(
      context,
      ref,
      what: 'the App Store Connect .p8 key',
      type: _p8Files,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pem = picked.text ?? _pem;
      _fileName = picked.name ?? _fileName;
      _problem = picked.problem;
    });
  }

  Future<void> _save() async {
    final pem = _pem;
    if (pem == null) {
      setState(() => _problem = 'Choose the .p8 file first.');
      return;
    }
    await _run(
      () => _controller.importAppleKey(
        pem: pem,
        keyId: _keyId.text,
        issuerId: _issuerId.text,
        vendorNumber: _vendor.text,
      ),
    );
    _imported();
  }

  /// A saved replacement closes the form and lets go of the key's text.
  void _imported() {
    if (!mounted || _problem != null) return;
    setState(() {
      _replacing = false;
      _pem = null;
      _fileName = null;
    });
  }

  Future<void> _remove() async {
    if (!await _confirmRemoval(context, 'App Store Connect key')) return;
    if (!mounted) return;
    await _run(_controller.removeAppleKey);
  }

  @override
  Widget build(BuildContext context) {
    final imported = widget.current;
    // What is shown as imported; null while a replacement is being typed.
    final current = _replacing ? null : imported;
    final editing = current == null;
    final card = SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(StoreKind.appStore, imported: imported != null),
          if (current != null) ...[
            LabeledValueRow(
              label: 'Key ID',
              value: SelectableText(current.keyId),
            ),
            LabeledValueRow(
              label: 'Issuer ID',
              value: SelectableText(current.issuerId),
            ),
            const SizedBox(height: Insets.xs),
          ] else ...[
            _Field(controller: _keyId, label: 'Key ID'),
            _Field(controller: _issuerId, label: 'Issuer ID'),
          ],
          _Field(
            controller: _vendor,
            label: 'Vendor number (optional)',
            hint: 'Needed for downloads',
          ),
          if (editing)
            _FileChoice(
              label: 'Choose .p8 file…',
              chosen: _fileName,
              onChoose: _busy ? null : _choose,
            ),
          _Problem(_problem),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              if (editing) ...[
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
                if (imported != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _replacing = false;
                            _problem = null;
                          }),
                    child: const Text('Cancel'),
                  ),
              ] else ...[
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => _controller.setAppleVendorNumber(_vendor.text),
                        ),
                  child: const Text('Save vendor number'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _replacing = true),
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: _busy ? null : _remove,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        const SettingsNote(
          'App Store Connect: a team key from Users and Access → '
          'Integrations, with at least Customer Support to read reviews and '
          'Sales or Finance for downloads. The vendor number is on Payments '
          'and Financial Reports.',
        ),
      ],
    );
  }
}

class _PlayCard extends ConsumerStatefulWidget {
  const _PlayCard({required this.current, super.key});

  final PlayAccount? current;

  @override
  ConsumerState<_PlayCard> createState() => _PlayCardState();
}

class _PlayCardState extends ConsumerState<_PlayCard> {
  late final _bucket = TextEditingController(
    text: widget.current?.reportsBucket ?? '',
  );
  late final _packages = TextEditingController(
    text: widget.current?.packageNames.join('\n') ?? '',
  );

  /// The picked key file's text, held only until Save hands it to the vault.
  String? _json;
  String? _fileName;
  String? _problem;
  bool _replacing = false;
  bool _busy = false;

  @override
  void dispose() {
    _bucket.dispose();
    _packages.dispose();
    super.dispose();
  }

  StoreCredentialsController get _controller =>
      ref.read(storeCredentialsProvider.notifier);

  Future<void> _run(Future<String?> Function() change) async {
    setState(() => _busy = true);
    final problem = await change();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  Future<void> _choose() async {
    final picked = await _pickCredential(
      context,
      ref,
      what: 'the Google Play service-account JSON',
      type: _jsonFiles,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _json = picked.text ?? _json;
      _fileName = picked.name ?? _fileName;
      _problem = picked.problem;
    });
  }

  Future<void> _save() async {
    final json = _json;
    if (json == null) {
      setState(() => _problem = 'Choose the service-account JSON first.');
      return;
    }
    await _run(
      () => _controller.importPlayAccount(
        json: json,
        bucket: _bucket.text,
        packageNames: parsePackageNames(_packages.text),
      ),
    );
    _imported();
  }

  /// A saved replacement closes the form and lets go of the key's text.
  void _imported() {
    if (!mounted || _problem != null) return;
    setState(() {
      _replacing = false;
      _json = null;
      _fileName = null;
    });
  }

  Future<void> _remove() async {
    if (!await _confirmRemoval(context, 'Google Play service account')) return;
    if (!mounted) return;
    await _run(_controller.removePlayAccount);
  }

  @override
  Widget build(BuildContext context) {
    final imported = widget.current;
    // What is shown as imported; null while a replacement is being typed.
    final current = _replacing ? null : imported;
    final editing = current == null;
    final card = SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(StoreKind.googlePlay, imported: imported != null),
          if (current != null) ...[
            LabeledValueRow(
              label: 'Account',
              value: SelectableText(current.clientEmail ?? 'Not named'),
            ),
            const SizedBox(height: Insets.xs),
          ],
          _Field(
            controller: _bucket,
            label: 'Reports bucket (optional)',
            hint: 'pubsite_prod_rev_…',
          ),
          _Field(
            controller: _packages,
            label: 'Extra package names (optional)',
            hint: 'com.example.app, one per line or comma separated',
            lines: 2,
          ),
          if (editing)
            _FileChoice(
              label: 'Choose service-account JSON…',
              chosen: _fileName,
              onChoose: _busy ? null : _choose,
            ),
          _Problem(_problem),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              if (editing) ...[
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
                if (imported != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _replacing = false;
                            _problem = null;
                          }),
                    child: const Text('Cancel'),
                  ),
              ] else ...[
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => _controller.setPlayOptions(
                            bucket: _bucket.text,
                            packageNames: parsePackageNames(_packages.text),
                          ),
                        ),
                  child: const Text('Save bucket and packages'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _replacing = true),
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: _busy ? null : _remove,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        const SettingsNote(
          'The reports bucket is in Play Console → Download reports → '
          'Statistics → “Copy Cloud Storage URI”; ratings and installs come '
          'from it.',
        ),
        const SettingsNote(
          'Google Play: the service account is invited in Play Console → '
          'Users and permissions with “View app information”, and “View app '
          'quality information” for crash and ANR rates.',
        ),
      ],
    );
  }
}
