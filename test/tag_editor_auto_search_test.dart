import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/core/storage/app_preferences.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/features/discover/application/search_providers.dart';
import 'package:mintmusic/features/local/application/local_providers.dart';
import 'package:mintmusic/features/local/data/local_music_repository.dart';
import 'package:mintmusic/features/local/presentation/tag_editor_page.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/application/plugin_providers.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/features/settings/application/settings_providers.dart';

/// 曲库索引里只有这一首，打开页面不需要读文件。
class _FakeRepo implements LocalMusicRepository {
  _FakeRepo(this.song);

  final Song song;

  @override
  Song? getSongById(String id) => song;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSourceManager implements MusicSourceManager {
  final List<String> keywords = [];
  final List<String> sourceIds = [];

  @override
  Future<List<Song>> search(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) async {
    keywords.add(query);
    sourceIds.add(sourceId);
    // 返回空结果：本用例只验证「有没有自动发起搜索」，不关心结果内容。
    return const <Song>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ThemeColors _colors() {
  const white = Colors.white;
  return ThemeColors(
    primary: const Color(0xFFE0B96B),
    primaryLight: white,
    primaryDark: const Color(0xFF222222),
    accent: white,
    accentLight: white,
    background: const Color(0xFF141414),
    surface: const Color(0xFF1C1C1C),
    surfaceVariant: const Color(0xFF2A2A2A),
    dialogSurface: const Color(0xFF1E1E1E),
    dialogSurfaceVariant: const Color(0xFF2A2A2A),
    textPrimary: white,
    textSecondary: const Color(0xFFB0B0B0),
    textHint: const Color(0xFF707070),
    textOnPrimary: const Color(0xFF141414),
    error: const Color(0xFFE57373),
    success: const Color(0xFF81C784),
    warning: const Color(0xFFFFB74D),
    divider: const Color(0xFF3A3A3A),
    disabled: const Color(0xFF555555),
    miniPlayerBackground: const Color(0xFF181818),
    miniPlayerProgress: const Color(0xFFE0B96B),
    coverShadow: const Color(0x00000000),
    shadow: const Color(0x00000000),
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mint_tag_auto_search');
    AppPaths.debugRootOverride = tmp.path;
    // 预热设置单例：页面 initState 会读「上次使用的音源」，这里先让它完成，
    // 避免首次初始化与假时钟缠在一起。
    await AppPreferences.getInstance();
  });

  tearDown(() {
    AppPaths.debugRootOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('打开页面不搜，点「在线搜索」tab 自动搜一次', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final manager = _RecordingSourceManager();
    final repo = _FakeRepo(
      Song(
        id: 'local-1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        year: 2003,
        source: 'local',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMusicRepositoryProvider.overrideWithValue(repo),
          musicSourceManagerProvider.overrideWithValue(manager),
          searchAvailableSourcesProvider.overrideWithValue(const [
            SourceInfo(id: 'kw@kw-test', name: '酷我'),
          ]),
          defaultSourceIdProvider.overrideWithValue('kw@kw-test'),
          pluginInitializedProvider.overrideWith((ref) async {}),
          themeColorsProvider.overrideWithValue(_colors()),
        ],
        child: L10n(
          locale: AppLocale.zhCn,
          child: MaterialApp(home: TagEditorPage(songId: 'local-1')),
        ),
      ),
    );

    // 等 _loadSong（postFrame）与「上次使用的音源」读取完成。
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(
      manager.keywords,
      isEmpty,
      reason: '默认停在「编辑信息」，不应自动搜索',
    );

    // 点「在线搜索」tab：切过去就应该自动搜，不用再点搜索按钮。
    // tab 切换动画结束后 listener 才会触发自动搜索，所以先 settle 再等异步。
    await tester.tap(find.text('在线搜索'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(manager.keywords, ['晴天 周杰伦']);
    expect(manager.sourceIds, ['kw@kw-test']);

    // 由该 tab 切回「编辑信息」再切回来：已经有结果，不重复请求。
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在线搜索'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(manager.keywords.length, 1, reason: '切回来不重新搜索，保留已有结果');
  });
}
