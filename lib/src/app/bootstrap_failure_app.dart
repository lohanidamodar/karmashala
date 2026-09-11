import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/theme.dart';

/// What the window shows when the bootstrap threw before the shell could run.
/// A process that exits with nothing is the alternative.
class BootstrapFailureApp extends StatelessWidget {
  const BootstrapFailureApp({
    super.key,
    required this.error,
    required this.stack,
    this.logDirectory,
  });

  final Object error;
  final StackTrace? stack;
  final Directory? logDirectory;

  String get details => 'Karmashala could not start.\n\n$error\n\n$stack';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Karmashala',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Karmashala could not start',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  SelectableText('$error'),
                  if (logDirectory != null) ...[
                    const SizedBox(height: 12),
                    SelectableText('Log: ${logDirectory!.path}'),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: details),
                        ),
                        child: const Text('Copy details'),
                      ),
                      OutlinedButton(
                        onPressed: () => exit(1),
                        child: const Text('Quit'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
