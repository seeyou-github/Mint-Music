#ifndef RUNNER_DESKTOP_LYRIC_WINDOW_H_
#define RUNNER_DESKTOP_LYRIC_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

namespace mintmusic {

/// 逐字时间轴里的一个字 / 词。
struct DesktopLyricWord {
  std::wstring text;
  long long start_ms = 0;
  long long end_ms = 0;
};

/// 一行歌词（时间 + 文本 + 翻译 + 罗马音 + 逐字时间轴）。
struct DesktopLyricLine {
  long long time_ms = 0;
  /// 这一行唱完的时间（普通 LRC 就是下一行的起始时间）。为 0 时由原生侧
  /// 用下一行的起始时间估算。
  long long end_time_ms = 0;
  std::wstring text;
  std::wstring translation;
  std::wstring roman;
  /// 逐字时间轴（逐字歌词才有；普通 LRC 为空，退回整行线性插值）。
  std::vector<DesktopLyricWord> words;
};

/// 一个要绘制的歌词槽位（固定两行，按当前行奇偶交替）。
struct DesktopLyricElement {
  std::wstring text;
  std::wstring translation;
  std::wstring roman;
  /// 是否为当前播放行（显示播放进度、超长时横向滚动）。
  bool active = false;
};

/// 桌面歌词窗口。
///
/// 这是一个独立的顶层窗口（无边框、背景透明、始终置顶），不依赖 Flutter 视图，
/// 因此：
/// * 应用最小化后依然显示在桌面上；
/// * 按住窗口可直接拖动位置。
class DesktopLyricWindow {
 public:
  static DesktopLyricWindow& Instance();

  /// 显示窗口（已显示时只更新样式与位置）。
  void Show();

  /// 隐藏并销毁窗口。
  void Hide();

  bool IsShowing() const { return window_ != nullptr; }

  /// 更新样式配置。
  ///
  /// 显示行数（固定 2 行）、不透明度（固定 80%）、锁定（固定关闭）都已固定，
  /// 不再由设置控制。
  void UpdateConfig(int font_size,
                    unsigned int played_color,
                    unsigned int unplay_color,
                    unsigned int shadow_color,
                    double position_x,
                    double position_y,
                    const std::wstring& font_family,
                    const std::wstring& font_path,
                    int font_weight);

  /// 更新歌词内容。[active_index] 为当前行（-1 表示无）。
  void UpdateLyric(const std::vector<DesktopLyricLine>& lines,
                   int active_index,
                   bool show_translation,
                   bool show_roman);

  /// 下发播放进度锚点：原生侧用自己的时钟推进当前行。
  void SetPlayState(long long position_ms, bool is_playing);

  /// 设置 / 清除拖动结束后的位置回调（参数为屏幕百分比）。
  void SetPositionCallback(std::function<void(double, double)> callback);

  /// 窗口过程（注册窗口类时需要取它的地址）。
  static LRESULT CALLBACK WindowProc(HWND hwnd,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);

 private:
  DesktopLyricWindow() = default;
  ~DesktopLyricWindow() = default;

  LRESULT HandleMessage(HWND hwnd,
                        UINT message,
                        WPARAM wparam,
                        LPARAM lparam);

