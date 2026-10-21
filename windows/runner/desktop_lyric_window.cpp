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
constexpr int kTimerIntervalMs = 50;

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

void DesktopLyricWindow::UpdateConfig(bool is_lock,
                                       int max_line_num,
                                       int font_size,
                                       int opacity_percent,
                                       unsigned int played_color,
                                       unsigned int unplay_color,
                                       unsigned int shadow_color,
                                       double position_x,
                                       double position_y,
                                       const std::wstring& font_family,
                                       const std::wstring& font_path) {
  is_lock_ = is_lock;
  max_line_num_ = std::max(1, max_line_num);
  font_size_ = std::max(10, font_size);
  opacity_percent_ = std::max(10, std::min(100, opacity_percent));
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
  } else if (font_path.empty() && !loaded_font_path_.empty()) {
    loaded_font_path_.clear();
    font_family_.clear();
  }

  if (font_ != nullptr) {
    ::DeleteObject(font_);
    font_ = nullptr;
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
    const ULONGLONG now = ::GetTickCount64();
    if (is_playing) {
      // 恢复播放：把暂停期间的时间从跑马灯计时里扣掉，长句歌词不会因为
      // 暂停期间的时间而跳过一段。
      marquee_start_tick_ += (now - marquee_pause_tick_);
    } else {
      // 暂停：记下暂停时刻，滚动动画随之停住。
      marquee_pause_tick_ = now;
    }
    is_playing_ = is_playing;
    // 暂停/恢复时重绘一次，让滚动位置立刻停住 / 继续。
    if (window_ != nullptr) {
      Paint();
    }
    return;
  }
  is_playing_ = is_playing;
}

