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

struct MonitorSearch {
  RECT monitor;
  RECT work;
  bool found;
};

BOOL CALLBACK FindMonitorProc(HMONITOR monitor,
                              HDC,
                              LPRECT,
                              LPARAM param) {
  auto* search = reinterpret_cast<MonitorSearch*>(param);
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (::GetMonitorInfoW(monitor, &info) == 0) {
    return TRUE;
  }
  if (::EqualRect(&info.rcMonitor, &search->monitor) != 0) {
    search->work = info.rcWork;
    search->found = true;
    return FALSE;
  }
  return TRUE;
}

/// 在仍连接的显示器里找回 [monitor_rect] 对应的那块屏，并返回它的工作区。
///
/// 显示器被拔掉或分辨率变化后返回 false，调用方退回主显示器。
bool FindWorkAreaForMonitorRect(const RECT& monitor_rect, RECT* work_area) {
  MonitorSearch search{};
  search.monitor = monitor_rect;
  ::EnumDisplayMonitors(nullptr, nullptr, &FindMonitorProc,
                        reinterpret_cast<LPARAM>(&search));
  if (!search.found) {
    return false;
  }
  *work_area = search.work;
  return true;
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
  // 行高 = 字号 × 1.25：字形本身约 1em，剩下 0.25em 是两行之间的间距
  // （原来是 1.5 倍，行间空白 0.5em，按要求减少一半）。
  return font_size_ * 5 / 4;
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

int DesktopLyricWindow::SlotHeightFor(
    const DesktopLyricElement& element) const {
  int height = GetLineHeight();
  const int sub = GetSubLineHeight();
  if (show_translation_ && !element.translation.empty()) {
    height += sub;
  }
  if (show_roman_ && !element.roman.empty()) {
    height += sub;
  }
  return height;
}

void DesktopLyricWindow::SpriteSurface::Release() {
  // 先删 DC（同时取消位图选择），再删位图；顺序反了 DeleteObject 会失败。
  if (base_dc != nullptr) {
    ::DeleteDC(base_dc);
    base_dc = nullptr;
  }
  if (mask_dc != nullptr) {
    ::DeleteDC(mask_dc);
    mask_dc = nullptr;
  }
  if (base_bitmap != nullptr) {
    ::DeleteObject(base_bitmap);
    base_bitmap = nullptr;
  }
  if (mask_bitmap != nullptr) {
    ::DeleteObject(mask_bitmap);
    mask_bitmap = nullptr;
  }
  base = nullptr;
  mask = nullptr;
  width = 0;
  height = 0;
}

bool DesktopLyricWindow::SpriteSurface::Create(HDC reference_dc,
                                               int surface_width,
                                               int surface_height) {
  if (reference_dc == nullptr || surface_width <= 0 || surface_height <= 0) {
    return false;
  }
  if (base != nullptr && mask != nullptr && width == surface_width &&
      height == surface_height) {
    // 复用同样尺寸的表面：内容整块清空，避免残留上一段文字。
    const size_t bytes = static_cast<size_t>(surface_width) * surface_height *
                         sizeof(uint32_t);
    std::memset(base, 0, bytes);
    std::memset(mask, 0, bytes);
    return true;
  }
  Release();

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = surface_width;
  // 负高度：自上而下排列，按行处理像素。
  info.bmiHeader.biHeight = -surface_height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* base_bits = nullptr;
  void* mask_bits = nullptr;
  base_bitmap = ::CreateDIBSection(reference_dc, &info, DIB_RGB_COLORS,
                                   &base_bits, nullptr, 0);
  mask_bitmap = ::CreateDIBSection(reference_dc, &info, DIB_RGB_COLORS,
                                   &mask_bits, nullptr, 0);
  if (base_bitmap == nullptr || mask_bitmap == nullptr) {
    Release();
    return false;
  }
  base_dc = ::CreateCompatibleDC(reference_dc);
  mask_dc = ::CreateCompatibleDC(reference_dc);
  if (base_dc == nullptr || mask_dc == nullptr || base_bits == nullptr ||
      mask_bits == nullptr) {
    Release();
    return false;
  }
  ::SelectObject(base_dc, base_bitmap);
  ::SelectObject(mask_dc, mask_bitmap);
  base = static_cast<uint32_t*>(base_bits);
  mask = static_cast<uint32_t*>(mask_bits);
  width = surface_width;
  height = surface_height;
  const size_t bytes =
      static_cast<size_t>(surface_width) * surface_height * sizeof(uint32_t);
  std::memset(base, 0, bytes);
  std::memset(mask, 0, bytes);
  return true;
}

int DesktopLyricWindow::StrokePadPixels() const {
  if ((stroke_color_ >> 24) == 0 || stroke_width_ratio_ <= 0.0) {
    return 2;
  }
  // 与原 StrokePath 的画笔宽度保持一致：轮廓线以字形边界为中心，
  // 外侧最多外扩半个线宽。
  const int pen_width = std::clamp(
      static_cast<int>(std::lround(font_size_ * stroke_width_ratio_ * 2.0)),
      2, 48);
  return pen_width / 2 + 2;
}

void DesktopLyricWindow::ReleaseSprites() {
  for (auto& sprite : sprites_) {
    sprite.main.Release();
    sprite.sub.Release();
    sprite.text_width = 0;
    sprite.marquee = false;
  }
  sprites_dirty_ = true;
  sprite_window_width_ = 0;
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
  // 新建的窗口坐标固定是 (0,0,400,100)，不能据此判断所在显示器。
  placed_ = false;
  // 30ms 推进定时器由播放状态决定要不要开（见 UpdateTimer）：暂停时窗口
  // 刚建出来就不该每秒空转 33 次。
  UpdateTimer();
}

void DesktopLyricWindow::DestroyWindowIfNeeded() {
  if (window_ == nullptr) {
    return;
  }
  ::DestroyWindow(window_);
  window_ = nullptr;
  // 窗口隐藏时释放预渲染位图；下次显示再按需重建。
  ReleaseSprites();
}

void DesktopLyricWindow::UpdateConfig(int font_size,
                                       unsigned int played_color,
                                       unsigned int unplay_color,
                                       unsigned int shadow_color,
                                       unsigned int stroke_color,
                                       double stroke_width_ratio,
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
  stroke_color_ = stroke_color;
  stroke_width_ratio_ = std::clamp(stroke_width_ratio, 0.0, 0.2);
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
  // 字号 / 颜色 / 字体 / 描边都可能变了，预渲染位图全部作废。
  sprites_dirty_ = true;
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
  // 歌词文本变了，两个槽位的预渲染位图都要重做。
  sprites_dirty_ = true;
  if (window_ != nullptr) {
    ApplySizeAndPosition();
    Paint();
  }
}

void DesktopLyricWindow::UpdateTimer() {
  if (window_ == nullptr) {
    return;
  }
  if (is_playing_) {
    if (timer_running_) {
      return;
    }
    ::SetTimer(window_, kTimerId, kTimerIntervalMs, nullptr);
    timer_running_ = true;
    return;
  }
  if (!timer_running_) {
    return;
  }
  ::KillTimer(window_, kTimerId);
  timer_running_ = false;
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
    // 暂停时那 30ms 的定时器只会空转（AdvanceActiveIndex 不推进、
    // NeedsAnimationFrame 直接 false），这里把它停掉；恢复播放再起。
    UpdateTimer();
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

double DesktopLyricWindow::ActiveSungFraction() const {
  if (active_index_ < 0 ||
      active_index_ >= static_cast<int>(lines_.size())) {
    return 0.0;
  }
  const DesktopLyricLine& line = lines_[active_index_];
  if (line.words.empty()) {
    return ActiveLineProgress();
  }
  const long long position = CurrentPositionMs();
  // 逐字歌词：按「每个字的时间 + 实测字宽」累计已唱宽度再除以整行宽度。
  // 与播放详情页的逐字高亮保持一致；整行线性插值会无视字与字之间的停顿，
  // 表现为桌面歌词比详情页唱得快。
  HDC dc = ::CreateCompatibleDC(nullptr);
  double total_width = 0.0;
  double sung_width = 0.0;
  if (dc != nullptr) {
    const HFONT old_font = static_cast<HFONT>(::SelectObject(dc, font_));
    // 先量完整行：分母必须是整行宽度。边量边累加、又在当前字处 break 的话，
    // 分母只包含「已唱到当前字为止」的宽度，比率恒接近 1——表现为一句刚开始
    // 填充就贴到行尾，随后在行尾来回跳。
    std::vector<double> widths;
    widths.reserve(line.words.size());
    for (const auto& word : line.words) {
      const double word_width = std::max(
          1.0, static_cast<double>(MeasureTextWidth(dc, word.text)));
      widths.push_back(word_width);
      total_width += word_width;
    }
    for (size_t i = 0; i < line.words.size(); i++) {
      const DesktopLyricWord& word = line.words[i];
      long long start = word.start_ms;
      long long end = word.end_ms;
      if (end <= start) {
        end = start + 1;
      }
      if (position <= start) {
        break;  // 这个字还没唱到，后面的都没唱
      }
      if (position >= end) {
        sung_width += widths[i];  // 整个字唱完
      } else {
        // 唱到这个字的中间：按时间在字宽里线性推进，后面的一律没唱。
        sung_width += widths[i] * static_cast<double>(position - start) /
                      static_cast<double>(end - start);
        break;
      }
    }
    ::SelectObject(dc, old_font);
    ::DeleteDC(dc);
  }
  if (total_width <= 0.0) {
    return ActiveLineProgress();
  }
  double fraction = sung_width / total_width;
  if (fraction < 0.0) fraction = 0.0;
  if (fraction > 1.0) fraction = 1.0;
  return fraction;
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
  return ActiveSungFraction() != last_painted_progress_;
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

void DesktopLyricWindow::GetTargetWorkArea(RECT* work_area) {
  // 窗口已经摆放好：跟随它当前所在的显示器（用户可能把它拖到了另一块屏）。
  if (window_ != nullptr && placed_) {
    MONITORINFO info{};
    info.cbSize = sizeof(MONITORINFO);
    HMONITOR monitor =
        ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr && ::GetMonitorInfoW(monitor, &info) != 0) {
      monitor_rect_ = info.rcMonitor;
      has_monitor_ = true;
      *work_area = info.rcWork;
      return;
    }
  }
  // 刚创建 / 重新显示：回到上次所在的显示器，隐藏再显示位置才不会变。
  if (has_monitor_ && FindWorkAreaForMonitorRect(monitor_rect_, work_area)) {
    return;
  }
  // 第一次显示，或原来的显示器已不存在：使用主显示器工作区。
  if (::SystemParametersInfo(SPI_GETWORKAREA, 0, work_area, 0) != 0 &&
      work_area->right > work_area->left &&
      work_area->bottom > work_area->top) {
    return;
  }
  // 取不到工作区时退回整个虚拟屏幕。
  int virtual_left = 0;
  int virtual_top = 0;
  int virtual_width = 0;
  int virtual_height = 0;
  GetVirtualScreen(&virtual_left, &virtual_top, &virtual_width, &virtual_height);
  *work_area = RECT{virtual_left, virtual_top, virtual_left + virtual_width,
                    virtual_top + virtual_height};
}

void DesktopLyricWindow::RememberMonitor() {
  if (window_ == nullptr) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  HMONITOR monitor = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  if (monitor != nullptr && ::GetMonitorInfoW(monitor, &info) != 0) {
    monitor_rect_ = info.rcMonitor;
    has_monitor_ = true;
  }
}

void DesktopLyricWindow::ApplySizeAndPosition() {
  if (window_ == nullptr) {
    return;
  }
  // 使用「工作区」（去掉任务栏后的可用区域），而不是整个虚拟屏幕。
  RECT work_area{};
  GetTargetWorkArea(&work_area);
  const int screen_left = work_area.left;
  const int screen_top = work_area.top;
  const int screen_width = work_area.right - work_area.left;
  const int screen_height = work_area.bottom - work_area.top;

  // 窗口宽度固定为工作区宽度的 80%（不再由设置项控制）。
  const int width = std::max(200, screen_width * 80 / 100);

  // 高度固定为两个槽位（含为翻译 / 音译预留的行），不随歌词内容变化。
  const int height = std::max(GetLineHeight(), MeasureContentHeight());

  const int max_x = std::max(0, screen_width - width);
  const int max_y = std::max(0, screen_height - height);
  // 四舍五入而不是截断：拖动结束后存的是百分比，回算时若截断会每次都
  // 少 1 像素，多次显示 / 隐藏后位置逐渐漂移。
  int x = screen_left +
          static_cast<int>(std::lround(position_x_ / 100.0 * max_x));
  int y = screen_top +
          static_cast<int>(std::lround(position_y_ / 100.0 * max_y));
  x = std::clamp(x, screen_left, screen_left + max_x);
  y = std::clamp(y, screen_top, screen_top + max_y);

  // 桌面歌词始终置顶显示，并且始终可以拖动（锁定功能已固定为关闭）。
  ::SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
  placed_ = true;
  RememberMonitor();
}

/// 测量歌词内容所需的高度：固定两个槽位。
///
/// 每个槽位只按**实际会画出来**的行计算（没有翻译 / 音译就不预留空行），
/// 这样两行歌词正好贴着窗口的上下边框，不会出现底部一大片空白。
int DesktopLyricWindow::MeasureContentHeight() const {
  const std::vector<DesktopLyricElement> elements = BuildElements();
  int total = 0;
  for (const auto& element : elements) {
    total += SlotHeightFor(element);
  }
  return std::max(GetLineHeight(), total);
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
  // 两个槽位显示的内容整体换了一轮（当前行 / 下一行）。
  sprites_dirty_ = true;
  ApplySizeAndPosition();
  return true;
}

void DesktopLyricWindow::RenderSpriteRow(SpriteSurface* surface,
                                         HFONT font,
                                         const std::wstring& text,
                                         UINT format,
                                         int x,
                                         int y,
                                         int content_width,
                                         int row_height,
                                         unsigned int color,
                                         int alpha_scale) {
  if (surface == nullptr || surface->base == nullptr ||
      surface->mask == nullptr || surface->mask_dc == nullptr ||
      font == nullptr || text.empty() || content_width <= 0 ||
      row_height <= 0) {
    return;
  }
  const int surface_width = surface->width;
  const int surface_height = surface->height;
  const size_t pixel_count = static_cast<size_t>(surface_width) *
                             static_cast<size_t>(surface_height);
  // 整体不透明度固定 80%，与以前的整窗合成一致。
  constexpr uint32_t kGlobalAlpha = 80 * 255 / 100;

  HDC dc = surface->mask_dc;
  const HGDIOBJ old_font = ::SelectObject(dc, font);
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(255, 255, 255));

  // 把 mask（黑底白字）按颜色合成到 base；只处理有覆盖的像素。
  auto composite = [&](unsigned int source_color, int alpha_scale) {
    const uint32_t alpha_base =
        ((source_color >> 24) & 0xFF) * alpha_scale / 100;
    const uint32_t alpha_limit = alpha_base * kGlobalAlpha / 255;
    const uint32_t r = (source_color & 0x00FF0000) >> 16;
    const uint32_t g = (source_color & 0x0000FF00) >> 8;
    const uint32_t b = source_color & 0x000000FF;
    for (size_t i = 0; i < pixel_count; ++i) {
      const uint32_t coverage = surface->mask[i] & 0xFF;
      if (coverage == 0) {
        continue;
      }
      const uint32_t alpha = coverage * alpha_limit / 255;
      if (alpha == 0) {
        continue;
      }
      surface->base[i] = (alpha << 24) | (((r * alpha / 255) & 0xFF) << 16) |
                         (((g * alpha / 255) & 0xFF) << 8) |
                         ((b * alpha / 255) & 0xFF);
    }
  };

  // 每一遍都先清空 mask，最后一遍画完文字后 mask 里只剩字形覆盖率。
  // 阴影：右下偏移 1 像素。
  if ((shadow_color_ >> 24) != 0) {
    std::memset(surface->mask, 0, pixel_count * sizeof(uint32_t));
    RECT rect{x + 1, y + 1, x + 1 + content_width, y + 1 + row_height};
    ::DrawTextW(dc, text.c_str(), -1, &rect, format | DT_NOPREFIX);
    composite(shadow_color_, 60);
  }

  // 描边：把 DrawText 记录成 GDI 路径，再用宽画笔描轮廓。
  if ((stroke_color_ >> 24) != 0 && stroke_width_ratio_ > 0.0) {
    std::memset(surface->mask, 0, pixel_count * sizeof(uint32_t));
    RECT rect{x, y, x + content_width, y + row_height};
    ::BeginPath(dc);
    ::DrawTextW(dc, text.c_str(), -1, &rect, format | DT_NOPREFIX);
    ::EndPath(dc);
    const int pen_width = std::clamp(
        static_cast<int>(std::lround(font_size_ * stroke_width_ratio_ * 2.0)),
        2, 48);
    HPEN pen = ::CreatePen(PS_SOLID, pen_width, RGB(255, 255, 255));
    if (pen != nullptr) {
      const HGDIOBJ old_pen = ::SelectObject(dc, pen);
      ::StrokePath(dc);
      ::SelectObject(dc, old_pen);
      ::DeleteObject(pen);
    }
    ::AbortPath(dc);
    composite(stroke_color_, 100);
  }

  // 最后只画文字：mask 最终只剩字形，逐字填充直接按它取形状。
  std::memset(surface->mask, 0, pixel_count * sizeof(uint32_t));
  RECT rect{x, y, x + content_width, y + row_height};
  ::DrawTextW(dc, text.c_str(), -1, &rect, format | DT_NOPREFIX);
  composite(color, alpha_scale);
  ::SelectObject(dc, old_font);
}

void DesktopLyricWindow::BuildSlotSprite(LineSprite* sprite,
                                         const DesktopLyricElement& element,
                                         int window_width) {
  if (sprite == nullptr) {
    return;
  }
  sprite->pad = StrokePadPixels();
  sprite->text_width = 0;
  sprite->marquee = false;
  sprite->main.Release();
  sprite->sub.Release();
  if (window_width <= 0) {
    return;
  }
  EnsureFont();

  const int pad = sprite->pad;
  const int line_height = GetLineHeight();
  const int sub_line_height = GetSubLineHeight();

  HDC reference = ::CreateCompatibleDC(nullptr);
  if (reference == nullptr) {
    return;
  }

  if (!element.text.empty() && font_ != nullptr) {
    const HGDIOBJ old_font = ::SelectObject(reference, font_);
    const int text_width = MeasureTextWidth(reference, element.text);
    ::SelectObject(reference, old_font);
    sprite->text_width = text_width;
    const bool over_wide = text_width > window_width;
    // 只有当前行超宽才滚动；其余超宽行居中显示省略号。
    sprite->marquee = element.active && over_wide;
    // 比实测宽度多留几像素：斜体 / 悬空的最后一笔不会贴在位图边缘被裁掉。
    constexpr int kTextRightMargin = 4;
    const int content_width =
        sprite->marquee
            ? text_width + kTextRightMargin
            : (over_wide ? window_width : text_width + kTextRightMargin);
    if (content_width > 0 &&
        sprite->main.Create(reference, content_width + pad * 2,
                            line_height + pad * 2)) {
      UINT format = DT_SINGLELINE | DT_VCENTER;
      if (sprite->marquee || !over_wide) {
        format |= DT_LEFT;
      } else {
        format |= DT_CENTER | DT_END_ELLIPSIS;
      }
      RenderSpriteRow(&sprite->main, font_, element.text, format, pad, pad,
                      content_width, line_height, unplay_color_, 100);
    }
  }

  int sub_rows = 0;
  if (show_translation_ && !element.translation.empty()) {
    sub_rows++;
  }
  if (show_roman_ && !element.roman.empty()) {
    sub_rows++;
  }
  if (sub_rows > 0 && sub_font_ != nullptr &&
      sprite->sub.Create(reference, window_width + pad * 2,
                         sub_rows * sub_line_height + pad * 2)) {
    const UINT format =
        DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_END_ELLIPSIS;
    int row = 0;
    if (show_translation_ && !element.translation.empty()) {
      RenderSpriteRow(&sprite->sub, sub_font_, element.translation, format,
                      pad, pad + row * sub_line_height, window_width,
                      sub_line_height, unplay_color_, 80);
      row++;
    }
    if (show_roman_ && !element.roman.empty()) {
      RenderSpriteRow(&sprite->sub, sub_font_, element.roman, format, pad,
                      pad + row * sub_line_height, window_width,
                      sub_line_height, unplay_color_, 80);
    }
  }
  ::DeleteDC(reference);
}

void DesktopLyricWindow::BlendSpriteIntoCanvas(uint32_t* dst,
                                               int dst_width,
                                               int dst_height,
                                               const uint32_t* src,
                                               int src_width,
                                               int src_height,
                                               int dst_x,
                                               int dst_y) {
  if (dst == nullptr || src == nullptr || dst_width <= 0 ||
      dst_height <= 0 || src_width <= 0 || src_height <= 0) {
    return;
  }
  const int src_x0 = std::max(0, -dst_x);
  const int src_y0 = std::max(0, -dst_y);
  const int src_x1 = std::min(src_width, dst_width - dst_x);
  const int src_y1 = std::min(src_height, dst_height - dst_y);
  if (src_x0 >= src_x1 || src_y0 >= src_y1) {
    return;
  }
  for (int sy = src_y0; sy < src_y1; ++sy) {
    const uint32_t* src_row = src + static_cast<size_t>(sy) * src_width;
    uint32_t* dst_row =
        dst + static_cast<size_t>(dst_y + sy) * dst_width + dst_x;
    for (int sx = src_x0; sx < src_x1; ++sx) {
      const uint32_t s = src_row[sx];
      const uint32_t sa = (s >> 24) & 0xFF;
      if (sa == 0) {
        continue;
      }
      uint32_t& d = dst_row[sx];
      // 画布是全透明底，绝大多数像素直接拷贝。
      if (sa == 255 || d == 0) {
        d = s;
        continue;
      }
      // 预乘 alpha 的 src-over。
      const uint32_t inv = 255 - sa;
      const uint32_t out_a = sa + ((d >> 24) & 0xFF) * inv / 255;
      const uint32_t out_r =
          ((s >> 16) & 0xFF) + (((d >> 16) & 0xFF) * inv) / 255;
      const uint32_t out_g =
          ((s >> 8) & 0xFF) + (((d >> 8) & 0xFF) * inv) / 255;
      const uint32_t out_b = (s & 0xFF) + ((d & 0xFF) * inv) / 255;
      d = (std::min(out_a, 255u) << 24) |
          (std::min(out_r, 255u) << 16) | (std::min(out_g, 255u) << 8) |
          std::min(out_b, 255u);
    }
  }
}

void DesktopLyricWindow::PaintPlayedFill(uint32_t* canvas,
                                         int canvas_width,
                                         int canvas_height,
                                         const LineSprite& sprite,
                                         int blit_x,
                                         int blit_y,
                                         double fraction) const {
  const SpriteSurface& surface = sprite.main;
  if (canvas == nullptr || surface.mask == nullptr ||
      sprite.text_width <= 0 || fraction <= 0.0) {
    return;
  }
  const double clamped = std::clamp(fraction, 0.0, 1.0);
  int fill_width =
      static_cast<int>(std::lround(clamped * sprite.text_width));
  fill_width = std::clamp(fill_width, 0, sprite.text_width);
  if (fill_width <= 0) {
    return;
  }
  const int line_height = GetLineHeight();
  const uint32_t alpha_limit =
      ((played_color_ >> 24) & 0xFF) * (80 * 255 / 100) / 255;
  const uint32_t r = (played_color_ & 0x00FF0000) >> 16;
  const uint32_t g = (played_color_ & 0x0000FF00) >> 8;
  const uint32_t b = played_color_ & 0x000000FF;

  for (int ly = 0; ly < line_height; ++ly) {
    const int local_y = sprite.pad + ly;
    if (local_y < 0 || local_y >= surface.height) {
      continue;
    }
    const int canvas_y = blit_y + local_y;
    if (canvas_y < 0 || canvas_y >= canvas_height) {
      continue;
    }
    const uint32_t* mask_row =
        surface.mask + static_cast<size_t>(local_y) * surface.width;
    uint32_t* dst_row = canvas + static_cast<size_t>(canvas_y) * canvas_width;
    for (int lx = 0; lx < fill_width; ++lx) {
      const int local_x = sprite.pad + lx;
      if (local_x >= surface.width) {
        break;
      }
      const uint32_t coverage = mask_row[local_x] & 0xFF;
      if (coverage == 0) {
        continue;
      }
      const uint32_t alpha = coverage * alpha_limit / 255;
      if (alpha == 0) {
        continue;
      }
      const int canvas_x = blit_x + local_x;
      if (canvas_x < 0 || canvas_x >= canvas_width) {
        continue;
      }
      dst_row[canvas_x] =
          (alpha << 24) | (((r * alpha / 255) & 0xFF) << 16) |
          (((g * alpha / 255) & 0xFF) << 8) | ((b * alpha / 255) & 0xFF);
    }
  }
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

  EnsureFont();

  const int line_height = GetLineHeight();
  const int pad = StrokePadPixels();
  const std::vector<DesktopLyricElement> elements = BuildElements();

  // 位图只在歌词 / 样式 / 窗口宽度变化时重建；之后每帧只做贴图。
  if (sprites_dirty_ || sprite_window_width_ != width ||
      sprites_[0].pad != pad) {
    for (int i = 0; i < 2; i++) {
      BuildSlotSprite(&sprites_[i], elements[i], width);
    }
    sprite_window_width_ = width;
    sprites_dirty_ = false;
  }

  // 当前播放行超出窗口宽度时横向滚动（来回滚动，两端速度为 0）。
  marquee_overflow_px_ = 0;
  for (const auto& sprite : sprites_) {
    if (sprite.marquee && sprite.text_width > width) {
      marquee_overflow_px_ = sprite.text_width - width;
      break;
    }
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
  if (canvas_bitmap == nullptr || canvas_bits == nullptr) {
    if (canvas_bitmap != nullptr) {
      ::DeleteObject(canvas_bitmap);
    }
    ::ReleaseDC(window_, screen_dc);
    return;
  }
  HDC canvas_dc = ::CreateCompatibleDC(screen_dc);
  if (canvas_dc == nullptr) {
    ::DeleteObject(canvas_bitmap);
    ::ReleaseDC(window_, screen_dc);
    return;
  }
  const HGDIOBJ old_canvas = ::SelectObject(canvas_dc, canvas_bitmap);

  const size_t pixel_count =
      static_cast<size_t>(width) * static_cast<size_t>(height);
  std::memset(canvas_bits, 0, pixel_count * 4);
  auto* canvas = static_cast<uint32_t*>(canvas_bits);

  // 当前行的播放进度（0 ~ 1），用于逐字填充。逐字歌词按每个字的时间 +
  // 字宽换算；普通 LRC 退回整行线性插值。
  const double active_progress = ActiveSungFraction();
  last_painted_progress_ = active_progress;

  // 固定两个槽位：当前播放行在 active_index_ % 2 对应的槽位，另一个槽位
  // 预载下一行。一行唱完切到下一行时，进度直接出现在另一个槽位。
  int y = 0;
  for (int i = 0; i < 2; i++) {
    const DesktopLyricElement& element = elements[i];
    const LineSprite& sprite = sprites_[i];

    if (sprite.main.base != nullptr) {
      int blit_x = 0;
      if (sprite.marquee) {
        blit_x = -scroll_offset - pad;
      } else if (sprite.text_width > width) {
        // 非当前行的超长歌词：居中 + 省略号，贴图从窗口左缘开始。
        blit_x = -pad;
      } else {
        blit_x = (width - sprite.text_width) / 2 - pad;
      }
      BlendSpriteIntoCanvas(canvas, width, height, sprite.main.base,
                            sprite.main.width, sprite.main.height, blit_x,
                            y - pad);
      if (element.active && active_progress > 0.0) {
        PaintPlayedFill(canvas, width, height, sprite, blit_x, y - pad,
                        active_progress);
      }
    }
    if (sprite.sub.base != nullptr) {
      BlendSpriteIntoCanvas(canvas, width, height, sprite.sub.base,
                            sprite.sub.width, sprite.sub.height, -pad,
                            y + line_height - pad);
    }
    y += SlotHeightFor(element);
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
  ::DeleteDC(canvas_dc);
  ::DeleteObject(canvas_bitmap);
  ::ReleaseDC(window_, screen_dc);
}

void DesktopLyricWindow::ReportPosition() {
  if (!position_callback_ || window_ == nullptr) {
    return;
  }
  RECT rect{};
  ::GetWindowRect(window_, &rect);
  // 与 ApplySizeAndPosition 使用同一基准（窗口所在显示器的工作区）。之前这里
  // 用整个虚拟屏幕，保存的百分比和回算时的工作区不一致：拖动结束后窗口会
  // 跳一下，下次显示的位置也会偏移（多显示器时尤其明显）。
  RECT work_area{};
  GetTargetWorkArea(&work_area);
  const int screen_left = work_area.left;
  const int screen_top = work_area.top;
  const int screen_width = work_area.right - work_area.left;
  const int screen_height = work_area.bottom - work_area.top;
  // RECT 的字段是 LONG，这里先转成 int，避免 std::max 的模板类型推导失败。
  const int window_width = static_cast<int>(rect.right - rect.left);
  const int window_height = static_cast<int>(rect.bottom - rect.top);
  const double x = (static_cast<int>(rect.left) - screen_left) * 100.0 /
                   std::max(1, screen_width - window_width);
  const double y = (static_cast<int>(rect.top) - screen_top) * 100.0 /
                   std::max(1, screen_height - window_height);
  // 同步内部位置，避免后续应用配置时窗口跳回旧位置。拖出工作区时夹紧。
  position_x_ = std::clamp(x, 0.0, 100.0);
  position_y_ = std::clamp(y, 0.0, 100.0);
  position_callback_(position_x_, position_y_);
}

LRESULT CALLBACK DesktopLyricWindow::WindowProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  DesktopLyricWindow& self = Instance();
  if (message == WM_NCCREATE) {
    self.window_ = hwnd;
    // 定时器随播放状态起停（暂停时不必每 30ms 醒一次）。
    self.UpdateTimer();
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
      timer_running_ = false;
      window_ = nullptr;
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace mintmusic
