/// 设置文件里少量敏感字段的本地编码工具。
///
/// 只是初级防护：让 `settings.json`（以及打进备份包的 settings.json）里
/// 不出现可直接阅读的明文，不作为真正的安全边界。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// 编码结果的前缀，用来区分「已编码」和「原样保存」的字段。
const String _tag = 'mm1:';

/// 密钥片段：逐位掩码存放，源码 / 二进制里不会出现密钥原文。
const List<int> _fragments = [
  0x42,
  0x29,
  0x3F,
  0x16,
  0x33,
  0xE9,
  0xE0,
  0xD5,
  0xDE,
  0xAB,
  0xF4,
  0xDB,
  0xC9,
  0x3F,
];

enc.Encrypter? _cipher;

enc.Encrypter get _encrypter {
  final cached = _cipher;
  if (cached != null) return cached;
  final text = String.fromCharCodes([
    for (var i = 0; i < _fragments.length; i++)
      _fragments[i] ^ ((0x2F + i * 17) & 0xFF),
  ]);
  final key = sha256.convert(utf8.encode(text)).bytes;
  final created = enc.Encrypter(
    enc.AES(enc.Key(Uint8List.fromList(key)), mode: enc.AESMode.cbc),
  );
  _cipher = created;
  return created;
}

/// 把明文编码成可以写进设置文件的文本；空值仍然是空串。
///
/// 每次都会用新的随机 IV，同样的明文得到的密文不同。
String sealField(String plain) {
  if (plain.isEmpty) return '';
  final iv = enc.IV.fromSecureRandom(16);
  final body = _encrypter.encrypt(plain, iv: iv);
  final bytes = Uint8List(16 + body.bytes.length)
    ..setRange(0, 16, iv.bytes)
    ..setRange(16, 16 + body.bytes.length, body.bytes);
  return '$_tag${base64Url.encode(bytes)}';
}

/// 还原 [sealField] 的结果。
///
/// 不带本工具前缀的值原样返回；内容损坏时返回空串，避免一条坏字段让整份
/// 配置读不出来。
String unsealField(String stored) {
  if (!stored.startsWith(_tag)) return stored;
  try {
    final bytes = base64Url.decode(stored.substring(_tag.length));
    if (bytes.length <= 16) return '';
    final iv = enc.IV(Uint8List.sublistView(bytes, 0, 16));
    final body = enc.Encrypted(Uint8List.sublistView(bytes, 16));
    return _encrypter.decrypt(body, iv: iv);
  } catch (_) {
    return '';
  }
}
