import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surface.dart';
import '../../core/theme/theme_colors.dart';

/// 分页列表底部的状态。
enum LoadMoreStatus {
  /// 正在加载下一页。
  loading,

  /// 下一页加载失败：显示「加载失败，点击重试」。
  error,
}

/// 分页列表底部统一的「加载中 / 加载失败点击重试」提示。
///
/// 「没有更多了」不再展示——到底没到底，翻页条自己会表现出来，多一行
/// 提示只是占地方。以前分页失败会被当成「没有更多」，用户看到的是列表
/// 直接停住，也不知道是网络问题还是真的没有数据了；失败单独给重试入口。
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({
    super.key,
    required this.status,
    required this.colors,
    this.message,
    this.onRetry,
    this.padding = const EdgeInsets.symmetric(vertical: AppSpacing.lg),
  });

  final LoadMoreStatus status;
  final ThemeColors colors;

  /// 失败原因（可选），显示在「加载失败」下面一行。
  final String? message;

  final VoidCallback? onRetry;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Center(child: _buildContent(context)),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (status) {
      case LoadMoreStatus.loading:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case LoadMoreStatus.error:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRetry,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: 6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Text(
                      context.tr('加载失败，点击重试'),
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                if ((message ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    message!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ],
            ),
          ),
        );
    }
  }
}

/// 整页级别的「加载失败」占位（首屏失败时用），带重试按钮。
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({
    super.key,
    required this.colors,
    this.message,
    this.onRetry,
    this.title,
  });

  final ThemeColors colors;
  final String? message;
  final VoidCallback? onRetry;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: colors.textHint.withValues(alpha: 0.7),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title ?? context.tr('加载失败'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
            if ((message ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                message!.trim(),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: 8,
                ),
                // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
                decoration: activeChipDecoration(
                  colors,
                  radius: AppRadius.full,
                  withBorder: true,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Text(
                      context.tr('重试'),
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
