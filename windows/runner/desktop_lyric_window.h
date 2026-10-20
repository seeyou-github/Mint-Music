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

/// 桌面歌词窗口。
///
/// 这是一个独立的顶层窗口（无边框、背景透明、可置顶），不依赖 Flutter 视图，
/// 因此：
/// * 应用最小化后依然显示在桌面上；
/// * 锁定后置顶显示（HWND_TOPMOST）；
/// * 应用窗口内不再重复渲染歌词。
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
                    int width_percent,
                    unsigned int played_color,
                    unsigned int unplay_color,
                    unsigned int shadow_color,
                    double position_x,
                    double position_y,
                    int align);

  /// 更新歌词内容。[active_index] 为当前行（-1 表示无）。
  void UpdateLyric(const std::vector<DesktopLyricLine>& lines,
                   int active_index,
                   bool show_translation,
                   bool show_roman);

  /// 下发播放进度锚点：原生侧用自己的时钟推进当前行。
  void SetPlayState(long long position_ms, bool is_playing);

  /// 设置 / 清除拖动结束后的位置回调（参数为屏幕百分比）。
  void SetPositionCallback(std::function<void(double, double)> callback);

 private:
  DesktopLyricWindow() = default;
  ~DesktopLyricWindow() = default;

  static LRESULT CALLBACK WindowProc(HWND hwnd,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);

  LRESULT HandleMessage(HWND hwnd,
                        UINT message,
                        WPARAM wparam,
                        LPARAM lparam);

  void CreateWindowIfNeeded();
  void DestroyWindowIfNeeded();
  void ApplySizeAndPosition();
  void EnsureFont();
  void AdvanceActiveIndex();
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
  int width_percent_ = 30;
  unsigned int played_color_ = 0xFFFFFFFF;
  unsigned int unplay_color_ = 0xFFB0B0B0;
  unsigned int shadow_color_ = 0xFF000000;
  double position_x_ = 50.0;
  double position_y_ = 20.0;
  int align_ = 1;  // 0=左 1=居中 2=右
  bool show_translation_ = false;
  bool show_roman_ = false;

  // 歌词
  std::vector<DesktopLyricLine> lines_;
  int active_index_ = -1;

  // 播放进度锚点
  long long anchor_position_ms_ = 0;
  ULONGLONG anchor_tick_ = 0;
  bool is_playing_ = false;

  // 拖动
  bool dragging_ = false;
  int drag_offset_x_ = 0;
  int drag_offset_y_ = 0;

  std::function<void(double, double)> position_callback_;
};

}  // namespace mintmusic

#endif  // RUNNER_DESKTOP_LYRIC_WINDOW_H_
