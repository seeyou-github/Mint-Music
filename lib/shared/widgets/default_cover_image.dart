import 'package:flutter/material.dart';

/// 默认封面（内置资源 `assets/images/default_cover.jpg`）。
///
/// 只在「确认取不到封面」时显示：
/// - 本地歌曲读不到内嵌封面（封面缓存 / MediaStore / 音频文件都没有）；
/// - 在线歌曲封面地址缺失，且 getPic 兜底也拿不到可用地址、或加载超时失败。
///
/// 注意：**取封面过程中不要用它**——那时应该保持原有占位（不显示封面），
/// 否则每次切歌都会先闪一下默认封面再换成真封面。
class DefaultCoverImage extends StatelessWidget {
  /// 随安装包内置的默认封面。
  static const String assetPath = 'assets/images/default_cover.jpg';

  final BoxFit fit;

  const DefaultCoverImage({super.key, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      fit: fit,
      filterQuality: FilterQuality.medium,
      // 资源缺失（极少见：增量安装 / 热重载没带上新资源）时不留白，
      // 用一块与封面主色接近的深色兜底。
      errorBuilder: (_, _, _) =>
          const ColoredBox(color: Color(0xFF151721)),
    );
  }
}
