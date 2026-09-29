import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_remote/client.dart' show parseEndpoint;
import 'package:karmashala_remote/remote.dart' show kHostCompanionPort;
import 'package:karmashala_ui/tokens.dart';

import 'pair_machine_page.dart';

/// Pairing by typing: the code or payload a machine shows, and — [byAddress]
/// — the address it answers on. Pasting leaves the address optional: a
/// payload or invite may name its own route, and a bare code meets the
/// server on the relay.
class PairMachineCodeScreen extends StatefulWidget {
  const PairMachineCodeScreen({
    super.key,
    required this.pairer,
    required this.byAddress,
  });

  final MachinePairer pairer;
  final bool byAddress;

  @override
  State<PairMachineCodeScreen> createState() => _PairMachineCodeScreenState();
}

class _PairMachineCodeScreenState extends State<PairMachineCodeScreen> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  /// `host:port`, the server's usual port filled in when only a host is typed.
  String? _endpoint() {
    final typed = _address.text.trim();
    if (typed.isEmpty) return null;
    return parseEndpoint(typed) != null ? typed : '$typed:$kHostCompanionPort';
  }

  Future<void> _pair() async {
    if (_busy) return;
    final endpoint = _endpoint();
    if (widget.byAddress && endpoint == null) {
      setState(
        () => _error =
            'Type the address the machine answers on, like `203.0.113.9` or '
            '`box.example.com`, with `:port` if it is not the usual one.',
      );
      return;
    }
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Type or paste the code the machine shows.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final refusal = await widget.pairer.pair(
      code: _code.text,
      address: endpoint,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = refusal;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = TextField(
      key: const Key('pair-machine-address-field'),
      controller: _address,
      enabled: !_busy,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: widget.byAddress ? 'Address' : 'Address, if it has one',
        hintText: '203.0.113.9',
        helperText: 'The same address you reach it at over SSH.',
      ),
    );
    final code = TextField(
      key: const Key('pair-machine-code-field'),
      controller: _code,
      enabled: !_busy,
      autofocus: !widget.byAddress,
      autocorrect: false,
      enableSuggestions: false,
      minLines: 1,
      maxLines: widget.byAddress ? 1 : 4,
      textCapitalization: widget.byAddress
          ? TextCapitalization.characters
          : TextCapitalization.none,
      inputFormatters: widget.byAddress ? [_UpperCase()] : null,
      onSubmitted: (_) => _pair(),
      style: theme.textTheme.bodyLarge?.copyWith(fontFamily: kMonoFamily),
      decoration: InputDecoration(
        labelText: widget.byAddress ? 'Pairing code' : 'Code or payload',
        hintText: 'K7QM-3X2W-…',
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.byAddress ? 'Add a machine by address' : 'Paste the code',
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(Insets.xl),
              children: [
                Text(
                  widget.byAddress
                      ? 'A server answers on its own address. Run '
                            '`karmashala_host pair` on it and type the code '
                            'it prints.'
                      : "Type the code shown under the machine's QR, or "
                            'paste its whole pairing payload. Codes expire '
                            'after five minutes.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: Insets.lg),
                if (widget.byAddress) ...[
                  address,
                  const SizedBox(height: Insets.md),
                  code,
                ] else ...[
                  code,
                  const SizedBox(height: Insets.md),
                  address,
                ],
                if (_error != null) ...[
                  const SizedBox(height: Insets.md),
                  Text(
                    _error!,
                    key: const Key('pair-machine-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: Insets.lg),
                FilledButton(
                  key: const Key('pair-machine-pair'),
                  onPressed: _busy ? null : _pair,
                  child: Text(_busy ? 'Pairing…' : 'Pair'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Codes are shown upper-case; typing lower-case is not a mistake to refuse.
class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}
