import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/tokens.dart';
import '../companion_chrome.dart';
import 'pairing_progress_screen.dart';

/// Pairing with a machine that has an address of its own — a session host on a
/// server, rather than a desktop this phone has to be found by.
///
/// Two fields because a box needs two facts and neither can be guessed: the
/// address, which the person already knows because they typed it to reach the
/// machine over SSH, and the code the host printed. Nothing here searches — a
/// box is not on this network's beacon, and a machine cannot read its own
/// public address to announce one.
class AddMachineScreen extends ConsumerStatefulWidget {
  const AddMachineScreen({super.key});

  @override
  ConsumerState<AddMachineScreen> createState() => _AddMachineScreenState();
}

class _AddMachineScreenState extends ConsumerState<AddMachineScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  /// `host:port`, with the host's own default filled in when only a host is
  /// typed — the port is the same on every machine, so making somebody type it
  /// is asking them to remember something they cannot get wrong.
  String? _endpoint() {
    final typed = _address.text.trim();
    if (typed.isEmpty) return null;
    final withPort = typed.contains(':') ? typed : '$typed:$kHostCompanionPort';
    return parseLanHint(withPort) == null ? null : withPort;
  }

  Future<void> _pair() async {
    final endpoint = _endpoint();
    final code = _code.text.trim();
    setState(() => _error = null);
    if (endpoint == null) {
      setState(
        () => _error =
            'That is not an address this can dial. A machine looks like '
            '`203.0.113.9` or `box.example.com`, with `:port` if it is not the '
            'usual one.',
      );
      return;
    }
    if (classifyPairingInput(code) == PairingInputKind.unrecognised) {
      // Said here rather than after a dial: the code is wrong shape before
      // anything is contacted, and a round trip would only delay the answer.
      setState(() => _error = 'That does not look like a pairing code.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PairingProgressScreen(
          attempt: (gateway) => gateway.pairWithCode(code, at: endpoint),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: companionAppBar(context, title: const Text('Add a machine')),
      body: SafeArea(
        child: ListView(
          padding: companionListInsets(
            context,
            const EdgeInsets.all(Insets.xl),
          ),
          children: [
            Text(
              'A server running the Karmashala session host answers on its own '
              'address. On that machine, or from the desktop that set it up, '
              'open a pairing window and type what it shows here.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              controller: _address,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '203.0.113.9',
                helperText: 'The same address you use to reach it over SSH.',
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseFormatter()],
              onSubmitted: (_) => _pair(),
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                hintText: 'K7QM-3X2W-…',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: Insets.lg),
            FilledButton(onPressed: _pair, child: const Text('Pair')),
          ],
        ),
      ),
    );
  }
}

/// Codes are shown upper-case and read back that way; typing lower-case is not
/// a mistake worth refusing.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}