  void CreateWindowIfNeeded();
  void DestroyWindowIfNeeded();
  void ApplySizeAndPosition();
  /// 取目标显示器的工作区（去掉任务栏后的可用区域）。
  ///
  /// 窗口已摆放时跟随窗口当前所在的显示器；刚创建（坐标不可信）或重新显示时
  /// 回到上次所在的显示器，这样隐藏再显示不会跳到另一块屏幕。
  void GetTargetWorkArea(RECT* work_area);
  /// 记录窗口当前所在的显示器，供下次重新显示时使用。
  void RememberMonitor();
  void EnsureFont();
  /// 组装固定两个槽位的歌词元素（槽位内容按当前行奇偶交替）。
  std::vector<DesktopLyricElement> BuildElements() const;
  /// 测量歌词内容所需高度（固定两个槽位，不会随行数变化）。
  int MeasureContentHeight() const;
  /// 推进当前歌词行；返回是否发生了变化（变化时需要重绘）。
  bool AdvanceActiveIndex();
  /// 当前播放位置（毫秒）。暂停时返回锚点位置，不随系统时钟前进。
  long long CurrentPositionMs() const;
  /// 当前行已经唱到的比例（0 ~ 1）。
  ///
  /// 普通 LRC 只有行级时间戳，这里用「本行开始 → 本行结束」这段区间做线性
  /// 插值，估算这一句唱到了哪个位置，用于逐字填充已播放颜色。
  double ActiveLineProgress() const;
  /// 当前行已唱到的比例（0 ~ 1），优先按逐字时间轴换算。
  ///
  /// 逐字歌词按「每个字的时间 + 实测字宽」累计已唱宽度再除以整行宽度，
  /// 与播放详情页的逐字高亮一致；没有逐字时间轴时退回 [ActiveLineProgress]。
  double ActiveSungFraction() const;
  /// 是否还需要逐帧重绘（跑马灯滚动 / 逐字填充还没走完）。
  bool NeedsAnimationFrame() const;
  void Paint();
  void ReportPosition();
  int GetLineHeight() const;
  /// 翻译 / 音译行的行高（使用略小的字号）。
  int GetSubLineHeight() const;
  /// 每个槽位为翻译 / 音译预留的行数。
  int GetSubLineCount() const;
  /// 单个槽位的总高度（主歌词 + 预留的翻译 / 音译行）。
  int GetSlotHeight() const;
  /// 某个槽位**实际**需要的高度：只统计真的会画出来的行
  /// （没有翻译 / 音译时不预留空行，避免两行歌词离窗口上下边框太远）。
  int SlotHeightFor(const DesktopLyricElement& element) const;

  HWND window_ = nullptr;
  HFONT font_ = nullptr;
  HFONT sub_font_ = nullptr;

  // 配置（显示 2 行、不透明度 80%、锁定关闭均为固定值，不再由设置控制）
  int font_size_ = 42;
  int font_weight_ = 500;
  unsigned int played_color_ = 0xFFFFFFFF;
  unsigned int unplay_color_ = 0xFFB0B0B0;
  unsigned int shadow_color_ = 0xFF000000;
  double position_x_ = 50.0;
  // 与 Dart 侧默认值一致（水平居中、靠近工作区底部）：配置下发前首次显示
  // 也不会先出现在顶部再跳到底部。
  double position_y_ = 85.0;
  bool show_translation_ = false;
  bool show_roman_ = false;

  // 窗口上次所在的显示器。隐藏会销毁窗口，重新显示时用它找回同一块屏幕。
  RECT monitor_rect_ = {};
  bool has_monitor_ = false;
  // 窗口刚创建、还没按保存的位置摆放：此时窗口坐标（0,0）不可信。
  bool placed_ = false;

  // 应用字体（导入的字体文件已在进程内注册）
  std::wstring font_family_;
  std::wstring loaded_font_path_;

  // 歌词
  std::vector<DesktopLyricLine> lines_;
  int active_index_ = -1;

  // 当前播放行超出窗口宽度时的横向滚动
  ULONGLONG marquee_start_tick_ = 0;
  // 暂停时记下的时间点：恢复播放时把暂停的这段时间从滚动计时里扣掉，
  // 这样长句歌词在暂停期间不会继续横向滚动。
  ULONGLONG marquee_pause_tick_ = 0;
  int marquee_overflow_px_ = 0;

  // 播放进度锚点
  long long anchor_position_ms_ = 0;
  ULONGLONG anchor_tick_ = 0;
  bool is_playing_ = false;

  // 正在被系统「拖动窗口」逻辑移动：期间不重绘，避免与拖动打架产生闪烁。
  bool dragging_ = false;

  // 上一帧绘制时当前行的填充进度：进度没变就不必再重绘
  // （前奏、暂停、整行已唱完时进度会被钳在 0 / 1，避免空转刷新）。
  double last_painted_progress_ = -1.0;

  std::function<void(double, double)> position_callback_;
};

}  // namespace mintmusic

#endif  // RUNNER_DESKTOP_LYRIC_WINDOW_H_
