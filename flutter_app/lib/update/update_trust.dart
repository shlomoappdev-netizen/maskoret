import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// What makes a downloaded update trusted (the same rules as UpdateTrust.swift). latest.json alone is not enough:
/// whoever could change the download site could point it at any file with that file's own sha256. So every platform
/// entry carries an Ed25519 signature of its platform, version, build and sha256, made with the owner's release key
/// (tools/manifest_sig.py), and the file comes only from this repository's GitHub releases.
class UpdateTrust {
  static const publicKey = '9W2HCLmnyplrC3gRqnhXipbtU5z5rJJmPLM4xCo96B0=';

  static String message(String platform, String version, int build, String sha256) =>
      'maskoret-update-v1\n$platform\n$version\n$build\n${sha256.toLowerCase()}';

  /// The entry was signed with the release key.
  static Future<bool> isSigned({
    required String platform,
    required String? version,
    required int? build,
    required String? sha256,
    required String? signature,
    String key = publicKey,
  }) async {
    if (version == null || build == null || sha256 == null || signature == null) return false;
    try {
      final sig = base64.decode(signature);
      final pub = base64.decode(key);
      if (sig.length != 64 || pub.length != 32) return false;
      return await Ed25519().verify(
        utf8.encode(message(platform, version, build, sha256)),
        signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Downloads come only from this repository's releases on GitHub.
  static bool isAllowedDownload(String url) {
    final u = Uri.tryParse(url);
    return u != null &&
        u.scheme == 'https' &&
        u.host.toLowerCase() == 'github.com' &&
        u.path.startsWith('/shlomoappdev-netizen/maskoret/releases/download/');
  }
}
