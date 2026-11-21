/// 音源的登录态。
///
/// 只有「插件实现了 `loginStatus` action」或「插件在 `send('loginStatus')`
/// 里主动上报」时才能拿到确切状态；其余情况一律 [unknown]，界面不能假装
/// 已登录。
///
/// ## 插件侧如何声明 / 上报
///
/// ```js
/// // 1) 静态声明（最简单，不推荐：装完就过时）
/// sources = { wy: { login: { required: true, state: 'loggedOut' } } }
///
/// // 2) 主动上报（运行时回调，宿主会缓存）
/// lx.send('loginStatus', { source: 'wy', state: 'loggedIn', account: 'xxx' })
///
/// // 3) 被动查询 action（推荐：宿主按需调用，不用一直推）
/// sources = { wy: { actions: ['musicUrl', 'loginStatus'], ... } }
/// request({ source: 'wy', action: 'loginStatus' }, (_, resp) => resp)
/// // 返回 { state: 'loggedIn' | 'loggedOut' | 'expired', account?: '昵称' }
/// ```
enum SourceLoginState {
  /// 插件不支持检测，或还没检测过。界面既不显示徽标，也不因登录态置灰。
  unknown,

  /// 确认已登录：凭据有效，全部声明音质都可用。
  loggedIn,

  /// 确认未登录：只剩 [SourceLoginSpec.freeQualitys] 里的档位可用。
  loggedOut,

  /// 之前登录过但凭据已失效（cookie 过期 / 被踢下线）。
  /// 与 [loggedOut] 的处理相同，只是提示文案更具体。
  expired;

  /// 是否已确认登录（只有这个状态能放开登录门槛的高音质）。
  bool get isLoggedIn => this == loggedIn;

  /// 是否「确认没登录」（需要提示用户去填凭据）。
  bool get isRejected => this == loggedOut || this == expired;

  /// 解析插件上报的原始值，无法识别时返回 [unknown]（绝不抛异常）。
  static SourceLoginState fromRaw(Object? raw) {
    final value = '${raw ?? ''}'.trim().toLowerCase().replaceAll('_', '');
    switch (value) {
      case 'loggedin':
      case 'login':
      case 'true':
      case 'ok':
      case 'valid':
        return SourceLoginState.loggedIn;
      case 'loggedout':
      case 'logout':
      case 'false':
      case 'nologin':
      case 'anonymous':
        return SourceLoginState.loggedOut;
      case 'expired':
      case 'invalid':
      case 'expire':
      case 'unauthorized':
        return SourceLoginState.expired;
      default:
        return SourceLoginState.unknown;
    }
  }

  /// 持久化用的稳定字符串（不要用 `name`，避免重命名枚举时旧数据失效）。
  String get storageKey {
    switch (this) {
      case SourceLoginState.unknown:
        return 'unknown';
      case SourceLoginState.loggedIn:
        return 'loggedIn';
      case SourceLoginState.loggedOut:
        return 'loggedOut';
      case SourceLoginState.expired:
        return 'expired';
    }
  }

  /// 界面上显示的文字。
  String get label {
    switch (this) {
      case SourceLoginState.unknown:
        return '登录态未知';
      case SourceLoginState.loggedIn:
        return '已登录';
      case SourceLoginState.loggedOut:
        return '未登录';
      case SourceLoginState.expired:
        return '登录已失效';
    }
  }
}
