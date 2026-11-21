import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/backup/webdav_service.dart';
import 'package:mintmusic/core/security/local_field_codec.dart';

void main() {
  test('敏感字段编码后可还原，且不包含明文', () {
    const plain = 'https://dav.example.com/path?x=1';
    final sealed = sealField(plain);
    expect(sealed, startsWith('mm1:'));
    expect(sealed, isNot(contains('dav.example.com')));
    expect(unsealField(sealed), plain);
    // 随机 IV：同一明文每次编码结果都不一样。
    expect(sealField(plain), isNot(sealed));
    expect(sealField(''), '');
    expect(unsealField(''), '');
  });

  test('WebDAV 配置写盘时只包含编码后的地址 / 账号 / 密码', () {
    const config = WebDavConfig(
      url: 'https://dav.example.com/back',
      user: 'alice',
      password: 'p@ssw0rd',
      deviceName: 'PC',
      playlistSyncEnabled: true,
    );
    final json = config.toJson();
    expect(json['url'], isNot(contains('dav.example.com')));
    expect(json['user'], isNot(contains('alice')));
    expect(json['password'], isNot(contains('p@ssw0rd')));
    expect(json['deviceName'], 'PC');

    final restored = WebDavConfig.fromJson(json);
    expect(restored.url, config.url);
    expect(restored.user, config.user);
    expect(restored.password, config.password);
    expect(restored.deviceName, config.deviceName);
    expect(restored.playlistSyncEnabled, isTrue);
  });
}
