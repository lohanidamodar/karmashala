import 'package:path/path.dart' as p;

/// Where an Antigravity conversation's **readable** transcript is, or null when
/// this store keeps none for it.
///
/// The design note that recorded this store as unreadable was drawn from
/// `conversations/<id>.db`, whose message columns really are protobuf in an
/// unpublished schema. A plain JSONL log sits elsewhere in the same store, and
/// on the WSL install here it exists for **every** conversation:
///
/// ```txt
/// ~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl
/// ```
///
/// Both accounts are therefore right, about two different files.
///
/// ## Measured on this machine, 2026-09-09
///
/// | Install | Brain directories | Transcripts |
/// | --- | --- | --- |
/// | WSL (`~/.gemini/antigravity-cli`) | 25 | 25, 2 to 3,789 lines |
/// | Windows (`C:\Users\<u>\.gemini\antigravity-cli`) | 1 | **0 — the directory is empty** |
///
/// So the Windows install keeps a `conversations/<id>.pb` and nothing to read
/// beside it. That is why this returns null rather than a path that does not
/// resolve: the refusal is a real answer, and it belongs where the caller can
/// act on it.
///
/// ## A path we were *given* beats a path we work out
///
/// The CLI's hooks documentation puts a `transcriptPath` on every payload, so
/// whenever a caller holds one it should hand it here unchanged — a `.jsonl`
/// argument is returned as it came, with no reconstruction at all. That
/// matters because the documented shape is **not** the one on this disk: the
/// docs put the file under the *workspace*
/// (`<workspace>/.gemini/antigravity-cli/transcript.jsonl`, product-specific by
/// their own note), and no such file exists here. Reconstructing by id is the
/// fallback, not the contract.
String? antigravityTranscriptPathFor(String filePath) {
  if (p.extension(filePath) == '.jsonl') return filePath;
  // `conversations/<id>.db` — the file identity is read from, and the only
  // path a detected Antigravity session carries.
  final conversations = p.dirname(filePath);
  if (p.basename(conversations) != 'conversations') return null;
  final id = p.basenameWithoutExtension(filePath);
  if (id.isEmpty) return null;
  return p.join(
    p.dirname(conversations),
    'brain',
    id,
    '.system_generated',
    'logs',
    'transcript.jsonl',
  );
}
