#include "desktop_lyric_window.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <set>

namespace mintmusic {

namespace {

constexpr wchar_t kWindowClassName[] = L"MintMusicDesktopLyricWindow";
constexpr UINT_PTR kTimerId = 1;
// 逐字填充的刷新间隔（约 33fps）：50ms 时进度是按 1/20 跳的，长句歌词能
// 看出「一格一格」的台阶；30ms 下每步只移动 1~2 像素，接近线性推进。
constexpr int kTimerIntervalMs = 30;

/// 注册窗口类（只注册一次）。
ATOM RegisterLyricWindowClass() {
  static ATOM atom = 0;
  if (atom != 0) {
    return atom;
  }
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(WNDCLASSEXW);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = &DesktopLyricWindow::WindowProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;
  wc.lpszClassName = kWindowClassName;
  atom = ::RegisterClassExW(&wc);
  return atom;
}

/// 虚拟屏幕尺寸与原点（多显示器时坐标可能为负）。
void GetVirtualScreen(int* left, int* top, int* width, int* height) {
  RECT desktop{};
  ::GetWindowRect(::GetDesktopWindow(), &desktop);
  *left = static_cast<int>(desktop.left);
  *top = static_cast<int>(desktop.top);
  *width = static_cast<int>(desktop.right - desktop.left);
  *height = static_cast<int>(desktop.bottom - desktop.top);
  if (*width <= 0) *width = ::GetSystemMetrics(SM_CXSCREEN);
  if (*height <= 0) *height = ::GetSystemMetrics(SM_CYSCREEN);
}

/// 枚举字体族时的回调（把族名收集到 set 里）。
int CALLBACK EnumFontCollect(const LOGFONTW* font,
                             const TEXTMETRICW*,
                             DWORD,
                             LPARAM param) {
  auto* families = reinterpret_cast<std::set<std::wstring>*>(param);
  families->insert(font->lfFaceName);
  return 1;
}

/// 收集当前进程里已注册的字体族名。
void CollectFontFamilies(std::set<std::wstring>* families) {
  HDC dc = ::GetDC(nullptr);
  if (dc == nullptr) {
    return;
  }
  ::EnumFontFamiliesExW(dc, nullptr, &EnumFontCollect,
                        reinterpret_cast<LPARAM>(families), 0);
  ::ReleaseDC(nullptr, dc);
}

/// 测量单行文字宽度（调用前需先把字体选入 DC）。
int MeasureTextWidth(HDC dc, const std::wstring& text) {
  if (text.empty()) {
    return 0;
  }
  SIZE size{};
  if (::GetTextExtentPoint32W(dc, text.c_str(), static_cast<int>(text.size()),
                              &size) == 0) {
    return 0;
  }
  return static_cast<int>(size.cx);
}

/// 解析字体文件路径。
///
/// 绝对路径直接使用；相对路径（内置字体，位于 flutter_assets 下）基于
/// 程序所在目录的 `data\flutter_assets` 解析。
std::wstring ResolveFontPath(const std::wstring& path) {
  if (path.empty()) {
    return path;
  }
  if (path.find(L':') != std::wstring::npos) {
    return path;  // 已经是绝对路径
  }
  wchar_t exe_path[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  std::wstring dir(exe_path);
  const size_t slash = dir.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    dir = dir.substr(0, slash);
  }
  return dir + L"\\data\\flutter_assets\\" + path;
}

/// 载入字体文件，返回它在系统里的字体族名（失败返回空串）。
std::wstring LoadFontFamily(const std::wstring& path) {
  const std::wstring resolved = ResolveFontPath(path);
  if (resolved.empty()) {
    return std::wstring();
  }
  std::set<std::wstring> before;
  CollectFontFamilies(&before);
  // FR_PRIVATE：只在当前进程内生效，不污染系统字体。
  if (::AddFontResourceExW(resolved.c_str(), FR_PRIVATE, nullptr) == 0) {
    return std::wstring();
  }
  std::set<std::wstring> after;
  CollectFontFamilies(&after);
  for (const auto& family : after) {
    if (before.find(family) == before.end()) {
      return family;
    }
  }
  return std::wstring();
}

}  // namespace

DesktopLyricWindow& DesktopLyricWindow::Instance() {
  static DesktopLyricWindow instance;
  return instance;
}

int DesktopLyricWindow::GetLineHeight() const {
  return font_size_ * 3 / 2;
}

int DesktopLyricWindow::GetSubLineHeight() const {
  return std::max(14, font_size_ * 3 / 5) * 3 / 2;
}

int DesktopLyricWindow::GetSubLineCount() const {
  return (show_translation_ ? 1 : 0) + (show_roman_ ? 1 : 0);
}

int DesktopLyricWindow::GetSlotHeight() const {
  return GetLineHeight() + GetSubLineCount() * GetSubLineHeight();
}

void DesktopLyricWindow::SetPositionCallback(
    std::function<void(double, double)> callback) {
  position_callback_ = std::move(callback);
}

void DesktopLyricWindow::Show() {
  CreateWindowIfNeeded();
  if (window_ == nullptr) {
    return;
  }
  marquee_start_tick_ = ::GetTickCount64();
  marquee_pause_tick_ = marquee_start_tick_;
  marquee_overflow_px_ = 0;
  // 若在拖动过程中被隐藏（暂停），重新显示时不能还停在「拖动中」状态，
  // 否则自动刷新会被一直跳过。
  dragging_ = false;
  ApplySizeAndPosition();
  ::ShowWindow(window_, SW_SHOWNOACTIVATE);
  Paint();
  ::UpdateWindow(window_);
}

void DesktopLyricWindow::Hide() {
  DestroyWindowIfNeeded();
}

void DesktopLyricWindow::CreateWindowIfNeeded() {
  if (window_ != nullptr) {
    return;
  }
  if (RegisterLyricWindowClass() == 0) {
    return;
  }
  window_ = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kWindowClassName, L"", WS_POPUP, 0, 0, 400, 100, nullptr, nullptr,
      ::GetModuleHandle(nullptr), nullptr);
  if (window_ == nullptr) {
    return;
  }
  ::SetTimer(window_, kTimerId, kTimerIntervalMs, nullptr);
}

