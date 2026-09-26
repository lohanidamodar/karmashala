import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_matrix.dart';

/// A path is the longest unbroken run of characters a conversation ever holds,
/// and the chat sits in a pane that is routinely the narrowest column on
/// screen. Underlining one must not be what finally pushes the row off the
/// edge at 720x560.
void main() {
  const long =
      'lib/src/features/sessions/presentation/'
      'transcript_path_link_and_a_very_long_file_name.dart:1284:12';

  Widget build() => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(
        onPathTap: (_) {},
        messages: const [
          ChatMessage(
            role: 'agent',
            text: 'The failure is in $long, right at the top of the file.',
          ),
          ChatMessage(
            role: 'tool',
            text: 'Read($long)',
            tool: ToolActivity(name: 'Read', subject: long),
          ),
        ],
      ),
    ),
  );

  testWidgets('a long path survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(tester, build: build);
  });
}
