import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/theme_colors.dart';
import '../../features/library/domain/models/recently_played.dart';
import 'cover_badge.dart';

/// 封面右上角的播放来源标签（歌单 / 榜单 / 专辑 / 搜索 / 作者 / 本地）。
class SourceBadge extends StatelessWidget {
  const SourceBadge({
    super.key,
    required this.type,
    required this.colors,
    this.onTap,
  });

  final PlaybackSourceType type;
  final ThemeColors colors;
  final VoidCallback? onTap;

  Color get _color => switch (type) {
    PlaybackSourceType.playlist => const Color(0xFFE0913C),
    PlaybackSourceType.rank => const Color(0xFFE05B5B),
    PlaybackSourceType.album => const Color(0xFFD9B44A),
    PlaybackSourceType.search => const Color(0xFF5B9BFF),
    PlaybackSourceType.artist => const Color(0xFFB07CFF),
    PlaybackSourceType.local => colors.primary,
    PlaybackSourceType.radio => const Color(0xFF4FC3A1),
    PlaybackSourceType.unknown => colors.textHint,
  };

  @override
  Widget build(BuildContext context) {
    return CoverBadge(
      label: context.tr(type.label),
      color: _color,
      onTap: onTap,
    );
  }
}