void DesktopLyricWindow::DestroyWindowIfNeeded() {
  if (window_ == nullptr) {
    return;
  }
  ::DestroyWindow(window_);
  window_ = nullptr;
}

void DesktopLyricWindow::UpdateConfig(int font_size,
                                       unsigned int played_color,
                                       unsigned int unplay_color,
                                       unsigned int shadow_color,
                                       double position_x,
                                       double position_y,
                                       const std::wstring& font_family,
                                       const std::wstring& font_path,
                                       int font_weight) {
  font_size_ = std::max(10, font_size);
  font_weight_ = std::max(1, std::min(1000, font_weight));
  played_color_ = played_color;
  unplay_color_ = unplay_color;
  shadow_color_ = shadow_color;
  position_x_ = position_x;
  position_y_ = position_y;

  // 应用字体：先注册字体文件，再取它在系统里的字体族名。
  if (!font_path.empty() && font_path != loaded_font_path_) {
    const std::wstring family = LoadFontFamily(font_path);
    loaded_font_path_ = font_path;
    // 枚举得到的族名最准确；枚举失败时退回 Dart 侧传来的名字。
    font_family_ = family.empty() ? font_family : family;
  } else if (font_path.empty()) {
    loaded_font_path_.clear();
    font_family_ = font_family;
  }

  if (font_ != nullptr) {
    ::DeleteObject(font_);
    font_ = nullptr;
  }
  if (sub_font_ != nullptr) {
    ::DeleteObject(sub_font_);
    sub_font_ = nullptr;
  }
  if (window_ != nullptr) {
    ApplySizeAndPosition();
    Paint();
  }
}

void DesktopLyricWindow::UpdateLyric(const std::vector<DesktopLyricLine>& lines,
                                     int active_index,
                                     bool show_translation,
                                     bool show_roman) {
  lines_ = lines;
  active_index_ = active_index;
  show_translation_ = show_translation;
  show_roman_ = show_roman;
  // 换行后从头开始滚动。
  marquee_start_tick_ = ::GetTickCount64();
  marquee_pause_tick_ = marquee_start_tick_;
  marquee_overflow_px_ = 0;
  if (window_ != nullptr) {
    ApplySizeAndPosition();
    Paint();
  }
}

