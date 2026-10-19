#include "thumbnail_toolbar.h"

#include <objbase.h>
#include <shobjidl.h>

#include <cstring>
#include <windows.h>

namespace mintmusic {
namespace {

// CLSID_TaskbarList = {56FDF344-FD6D-11d0-958A-006097C9A090}
// 这里直接写死 GUID，避免依赖 uuid.lib 里的 CLSID_TaskbarList 符号。
constexpr CLSID kTaskbarListClsid = {
    0x56FDF344,
    0xFD6D,
    0x11D0,
    {0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90}};

// 图像列表中的图片下标。
constexpr int kImagePrevious = 0;
constexpr int kImagePlay = 1;
constexpr int kImagePause = 2;
constexpr int kImageNext = 3;

// 需要绘制的按钮图形。
enum class Glyph { kPrevious, kPlay, kPause, kNext };

HIMAGELIST g_image_list = nullptr;
HWND g_window = nullptr;
bool g_playing = false;
bool g_attached = false;

// 画一个 32 位 ARGB 的按钮图形。
//
// 任务栏工具栏的按钮背景由系统绘制，图形本身需要带 alpha 通道。GDI 不写
// alpha，所以画完之后再手动补一遍：非黑色像素视为图形部分，alpha 置 255。
HBITMAP CreateGlyphBitmap(UINT size, Glyph glyph) {
  const int width = size == 0 ? 16 : static_cast<int>(size);
  const int height = width;

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  // 负高度表示自上而下的 DIB，绘制坐标与屏幕方向一致。
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  HDC screen = ::GetDC(nullptr);
  if (screen == nullptr) {
    return nullptr;
  }

  void* bits = nullptr;
  HBITMAP bitmap =
      ::CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) {
      ::DeleteObject(bitmap);
    }
    ::ReleaseDC(nullptr, screen);
    return nullptr;
  }

  HDC dc = ::CreateCompatibleDC(screen);
  ::ReleaseDC(nullptr, screen);
  if (dc == nullptr) {
    ::DeleteObject(bitmap);
    return nullptr;
  }

  // CreateDIBSection 不保证清零，先把背景擦成全透明（alpha = 0）。
  std::memset(bits, 0, static_cast<size_t>(width) * height * 4);

  HGDIOBJ old_bitmap = ::SelectObject(dc, bitmap);
  ::SetBkMode(dc, TRANSPARENT);

  HPEN pen = ::CreatePen(PS_NULL, 0, RGB(0, 0, 0));
  HGDIOBJ old_pen = ::SelectObject(dc, pen);
  HBRUSH brush = ::CreateSolidBrush(RGB(255, 255, 255));
  HGDIOBJ old_brush = ::SelectObject(dc, brush);

  const int cx = width / 2;
  const int cy = height / 2;
  const int s = static_cast<int>(width * 0.3);

  switch (glyph) {
    case Glyph::kPlay: {
      POINT points[3] = {
          {cx - static_cast<LONG>(s * 0.7), cy - s},
          {cx - static_cast<LONG>(s * 0.7), cy + s},
          {cx + s, cy},
      };
      ::Polygon(dc, points, 3);
      break;
    }
    case Glyph::kPause: {
      ::Rectangle(dc, cx - s, cy - s, cx - s + s / 2, cy + s);
      ::Rectangle(dc, cx + s / 2, cy - s, cx + s, cy + s);
      break;
    }
    case Glyph::kPrevious: {
      ::Rectangle(dc, cx - s, cy - s, cx - s + s / 3, cy + s);
      POINT points[3] = {
          {cx - s / 2, cy - s},
          {cx - s / 2, cy + s},
          {cx + s, cy},
      };
      ::Polygon(dc, points, 3);
      break;
    }
    case Glyph::kNext: {
      POINT points[3] = {
          {cx - s, cy - s},
          {cx - s, cy + s},
          {cx + s / 2, cy},
      };
      ::Polygon(dc, points, 3);
      ::Rectangle(dc, cx + s - s / 3, cy - s, cx + s, cy + s);
      break;
    }
  }

  ::SelectObject(dc, old_brush);
  ::SelectObject(dc, old_pen);
  ::SelectObject(dc, old_bitmap);
  ::DeleteObject(brush);
  ::DeleteObject(pen);
  ::DeleteDC(dc);

  auto* pixels = static_cast<unsigned int*>(bits);
  const int pixel_count = width * height;
  for (int i = 0; i < pixel_count; ++i) {
    const unsigned int rgb = pixels[i] & 0x00FFFFFFu;
    pixels[i] = rgb == 0 ? 0u : (0xFF000000u | rgb);
  }

  return bitmap;
}

