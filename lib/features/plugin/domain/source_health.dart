/// 音源（`平台id@插件id`）最近一次取地址请求的健康状态。
///
/// 用途：在插件管理页给插件卡片打红标（「失败」/「超时」），让用户一眼看出
/// 哪个播放源最近不可用，而不用翻日志。标记会一直留着，直到：
///
/// * 用户手动清除（点标签）；
/// * 插件测试通过（[PluginTestService] 里清除）；
/// * 后续播放同一音源成功（解析地址成功即清除）。
///
/// 只有**数据源自动换源**这条链路会打标：普通歌曲单曲失败多是「这首歌在该平台
/// 没版权」，拿它给音源扣帽子会误伤。
enum SourceHealthStatus {
  failed,
  timeout;

  /// 标签文案。
  String get label => switch (this) {
    SourceHealthStatus.failed => '失败',
    SourceHealthStatus.timeout => '超时',
  };

  /// 存储 / 日志用的稳定标识（不要用 [name] 之外的本地化文案做持久化）。
  String get code => name;

  static SourceHealthStatus? fromCode(Object? raw) {
    final text = '${raw ?? ''}'.trim().toLowerCase();
    if (text.isEmpty) return null;
    for (final status in SourceHealthStatus.values) {
      if (status.code == text) return status;
    }
    return null;
  }
}

/// 一条音源健康记录。
class SourceHealthEntry {
  /// 应用层音源 id（`平台id@插件id`，例如 `wy@1a2b3c`）。
  final String sourceId;

  final SourceHealthStatus status;

  /// 失败原因（简短、用户可读），可能为空。
  final String? reason;

  /// 记录时间。
  final DateTime at;

  const SourceHealthEntry({
    required this.sourceId,
    required this.status,
    this.reason,
    required this.at,
  });

  String get baseId {
    final at = sourceId.indexOf('@');
    return at < 0 ? sourceId : sourceId.substring(0, at);
  }

  String? get pluginId {
    final at = sourceId.indexOf('@');
    if (at < 0 || at + 1 >= sourceId.length) return null;
    return sourceId.substring(at + 1);
  }

  SourceHealthEntry copyWith({
    SourceHealthStatus? status,
    String? reason,
    DateTime? at,
    bool clearReason = false,
  }) => SourceHealthEntry(
    sourceId: sourceId,
    status: status ?? this.status,
    reason: clearReason ? null : (reason ?? this.reason),
    at: at ?? this.at,
  );

  Map<String, dynamic> toJson() => {
    'status': status.code,
    if (reason != null && reason!.isNotEmpty) 'reason': reason,
    'at': at.millisecondsSinceEpoch,
  };

  /// 解析失败返回 null（旧数据 / 手工改坏都不崩）。
  static SourceHealthEntry? fromJson(String sourceId, Object? json) {
    if (json is! Map) return null;
    final status = SourceHealthStatus.fromCode(json['status']);
    if (status == null) return null;
    final rawAt = json['at'];
    final at = rawAt is int
        ? DateTime.fromMillisecondsSinceEpoch(rawAt)
        : DateTime.tryParse('${rawAt ?? ''}') ??
              DateTime.now();
    final reason = '${json['reason'] ?? ''}'.trim();
    return SourceHealthEntry(
      sourceId: sourceId,
      status: status,
      reason: reason.isEmpty ? null : reason,
      at: at,
    );
  }
}