void DesktopLyricWindow::SetPlayState(long long position_ms, bool is_playing) {
  anchor_position_ms_ = position_ms;
  anchor_tick_ = ::GetTickCount64();
  if (is_playing_ != is_playing) {
    const ULONGLONG now = anchor_tick_;
    if (is_playing) {
      // 恢复播放：把暂停期间的时间从跑马灯计时里扣掉，长句歌词不会因为
      // 暂停期间的时间而跳过一段。
      marquee_start_tick_ += (now - marquee_pause_tick_);
    } else {
      // 暂停：记下暂停时刻，滚动动画随之停住。
      marquee_pause_tick_ = now;
    }
    is_playing_ = is_playing;
  }
  // 锚点变了就重绘一次：暂停时没有定时推进，逐字进度会停在旧位置；
  // 拖动进度条（暂停状态）时也只有这里能把它纠正过来。
  if (window_ != nullptr) {
    Paint();
  }
}

long long DesktopLyricWindow::CurrentPositionMs() const {
  if (!is_playing_) {
    return anchor_position_ms_;
  }
  const ULONGLONG now = ::GetTickCount64();
  return anchor_position_ms_ + static_cast<long long>(now - anchor_tick_);
}

double DesktopLyricWindow::ActiveLineProgress() const {
  if (active_index_ < 0 ||
      active_index_ >= static_cast<int>(lines_.size())) {
    return 0.0;
  }
  const DesktopLyricLine& line = lines_[active_index_];
  const long long start = line.time_ms;
  long long end = line.end_time_ms;
  if (end <= start) {
    // 没有结束时间（例如加载中的占位行）时，用下一行的起始时间估算；
    // 最后一行按 3 秒估算，与 Dart 侧解析普通 LRC 的规则一致。
    end = (active_index_ + 1 < static_cast<int>(lines_.size()))
              ? lines_[active_index_ + 1].time_ms
              : start + 3000;
  }
  if (end <= start) {
    return 0.0;
  }
  const long long position = CurrentPositionMs();
  if (position <= start) {
    return 0.0;
  }
  if (position >= end) {
    return 1.0;
  }
  return static_cast<double>(position - start) /
         static_cast<double>(end - start);
}

bool DesktopLyricWindow::NeedsAnimationFrame() const {
  if (!is_playing_ || dragging_ || window_ == nullptr) {
    return false;
  }
  if (lines_.empty()) {
    return false;
  }
  // 跑马灯滚动中，或者当前行的逐字填充还没走完，都需要继续重绘。
  if (marquee_overflow_px_ > 0) {
    return true;
  }
  return ActiveLineProgress() != last_painted_progress_;
}

void DesktopLyricWindow::EnsureFont() {
  const int sub_size = std::max(14, font_size_ * 3 / 5);
  auto create_font = [this](int pixel_size, const wchar_t* face) {
    return ::CreateFontW(-pixel_size, 0, 0, 0, font_weight_, FALSE, FALSE, FALSE,
                         DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                         CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                         DEFAULT_PITCH | FF_DONTCARE, face);
  };
  auto create_with_fallback = [&](int pixel_size) -> HFONT {
    // 优先使用歌词设置里选择的字体。
    if (!font_family_.empty()) {
      HFONT font = create_font(pixel_size, font_family_.c_str());
      if (font != nullptr) {
        return font;
      }
    }
    HFONT font = create_font(pixel_size, L"Microsoft YaHei UI");
    if (font != nullptr) {
      return font;
    }
    return create_font(pixel_size, L"SimHei");
  };

  if (font_ == nullptr) {
    font_ = create_with_fallback(font_size_);
  }
  if (sub_font_ == nullptr) {
    sub_font_ = create_with_fallback(sub_size);
  }
}

/// 组装固定两个槽位的歌词元素。
///
/// 槽位由当前行的奇偶决定（active_index_ % 2）：当前行进哪个槽位，另一个
/// 槽位就预载下一行。这样从第一行唱到第二行时进度直接出现在第二行，第一行
/// 的位置换成了更后面的歌词，不会整体上移。
std::vector<DesktopLyricElement> DesktopLyricWindow::BuildElements() const {
  std::vector<DesktopLyricElement> elements(2);
  if (lines_.empty()) {
    return elements;
  }
  const int count = static_cast<int>(lines_.size());
  const bool has_active = active_index_ >= 0 && active_index_ < count;
  const int base = has_active ? active_index_ : 0;
  const int active_slot = has_active ? (active_index_ % 2) : 0;
  for (int slot = 0; slot < 2; slot++) {
    const int offset = (slot - active_slot + 2) % 2;
    const int index = base + offset;
    if (index >= count) {
      continue;
    }
    DesktopLyricElement& element = elements[slot];
    element.text = lines_[index].text;
    element.translation = show_translation_ ? lines_[index].translation : L"";
    element.roman = show_roman_ ? lines_[index].roman : L"";
    element.active = has_active && index == active_index_;
  }
  return elements;
}