void DesktopLyricWindow::EnsureFont() {
  if (font_ != nullptr) {
    return;
  }
  // 优先使用应用里选择的字体。
  if (!font_family_.empty()) {
    font_ = ::CreateFontW(
        -font_size_, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, font_family_.c_str());
  }
  if (font_ == nullptr) {
    font_ = ::CreateFontW(
        -font_size_, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
  }
  if (font_ == nullptr) {
    font_ = ::CreateFontW(
        -font_size_, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"SimHei");
  }
}

/// 组装当前要绘制的歌词元素：当前行（高亮）+ 后续行。
std::vector<DesktopLyricElement> DesktopLyricWindow::BuildElements() const {
  std::vector<DesktopLyricElement> elements;
  if (active_index_ < 0 ||
      active_index_ >= static_cast<int>(lines_.size())) {
    return elements;
  }
  for (int i = active_index_;
       i < static_cast<int>(lines_.size()) &&
       (i - active_index_) < max_line_num_ &&
       static_cast<int>(elements.size()) < max_line_num_;
       i++) {
    const bool is_active = (i == active_index_);
    DesktopLyricElement main;
    main.text = lines_[i].text;
    main.color = is_active ? played_color_ : unplay_color_;
    main.alpha_scale = 100;
    main.active = is_active;
    main.centered = is_active;
    elements.push_back(main);

    if (show_translation_ && !lines_[i].translation.empty() &&
        static_cast<int>(elements.size()) < max_line_num_) {
      DesktopLyricElement translation;
      translation.text = lines_[i].translation;
      translation.color = unplay_color_;
      translation.alpha_scale = 80;
      translation.centered = is_active;
      elements.push_back(translation);
    }
    if (show_roman_ && !lines_[i].roman.empty() &&
        static_cast<int>(elements.size()) < max_line_num_) {
      DesktopLyricElement roman;
      roman.text = lines_[i].roman;
      roman.color = unplay_color_;
      roman.alpha_scale = 80;
      roman.centered = is_active;
      elements.push_back(roman);
    }
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

  // 高度按歌词行数计算：每行只显示一行文字，超长时横向滚动而不是换行。
  const int height = std::max(GetLineHeight(), MeasureContentHeight());

  int x = screen_left + static_cast<int>(position_x_ / 100.0 *
                                        std::max(0, screen_width - width));
  int y = screen_top + static_cast<int>(position_y_ / 100.0 *
                                        std::max(0, screen_height - height));
  if (x < screen_left) x = screen_left;
  if (y < screen_top) y = screen_top;

  // 锁定：点击穿透到下层内容；未锁定：可以拖动。
  LONG_PTR ex_style = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  if (is_lock_) {
    ex_style |= WS_EX_TRANSPARENT;
  }
  ::SetWindowLongPtrW(window_, GWL_EXSTYLE, ex_style);

  // 桌面歌词始终置顶显示（不锁定时同样置顶）。
  ::SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
}

/// 测量歌词内容所需的高度（每行固定一个行高，不再按文字长度换行）。
int DesktopLyricWindow::MeasureContentHeight() const {
  const std::vector<DesktopLyricElement> elements = BuildElements();
  if (elements.empty()) {
    return GetLineHeight();
  }
  return static_cast<int>(elements.size()) * GetLineHeight();
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
  const ULONGLONG now = ::GetTickCount64();
  const long long position =
      anchor_position_ms_ + static_cast<long long>(now - anchor_tick_);
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
  const int global_alpha = opacity_percent_ * 255 / 100;
  // 文字固定居中显示。
  const UINT align_flag = DT_CENTER;

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
  auto draw_text = [&](const std::wstring& text, int y, int height,
                       unsigned int color, int alpha_scale, int left,
                       int top_offset, UINT format, int draw_width) {
    if (text.empty() || height <= 0 || draw_width <= 0) {
      return;
    }
    std::memset(mask_bits, 0, pixel_count * 4);
    ::SelectObject(mask_dc, font_);
    RECT text_rect{left, y + top_offset, left + draw_width,
                   y + top_offset + height};
    ::DrawTextW(mask_dc, text.c_str(), -1, &text_rect, format | DT_NOPREFIX);
    const uint32_t alpha_base = ((color >> 24) & 0xFF) * alpha_scale / 100;
    // 再乘上整体不透明度（设置里的「不透明度」）。
    const uint32_t alpha_limit = alpha_base * global_alpha / 255;
    for (size_t i = 0; i < pixel_count; i++) {
      const uint32_t coverage = mask[i] & 0xFF;
      if (coverage == 0) {
        continue;
      }
      const uint32_t alpha = coverage * alpha_limit / 255;
      if (alpha == 0) {
        continue;
      }
      const uint32_t r = (color & 0x00FF0000) >> 16;
      const uint32_t g = (color & 0x0000FF00) >> 8;
      const uint32_t b = (color & 0x000000FF);
      canvas[i] = (alpha << 24) | (((r * alpha / 255) & 0xFF) << 16) |
                   (((g * alpha / 255) & 0xFF) << 8) | ((b * alpha / 255) & 0xFF);
    }
  };

  // 逐个元素绘制：一行歌词固定占一个行高。
  // * 正在播放的行居中显示，超长时横向滚动；
  // * 其余行按「水平对齐」设置绘制，超长时用省略号截断。
  int y = 0;
  for (const auto& element : elements) {
    if (element.text.empty()) {
      continue;
    }
    const int element_height = line_height;
    const int text_width = MeasureTextWidth(mask_dc, element.text);
    UINT format = DT_SINGLELINE | DT_VCENTER;
    int left = 0;
    int draw_width = width;
    if (element.active && text_width > width) {
      format |= DT_LEFT;
      left = -scroll_offset;
      draw_width = text_width + width;
    } else if (element.centered) {
      // 正在播放的歌词（含其翻译 / 音译）居中显示。
      format |= DT_CENTER | DT_END_ELLIPSIS;
    } else {
      format |= align_flag | DT_END_ELLIPSIS;
    }
    // 阴影：先在右下偏移 1 像素处画一遍。
    if ((shadow_color_ >> 24) != 0) {
      draw_text(element.text, y, element_height, shadow_color_, 60, left + 1,
                1, format, draw_width);
    }
    draw_text(element.text, y, element_height, element.color,
              element.alpha_scale, left, 0, format, draw_width);
    y += element_height;
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
      // 只在当前歌词行变化、或当前行需要横向滚动时重绘，
      // 避免拖动时反复刷新导致闪烁。暂停时不再滚动，也不必重绘。
      if (AdvanceActiveIndex() || (marquee_overflow_px_ > 0 && is_playing_)) {
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
      if (is_lock_) {
        return 0;
      }
      // 交给系统的「标题栏拖动」逻辑移动窗口：
      // 窗口跟随鼠标且不需要重绘，拖动时不会闪烁；
      // 用屏幕坐标计算也不会出现「指针与窗口距离越来越远」的问题。
      ::ReleaseCapture();
      ::SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      return 0;
    }
    case WM_EXITSIZEMOVE: {
      // 拖动结束：把新位置回传给 Dart 侧持久化。
      ReportPosition();
      return 0;
    }
    case WM_RBUTTONUP: {
      // 右键切换锁定（锁定后置顶且不可拖动）。
      is_lock_ = !is_lock_;
      ApplySizeAndPosition();
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
