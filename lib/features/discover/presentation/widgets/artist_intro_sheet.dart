import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/utils/responsive_layout.dart';
import '../../../player/application/mini_player_visibility.dart';
import '../../domain/models/search_collection.dart';

/// 打开作者介绍弹框。
///
/// Windows 等桌面端限制为窗口宽度的 70%，与评论弹框一致。
Future<void> showArtistIntroSheet(
  BuildContext context, {
  required ArtistIntro intro,
  required String title,
  required ThemeColors colors,
}) {
  final width = MediaQuery.sizeOf(context).width;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.dialogSurface,
    constraints: Platform.isAndroid
        ? null
        : BoxConstraints(
            minWidth: width * 0.7,
            maxWidth: width * 0.7,
          ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (ctx) =>
        ArtistIntroSheet(intro: intro, title: title, colors: colors),
  );
}

/// 作者介绍弹框：标题 + 一行元数据 + 可滚动的正文。
///
/// 高度上限取屏幕 70%：简介可能上万字符（酷我），必须能滚。
class ArtistIntroSheet extends ConsumerWidget {
  const ArtistIntroSheet({
    super.key,
    required this.intro,
    required this.title,
    required this.colors,
  });

  final ArtistIntro intro;
  final String title;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Android 弹层在页面导航器里，会压在迷你播放器下面，正文要给它让出高度。
    final miniPlayerInset =
        Platform.isAndroid && ref.watch(miniPlayerVisibleProvider)
        ? ResponsiveLayout.miniPlayerReservedHeight(context)
        : 0.0;
    // Android 正文字号大 2 号。
    final bodyFontSize = Platform.isAndroid ? 17.0 : 15.0;
    final meta = <String>[
      if (intro.alias.isNotEmpty) intro.alias,
      if (intro.region.isNotEmpty) intro.region,
      if (intro.birthday.isNotEmpty) intro.birthday,
      if (intro.style.isNotEmpty) intro.style,
      if (intro.albumCount > 0) '${intro.albumCount} 张专辑',
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('作者介绍'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Icon(Icons.close, size: 18, color: colors.textHint),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                top: 2,
              ),
              child: Text(
                meta.join(' · '),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg + miniPlayerInset,
              ),
              child: SelectableText(
                intro.description,
                style: TextStyle(
                  fontSize: bodyFontSize,
                  height: 1.7,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
