#ifndef RUNNER_DESKTOP_LYRIC_WINDOW_H_
#define RUNNER_DESKTOP_LYRIC_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

namespace mintmusic {

/// 一行歌词（时间 + 文本 + 翻译 + 罗马音）。
struct DesktopLyricLine {
  long long time_ms = 0;
  std::wstring text;
  std::wstring translation;
  std::wstring roman;
};

/// 一个要绘制的歌词元素（文本 + 颜色 + 透明度缩放）。
struct DesktopLyricElement {
  std::wstring text;
  unsigned int color = 0xFFFFFFFF;
  int alpha_scale = 100;
  /// 是否为当前播放行主歌词（居中显示，超长时横向滚动）。
  bool active = false;
  /// 是否属于当前播放行（含翻译 / 音译），居中显示。
  bool centered = false;
};

/// 桌面歌词窗口。
///
/// 这是一个独立的顶层窗口（无边框、背景透明、始终置顶），不依赖 Flutter 视图，
/// 因此：
/// * 应用最小化后依然显示在桌面上；
/// * 锁定后点击穿透下层内容（未锁定时可以拖动）。
class DesktopLyricWindow {
 public:
  static DesktopLyricWindow& Instance();

  /// 显示窗口（已显示时只更新样式与位置）。
  void Show();

  /// 隐藏并销毁窗口。
  void Hide();

  bool IsShowing() const { return window_ != nullptr; }

  /// 更新样式配置。
  void UpdateConfig(bool is_lock,
                    int max_line_num,
                    int font_size,
                    int opacity_percent,
                    unsigned int played_color,
                    unsigned int unplay_color,
                    unsigned int shadow_color,
                    double position_x,
                    double position_y,
                    const std::wstring& font_family,
                    const std::wstring& font_path);

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
  void EnsureFont();
  /// 组装当前要绘制的歌词元素。
  std::vector<DesktopLyricElement> BuildElements() const;
  /// 测量歌词内容所需高度（每行只显示一行文字，超长横向滚动）。
  int MeasureContentHeight() const;
  /// 推进当前歌词行；返回是否发生了变化（变化时需要重绘）。
  bool AdvanceActiveIndex();
  void Paint();
  void ReportPosition();
  int GetLineHeight() const;

  HWND window_ = nullptr;
  HFONT font_ = nullptr;

  // 配置
  bool is_lock_ = false;
  int max_line_num_ = 3;
  int font_size_ = 18;
  int opacity_percent_ = 100;
  unsigned int played_color_ = 0xFFFFFFFF;
  unsigned int unplay_color_ = 0xFFB0B0B0;
  unsigned int shadow_color_ = 0xFF000000;
  double position_x_ = 50.0;
  double position_y_ = 20.0;
  bool show_translation_ = false;
  bool show_roman_ = false;

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

  std::function<void(double, double)> position_callback_;
};

}  // namespace mintmusic

#endif  // RUNNER_DESKTOP_LYRIC_WINDOW_H_
