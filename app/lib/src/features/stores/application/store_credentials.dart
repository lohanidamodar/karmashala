import 'package:riverpod/riverpod.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

import '../../../core/probe/probe_mode.dart';
import '../../../core/util/clock_provider.dart';
import '../data/credential_file.dart';
import '../data/secure_secret_vault.dart';

export '../data/credential_file.dart' show CredentialFileException;

/// Where store credentials are kept: the OS keystore.
final storeVaultProvider = Provider<SecretVault>((ref) => SecureSecretVault());

final storeVaultKeysProvider = Provider<StoreVaultKeys>(
  (ref) => StoreVaultKeys(probe: ref.watch(probeModeProvider).enabled),
);

/// Reads a picked credential file's text; a provider so a test needs no file.
typedef CredentialFileReader = Future<String> Function(String path);

final credentialFileReaderProvider = Provider<CredentialFileReader>(
  (ref) => readCredentialFile,
);

/// The credentials imported so far; either may be absent.
class StoreCredentials {
  const StoreCredentials({this.apple, this.play});

  final AppleApiKey? apple;
  final PlayAccount? play;

  bool get isEmpty => apple == null && play == null;

  Set<StoreKind> get connected => {
    if (apple != null) StoreKind.appStore,
    if (play != null) StoreKind.googlePlay,
  };
}

/// Package names as typed: separated by commas or new lines, blanks and
/// repeats dropped.
List<String> parsePackageNames(String typed) => {
  for (final part in typed.split(RegExp(r'[,\s]+')))
    if (part.trim().isNotEmpty) part.trim(),
}.toList();

String? _optional(String? typed) {
  final value = typed?.trim() ?? '';
  return value.isEmpty ? null : value;
}

/// Imports, edits and removes the two store credentials. Every change answers
/// null when it was kept, or a sentence saying why it was not.
class StoreCredentialsController extends AsyncNotifier<StoreCredentials> {
  @override
  Future<StoreCredentials> build() async {
    final vault = ref.watch(storeVaultProvider);
    final keys = ref.watch(storeVaultKeysProvider);
    final apple = await vault.read(keys.apple);
    final play = await vault.read(keys.play);
    return StoreCredentials(
      apple: _decode(apple, AppleApiKey.decode),
      play: _decode(play, PlayAccount.decode),
    );
  }

  /// A value that no longer decodes is treated as absent: importing again
  /// replaces it.
  static T? _decode<T>(String? encoded, T Function(String) decode) {
    if (encoded == null) return null;
    try {
      return decode(encoded);
    } on Object {
      return null;
    }
  }

  Future<String?> importAppleKey({
    required String pem,
    required String keyId,
    required String issuerId,
    String? vendorNumber,
  }) => _saveApple(
    AppleApiKey(
      keyId: keyId.trim(),
      issuerId: issuerId.trim(),
      privateKeyPem: pem,
      vendorNumber: _optional(vendorNumber),
    ),
  );

  Future<String?> setAppleVendorNumber(String? vendorNumber) async {
    final key = (await future).apple;
    if (key == null) return 'No App Store Connect key is imported.';
    return _saveApple(key.withVendorNumber(_optional(vendorNumber)));
  }

  Future<String?> removeAppleKey() => _change(
    (vault, keys) => vault.delete(keys.apple),
    (current) => StoreCredentials(play: current.play),
  );

  Future<String?> importPlayAccount({
    required String json,
    String? bucket,
    List<String> packageNames = const [],
  }) => _savePlay(
    PlayAccount(
      serviceAccountJson: json,
      reportsBucket: _optional(bucket),
      packageNames: packageNames,
    ),
  );

  Future<String?> setPlayOptions({
    String? bucket,
    required List<String> packageNames,
  }) async {
    final account = (await future).play;
    if (account == null) return 'No Google Play service account is imported.';
    return _savePlay(
      account.copyWith(
        reportsBucket: () => _optional(bucket),
        packageNames: packageNames,
      ),
    );
  }

  Future<String?> removePlayAccount() => _change(
    (vault, keys) => vault.delete(keys.play),
    (current) => StoreCredentials(apple: current.apple),
  );

  Future<String?> _saveApple(AppleApiKey key) async {
    if (key.problem case final problem?) return problem;
    return _change(
      (vault, keys) => vault.write(keys.apple, key.encode()),
      (current) => StoreCredentials(apple: key, play: current.play),
    );
  }

  Future<String?> _savePlay(PlayAccount account) async {
    if (account.problem case final problem?) return problem;
    return _change(
      (vault, keys) => vault.write(keys.play, account.encode()),
      (current) => StoreCredentials(apple: current.apple, play: account),
    );
  }

  /// Changes the vault, then the state: the console and the dashboard watch
  /// it, so both are rebuilt on every change.
  Future<String?> _change(
    Future<void> Function(SecretVault vault, StoreVaultKeys keys) change,
    StoreCredentials Function(StoreCredentials current) after,
  ) async {
    final vault = ref.read(storeVaultProvider);
    final keys = ref.read(storeVaultKeysProvider);
    final current = await future;
    try {
      await change(vault, keys);
    } on Object catch (error) {
      // The type only: a keystore error may quote what it was given.
      return 'The system keystore refused the change (${error.runtimeType}).';
    }
    if (ref.mounted) state = AsyncData(after(current));
    return null;
  }
}

final storeCredentialsProvider =
    AsyncNotifierProvider<StoreCredentialsController, StoreCredentials>(
      StoreCredentialsController.new,
    );

/// The stores there are credentials for, read as one. Rebuilt — and the old
/// one closed — whenever a credential changes.
final storeConsoleProvider = Provider<StoreConsole>((ref) {
  final credentials = ref.watch(storeCredentialsProvider).value;
  final clock = ref.watch(clockProvider);
  final console = StoreConsole([
    if (credentials?.apple case final key?) AppleStoreClient(key),
    if (credentials?.play case final account?) PlayStoreClient(account),
  ], now: clock.nowUtc);
  ref.onDispose(console.close);
  return console;
});