// 构建按钮图像列表（系统要求 32 位、SM_CXICON x SM_CYICON）。
HIMAGELIST BuildImageList() {
  const int cx = ::GetSystemMetrics(SM_CXICON);
  const int cy = ::GetSystemMetrics(SM_CYICON);
  if (cx <= 0 || cy <= 0) {
    return nullptr;
  }

  HIMAGELIST list = ::ImageList_Create(cx, cy, ILC_COLOR32, 4, 4);
  if (list == nullptr) {
    return nullptr;
  }

  const Glyph glyphs[4] = {
      Glyph::kPrevious,
      Glyph::kPlay,
      Glyph::kPause,
      Glyph::kNext,
  };
  for (const Glyph glyph : glyphs) {
    HBITMAP bitmap = CreateGlyphBitmap(static_cast<UINT>(cx), glyph);
    if (bitmap == nullptr) {
      continue;
    }
    ::ImageList_Add(list, bitmap, nullptr);
    ::DeleteObject(bitmap);
  }

  return list;
}

// 创建一个 ITaskbarList3 实例。
ITaskbarList3* CreateTaskbarList() {
  ITaskbarList3* taskbar = nullptr;
  const HRESULT result = ::CoCreateInstance(
      kTaskbarListClsid, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar));
  if (FAILED(result) || taskbar == nullptr) {
    return nullptr;
  }
  if (FAILED(taskbar->HrInit())) {
    taskbar->Release();
    return nullptr;
  }
  return taskbar;
}

}  // namespace

void ThumbnailToolbar::Attach(HWND window) {
  if (g_attached || window == nullptr) {
    return;
  }

  ITaskbarList3* taskbar = CreateTaskbarList();
  if (taskbar == nullptr) {
    return;
  }

  HIMAGELIST list = BuildImageList();
  if (list == nullptr) {
    taskbar->Release();
    return;
  }

  g_image_list = list;
  g_window = window;

  taskbar->ThumbBarSetImageList(window, g_image_list);

  THUMBBUTTON buttons[3] = {};
  buttons[0].dwMask = THB_BITMAP | THB_TOOLTIP | THB_FLAGS;
  buttons[0].iId = static_cast<UINT>(kThumbnailButtonPrevious);
  buttons[0].iBitmap = static_cast<UINT>(kImagePrevious);
  buttons[0].pszTip = const_cast<LPWSTR>(L"\u4e0a\u4e00\u9996");
  buttons[0].dwFlags = THBF_HIDEBACKGROUND;

  buttons[1].dwMask = THB_BITMAP | THB_TOOLTIP | THB_FLAGS;
  buttons[1].iId = static_cast<UINT>(kThumbnailButtonPlayPause);
  buttons[1].iBitmap = static_cast<UINT>(g_playing ? kImagePause : kImagePlay);
  buttons[1].pszTip = const_cast<LPWSTR>(L"\u64ad\u653e / \u6682\u505c");
  buttons[1].dwFlags = THBF_HIDEBACKGROUND;

  buttons[2].dwMask = THB_BITMAP | THB_TOOLTIP | THB_FLAGS;
  buttons[2].iId = static_cast<UINT>(kThumbnailButtonNext);
  buttons[2].iBitmap = static_cast<UINT>(kImageNext);
  buttons[2].pszTip = const_cast<LPWSTR>(L"\u4e0b\u4e00\u9996");
  buttons[2].dwFlags = THBF_HIDEBACKGROUND;

  const HRESULT result = taskbar->ThumbBarAddButtons(window, 3, buttons);
  taskbar->Release();

  g_attached = SUCCEEDED(result);
}

void ThumbnailToolbar::SetPlaying(bool playing) {
  if (g_playing == playing) {
    return;
  }
  g_playing = playing;

  // 工具栏还没挂上时只记录状态，等挂上时会用最新的状态画图标。
  if (!g_attached || g_window == nullptr) {
    return;
  }

  ITaskbarList3* taskbar = CreateTaskbarList();
  if (taskbar == nullptr) {
    return;
  }

  THUMBBUTTON button = {};
  button.dwMask = THB_BITMAP | THB_TOOLTIP;
  button.iId = static_cast<UINT>(kThumbnailButtonPlayPause);
  button.iBitmap = static_cast<UINT>(playing ? kImagePause : kImagePlay);
  button.pszTip = const_cast<LPWSTR>(L"\u64ad\u653e / \u6682\u505c");

  taskbar->ThumbBarUpdateButtons(g_window, 1, &button);
  taskbar->Release();
}

bool ThumbnailToolbar::IsAttached() {
  return g_attached;
}

}  // namespace mintmusic
