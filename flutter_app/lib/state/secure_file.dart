import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the encryption key lives (the system's secure storage; a fake one in the tests).
abstract class KeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Android Keystore / Windows Credential Manager, through flutter_secure_storage.
class SystemKeyStore implements KeyStore {
  static const _storage = FlutterSecureStorage();
  static const _name = 'maskoret-local-cache-key';

  @override
  Future<String?> read() => _storage.read(key: _name);
  @override
  Future<void> write(String value) => _storage.write(key: _name, value: value);
  @override
  Future<void> delete() => _storage.delete(key: _name);
}

/// The only thing the app keeps on the device: a temporary, encrypted copy of the household on screen,
/// so it opens fast and keeps working without internet. The server is the source of truth; signing out
/// deletes this copy and its key. Port of SecureFile.swift.
///
/// Files are AES-GCM sealed (256-bit key in the system's secure storage, never next to the files):
/// "MSK1" + nonce + ciphertext + tag — the same layout as the Swift app's files.
class SecureFile {
  SecureFile(this.folder, this.keys);

  final Directory folder;
  final KeyStore keys;

  static final _magic = utf8.encode('MSK1');
  static final _algorithm = AesGcm.with256bits();
  SecretKey? _key;

  Future<SecretKey?> _existingKey() async {
    if (_key != null) return _key;
    final stored = await keys.read();
    if (stored == null) return null;
    return _key = SecretKey(base64Decode(stored));
  }

  Future<SecretKey> _keyForWriting() async {
    final existing = await _existingKey();
    if (existing != null) return existing;
    final key = await _algorithm.newSecretKey();
    await keys.write(base64Encode(await key.extractBytes()));
    return _key = key;
  }

  static bool isEncrypted(List<int> data) =>
      data.length >= _magic.length && List.generate(_magic.length, (i) => data[i] == _magic[i]).every((x) => x);

  Future<void> write(File file, String text) async {
    final box = await _algorithm.encrypt(utf8.encode(text), secretKey: await _keyForWriting());
    folder.createSync(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsBytes(Uint8List.fromList([..._magic, ...box.concatenation()]), flush: true);
    await tmp.rename(file.path);
  }

  /// Reads an encrypted file. Plain JSON written by older versions is still read (and gets encrypted on the next save).
  /// Returns null when the file is missing or can't be opened (e.g. its key was deleted).
  Future<String?> read(File file) async {
    if (!file.existsSync()) return null;
    final data = await file.readAsBytes();
    if (!isEncrypted(data)) return utf8.decode(data);
    try {
      final key = await _existingKey();
      if (key == null) return null;
      final box = SecretBox.fromConcatenation(data.sublist(_magic.length),
          nonceLength: _algorithm.nonceLength, macLength: _algorithm.macAlgorithm.macLength);
      return utf8.decode(await _algorithm.decrypt(box, secretKey: key));
    } catch (_) {
      return null;
    }
  }

  /// Signing out: the encrypted copy and its key are gone — whatever is left on disk can't be read.
  Future<void> wipeAll() async {
    if (folder.existsSync()) {
      for (final item in folder.listSync()) {
        try {
          item.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    await keys.delete();
    _key = null;
  }
}
