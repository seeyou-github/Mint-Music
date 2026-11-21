import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_routes.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surface.dart';
import '../../core/theme/theme_colors.dart';
import '../../features/discover/domain/models/search_collection.dart';
import 'cover_badge.dart';
import 'music_cover_image.dart';

/// 专辑 / 作者卡片（搜索结果与作者专辑列表共用，保证两处样式一致）。
///
/// 外层仍由调用方套 [floatingCard] 提供阴影 / 边框，这里只负责卡片内容。
class CollectionCard extends StatelessWidget {
  const CollectionCard({super.key, required this.colors, required this.item});

  final ThemeColors colors;
  final SearchCollection item;

  @override
  Widget build(BuildContext context) {
    final isArtist = item.type == CollectionType.artist;
    final subtitle = <String>[
      if (!isArtist && (item.artist ?? '').isNotEmpty) item.artist!,
      if ((item.date ?? '').isNotEmpty) item.date!,
      if (item.worksNum > 0) context.tr('${item.worksNum} 首'),
    ].join(' · ');
    return GestureDetector(
      onTap: () => context.push(
        '${AppRoutes.collectionDetail}?type=${item.type.id}'
        '&id=${Uri.encodeComponent(item.id)}',
        extra: item,
      ),
      child: Container(
        decoration: floatingSurfaceDecoration(
          colors,
          radius: AppRadius.md,
          withShadow: false,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MusicCoverImage(
                      url: item.coverUrl,
                      fit: BoxFit.cover,
                      errorWidget: Container(
                        color: colors.surfaceVariant,
                        child: Icon(
                          isArtist ? Icons.person : Icons.album,
                          size: 36,
                          color: colors.textHint,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: CoverCountBadge(
                      label: context.tr(item.type.label),
                      fontSize: 11,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      radius: AppRadius.sm,
                      background: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}