import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

/// The Add ACP agent dialog's Custom form: name, command, arguments and
/// environment, typed.
class AcpCustomAgentForm extends StatelessWidget {
  const AcpCustomAgentForm({
    required this.name,
    required this.command,
    required this.args,
    required this.env,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController name;
  final TextEditingController command;
  final TextEditingController args;
  final TextEditingController env;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: theme.textTheme.bodyMedium?.fontSize,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Name',
            hintText: 'My agent',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: command,
          style: mono,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Command',
            hintText: 'An executable on PATH, or its full path',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: args,
          style: mono,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Arguments',
            hintText: '--acp  (quotes keep words together)',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: env,
          style: mono,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Environment',
            hintText: 'KEY=value, one per line',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}
