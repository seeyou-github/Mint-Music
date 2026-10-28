import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/theme/theme_colors.dart';
import 'package:mintmusic/features/player/presentation/widgets/lyric_format_tag.dart';

void main() {
  testWidgets('renders format name on light and dark backgrounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LyricFormatTag(format: 'YRC', colors: ThemeColors.light),
              LyricFormatTag(format: 'TTML', dark: true),
            ],
          ),
        ),
      ),
    );

    expect(find.text('YRC'), findsOneWidget);
    expect(find.text('TTML'), findsOneWidget);
  });
}
