import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/presentation/widgets/player_controls.dart';

void main() {
  testWidgets('播放页音质按钮与菜单用短名称', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: PlayerProgressBar(
              progress: 0.2,
              position: const Duration(seconds: 30),
              duration: const Duration(seconds: 180),
              currentQuality: '128k',
              availableQualities: const ['128k', '320k', 'flac', 'hires'],
              currentSong: const Song(
                id: 'online',
                title: 't',
                artist: 'a',
                album: 'b',
                duration: 180,
                source: 'wy',
              ),
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );

    // 按钮上显示当前音质的短名称。
    expect(find.text('128K'), findsOneWidget);
    expect(find.text('标准 128K'), findsNothing);

    await tester.tap(find.text('128K'));
    await tester.pumpAndSettle();

    expect(find.text('128K'), findsNWidgets(2));
    expect(find.text('320K'), findsOneWidget);
    expect(find.text('Flac'), findsOneWidget);
    // 其他档位保持原名称。
    expect(find.text('高清臻音'), findsOneWidget);
  });
}