void DesktopLyricWindow::ApplySizeAndPosition() {
  if (window_ == nullptr) {
    return;
  }
  // 使用「工作区」（去掉任务栏后的可用区域），而不是整个虚拟屏幕。
  RECT work_area{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  if (work_area.right <= work_area.left || work_area.bottom <= work_area.top) {
    // 取不到工作区时退回整个虚拟屏幕。
    int virtual_left = 0;
    int virtual_top = 0;
    int virtual_width = 0;
    int virtual_height = 0;
    GetVirtualScreen(&virtual_left, &virtual_top, &virtual_width, &virtual_height);
    work_area = RECT{virtual_left, virtual_top, virtual_left + virtual_width,
                      virtual_top + virtual_height};
  }
  const int screen_left = work_area.left;
  const int screen_top = work_area.top;
  const int screen_width = work_area.right - work_area.left;
  const int screen_height = work_area.bottom - work_area.top;

  // 窗口宽度固定为工作区宽度的 80%（不再由设置项控制）。
  const int width = std::max(200, screen_width * 80 / 100);

  // 高度固定为两个槽位（含为翻译 / 音译预留的行），不随歌词内容变化。
  const int height = std::max(GetLineHeight(), MeasureContentHeight());

  int x = screen_left + static_cast<int>(position_x_ / 100.0 *
                                        std::max(0, screen_width - width));
  int y = screen_top + static_cast<int>(position_y_ / 100.0 *
                                        std::max(0, screen_height - height));
  if (x < screen_left) x = screen_left;
  if (y < screen_top) y = screen_top;

  // 桌面歌词始终置顶显示，并且始终可以拖动（锁定功能已固定为关闭）。
  ::SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
}

/// 测量歌词内容所需的高度：固定两个槽位。
int DesktopLyricWindow::MeasureContentHeight() const {
  return 2 * GetSlotHeight();
}

bool DesktopLyricWindow::AdvanceActiveIndex() {
  if (lines_.empty()) {
    if (active_index_ != -1) {
      active_index_ = -1;
      return true;
    }
    return false;
  }
  // 暂停时不推进当前行：歌词停在当前这一行，等恢复播放后再继续。
  if (!is_playing_) {
    return false;
  }
  const long long position = CurrentPositionMs();
  int index = 0;
  for (size_t i = 0; i < lines_.size(); i++) {
    if (lines_[i].time_ms <= position) {
      index = static_cast<int>(i);
    } else {
      break;
    }
  }
  if (index == active_index_) {
    return false;
  }
  active_index_ = index;
  // 换行后从头开始滚动。
  marquee_start_tick_ = ::GetTickCount64();
  marquee_pause_tick_ = marquee_start_tick_;
  marquee_overflow_px_ = 0;
  ApplySizeAndPosition();
  return true;
}

void DesktopLyricWindow::Paint() {
  if (window_ == nullptr) {
    return;
  }
  RECT client{};
  ::GetClientRect(window_, &client);
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  HDC screen_dc = ::GetDC(window_);
  if (screen_dc == nullptr) {
    return;
  }

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  // 负数表示位图自上而下排列，方便按行绘制。
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* canvas_bits = nullptr;
  HBITMAP canvas_bitmap = ::CreateDIBSection(screen_dc, &bitmap_info,
                                             DIB_RGB_COLORS, &canvas_bits,
                                             nullptr, 0);
  void* mask_bits = nullptr;
  HBITMAP mask_bitmap = ::CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS,
                                           &mask_bits, nullptr, 0);
  if (canvas_bitmap == nullptr || mask_bitmap == nullptr) {
    if (canvas_bitmap != nullptr) ::DeleteObject(canvas_bitmap);
    if (mask_bitmap != nullptr) ::DeleteObject(mask_bitmap);
    ::ReleaseDC(window_, screen_dc);
    return;
  }

  HDC canvas_dc = ::CreateCompatibleDC(screen_dc);
  HDC mask_dc = ::CreateCompatibleDC(screen_dc);
  HGDIOBJ old_canvas = ::SelectObject(canvas_dc, canvas_bitmap);
  HGDIOBJ old_mask = ::SelectObject(mask_dc, mask_bitmap);

  const size_t pixel_count =
      static_cast<size_t>(width) * static_cast<size_t>(height);
  std::memset(canvas_bits, 0, pixel_count * 4);
  std::memset(mask_bits, 0, pixel_count * 4);

  EnsureFont();
  ::SelectObject(mask_dc, font_);
  ::SetBkMode(mask_dc, TRANSPARENT);
  ::SetTextColor(mask_dc, RGB(255, 255, 255));

  auto* canvas = reinterpret_cast<uint32_t*>(canvas_bits);
  auto* mask = reinterpret_cast<uint32_t*>(mask_bits);

  const int line_height = GetLineHeight();
  const int sub_line_height = GetSubLineHeight();
  const int slot_height = GetSlotHeight();
  // 整体不透明度固定 80%。
  const int global_alpha = 80 * 255 / 100;

  // 当前播放行超出窗口宽度时横向滚动（来回滚动，两端速度为 0）。
  marquee_overflow_px_ = 0;
  const std::vector<DesktopLyricElement> elements = BuildElements();
  for (const auto& element : elements) {
    if (!element.active || element.text.empty()) {
      continue;
    }
    const int active_width = MeasureTextWidth(mask_dc, element.text);
    if (active_width > width) {
      marquee_overflow_px_ = active_width - width;
    }
    break;
  }
  int scroll_offset = 0;
  if (marquee_overflow_px_ > 0) {
    constexpr double kScrollPeriodSeconds = 7.0;
    const double elapsed =
        static_cast<double>(::GetTickCount64() - marquee_start_tick_) / 1000.0;
    // 0 → 1 向左滚到头，1 → 2 再滚回来。
    double phase =
        std::fmod(elapsed, kScrollPeriodSeconds * 2.0) / kScrollPeriodSeconds;
    if (phase > 1.0) {
      phase = 2.0 - phase;
    }
    // ease-in-out：两端速度为 0，避免来回滚动时突然反向。
    const double eased = phase * phase * (3.0 - 2.0 * phase);
    scroll_offset =
        static_cast<int>(std::lround(eased * marquee_overflow_px_));
  }

  // 把一段文字画到蒙版（黑底白字），再按颜色合成到画布。
  // 每个歌词元素只画一行：超长时不换行，由调用方传入横向偏移做滚动。
  //
  // [clip_right] 为合成时的右边界（画布像素坐标，-1 表示不裁剪）。当前播放行
  // 用它把「已经唱到」的部分单独染成已播放颜色，边界按进度线性推进，所以
  // 唱到某个字时这个字会被从左往右一点点擦亮。
  auto draw_text = [&](HFONT font, const std::wstring& text, int y,
                       int row_height, unsigned int color, int alpha_scale,
                       int left, int top_offset, UINT format, int draw_width,
                       int clip_right) {
    if (text.empty() || row_height <= 0 || draw_width <= 0) {
      return;
    }
    // 只处理文字实际覆盖的那块区域：逐帧重绘时整窗扫描在高分屏上很吃 CPU。
    const int rect_left = std::max(0, left);
    const int rect_right = std::min(width, left + draw_width);
    const int rect_top = std::max(0, y + top_offset);
    const int rect_bottom = std::min(height, y + top_offset + row_height);
    if (rect_left >= rect_right || rect_top >= rect_bottom) {
      return;
    }
    const size_t row_span = static_cast<size_t>(rect_right - rect_left) * 4;
    for (int py = rect_top; py < rect_bottom; py++) {
      std::memset(mask + static_cast<size_t>(py) * width + rect_left, 0,
                  row_span);
    }
    ::SelectObject(mask_dc, font);
    RECT text_rect{left, y + top_offset, left + draw_width,
                   y + top_offset + row_height};
    ::DrawTextW(mask_dc, text.c_str(), -1, &text_rect, format | DT_NOPREFIX);

    int x_end = rect_right;
    if (clip_right >= 0) {
      x_end = std::min(x_end, std::max(rect_left, clip_right));
    }
    if (rect_left >= x_end) {
      return;
    }

    const uint32_t alpha_base = ((color >> 24) & 0xFF) * alpha_scale / 100;
    // 再乘上整体不透明度（固定 80%）。
    const uint32_t alpha_limit = alpha_base * global_alpha / 255;
    const uint32_t r = (color & 0x00FF0000) >> 16;
    const uint32_t g = (color & 0x0000FF00) >> 8;
    const uint32_t b = (color & 0x000000FF);
    for (int py = rect_top; py < rect_bottom; py++) {
      const size_t row = static_cast<size_t>(py) * width;
      for (int px = rect_left; px < x_end; px++) {
        const size_t i = row + static_cast<size_t>(px);
        const uint32_t coverage = mask[i] & 0xFF;
        if (coverage == 0) {
          continue;
        }
        const uint32_t alpha = coverage * alpha_limit / 255;
        if (alpha == 0) {
          continue;
        }
        canvas[i] = (alpha << 24) | (((r * alpha / 255) & 0xFF) << 16) |
                    (((g * alpha / 255) & 0xFF) << 8) |
                    ((b * alpha / 255) & 0xFF);
      }
    }
  };

  // 当前行的播放进度（0 ~ 1），用于逐字填充。
  const double active_progress = ActiveLineProgress();
  last_painted_progress_ = active_progress;

  // 固定两个槽位：当前播放行在 active_index_ % 2 对应的槽位，另一个槽位
  // 预载下一行。一行唱完切到下一行时，进度直接出现在另一个槽位，两个槽位
  // 的位置始终不动。
  int y = 0;
  for (const auto& element : elements) {
    const bool has_text = !element.text.empty();
    ::SelectObject(mask_dc, font_);
    const int text_width =
        has_text ? MeasureTextWidth(mask_dc, element.text) : 0;

    if (has_text) {
      UINT format = DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS;
      int left = 0;
      int draw_width = width;
      const bool marquee = element.active && text_width > width;
      if (marquee) {
        format = DT_SINGLELINE | DT_VCENTER | DT_LEFT;
        left = -scroll_offset;
        draw_width = text_width + width;
      }
      // 阴影：先在右下偏移 1 像素处画一遍（整行，不参与逐字填充）。
      if ((shadow_color_ >> 24) != 0) {
        draw_text(font_, element.text, y, line_height, shadow_color_, 60,
                  left + 1, 1, format, draw_width, -1);
      }
      if (element.active) {
        // 未唱到的部分用「未播放颜色」铺底。
        draw_text(font_, element.text, y, line_height, unplay_color_, 100,
                  left, 0, format, draw_width, -1);
        if (active_progress > 0.0) {
          int clip_right = -1;
          if (active_progress < 1.0) {
            // 文字实际起点：跑马灯时随滚动偏移，居中时是 (窗口宽 - 文字宽) / 2。
            const int text_left_x = marquee ? left : (width - text_width) / 2;
            clip_right =
                text_left_x +
                static_cast<int>(std::lround(active_progress * text_width));
          }
          // 已经唱到的部分用「已播放颜色」覆盖上去。
          draw_text(font_, element.text, y, line_height, played_color_, 100,
                    left, 0, format, draw_width, clip_right);
        }
      } else {
        draw_text(font_, element.text, y, line_height, unplay_color_, 100,
                  left, 0, format, draw_width, -1);
      }
    }

    // 翻译 / 音译固定占用槽位内预留的行；即使当前行没有翻译，也保留空行，
    // 避免窗口高度随歌词内容变化。
    if (show_translation_ && !element.translation.empty()) {
      const int translation_y = y + line_height;
      if ((shadow_color_ >> 24) != 0) {
        draw_text(sub_font_, element.translation, translation_y,
                  sub_line_height, shadow_color_, 60, 1, 1,
                  DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS,
                  width, -1);
      }
      draw_text(sub_font_, element.translation, translation_y, sub_line_height,
                unplay_color_, 80, 0, 0,
                DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS,
                width, -1);
    }
    if (show_roman_ && !element.roman.empty()) {
      const int roman_y =
          y + line_height + (show_translation_ ? sub_line_height : 0);
      if ((shadow_color_ >> 24) != 0) {
        draw_text(sub_font_, element.roman, roman_y, sub_line_height,
                  shadow_color_, 60, 1, 1,
                  DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS,
                  width, -1);
      }
      draw_text(sub_font_, element.roman, roman_y, sub_line_height,
                unplay_color_, 80, 0, 0,
                DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS,
                width, -1);
    }
    y += slot_height;
  }

  POINT origin{0, 0};
  RECT window_rect{};
  ::GetWindowRect(window_, &window_rect);
  origin.x = window_rect.left;
  origin.y = window_rect.top;
  SIZE size{width, height};
  POINT src{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  ::UpdateLayeredWindow(window_, screen_dc, &origin, &size, canvas_dc, &src, 0,
                        &blend, ULW_ALPHA);

  ::SelectObject(canvas_dc, old_canvas);
  ::SelectObject(mask_dc, old_mask);
  ::DeleteDC(canvas_dc);
  ::DeleteDC(mask_dc);
  ::DeleteObject(canvas_bitmap);
  ::DeleteObject(mask_bitmap);
  ::ReleaseDC(window_, screen_dc);
}

void DesktopLyricWindow::ReportPosition() {
  if (!position_callback_ || window_ == nullptr) {
    return;
  }
  RECT rect{};
  ::GetWindowRect(window_, &rect);
  int screen_left = 0;
  int screen_top = 0;
  int screen_width = 0;
  int screen_height = 0;
  GetVirtualScreen(&screen_left, &screen_top, &screen_width, &screen_height);
  // RECT 的字段是 LONG，这里先转成 int，避免 std::max 的模板类型推导失败。
  const int window_width = static_cast<int>(rect.right - rect.left);
  const int window_height = static_cast<int>(rect.bottom - rect.top);
  const double x = (static_cast<int>(rect.left) - screen_left) * 100.0 /
                   std::max(1, screen_width - window_width);
  const double y = (static_cast<int>(rect.top) - screen_top) * 100.0 /
                   std::max(1, screen_height - window_height);
  // 同步内部位置，避免后续应用配置时窗口跳回旧位置。
  position_x_ = x;
  position_y_ = y;
  position_callback_(x, y);
}

LRESULT CALLBACK DesktopLyricWindow::WindowProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  DesktopLyricWindow& self = Instance();
  if (message == WM_NCCREATE) {
    self.window_ = hwnd;
    ::SetTimer(hwnd, kTimerId, kTimerIntervalMs, nullptr);
    return TRUE;
  }
  return self.HandleMessage(hwnd, message, wparam, lparam);
}

LRESULT DesktopLyricWindow::HandleMessage(HWND hwnd,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
      // 拖动窗口期间完全不动窗口（含 SetWindowPos / UpdateLayeredWindow），
      // 否则会与系统拖动逻辑互相拉扯，表现为抖动闪烁。
      if (dragging_) {
        return 0;
      }
      // 只在当前歌词行变化、或需要动画（跑马灯滚动 / 逐字填充）时重绘。
      // 暂停、以及当前行已唱完时都不重绘，避免无谓刷新导致闪烁。
      if (AdvanceActiveIndex() || NeedsAnimationFrame()) {
        Paint();
      }
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps{};
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_LBUTTONDOWN: {
      // 交给系统的「标题栏拖动」逻辑移动窗口：
      // 窗口跟随鼠标且不需要重绘，拖动时不会闪烁；
      // 用屏幕坐标计算也不会出现「指针与窗口距离越来越远」的问题。
      ::ReleaseCapture();
      ::SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      return 0;
    }
    case WM_ENTERSIZEMOVE:
      // 系统拖动窗口期间不重绘：UpdateLayeredWindow 与拖动同时进行会闪。
      dragging_ = true;
      return 0;
    case WM_EXITSIZEMOVE: {
      // 拖动结束：把新位置回传给 Dart 侧持久化，并补一帧（拖动期间冻结了）。
      dragging_ = false;
      ReportPosition();
      Paint();
      return 0;
    }
    case WM_DESTROY:
      ::KillTimer(hwnd, kTimerId);
      window_ = nullptr;
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace mintmusic
