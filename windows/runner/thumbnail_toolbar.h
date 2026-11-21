#ifndef RUNNER_THUMBNAIL_TOOLBAR_H_
#define RUNNER_THUMBNAIL_TOOLBAR_H_

#include <windows.h>

namespace mintmusic {

// 任务栏缩略图工具栏的按钮 ID（点击后通过 WM_COMMAND 回调给窗口）。
constexpr int kThumbnailButtonPrevious = 1001;
constexpr int kThumbnailButtonPlayPause = 1002;
constexpr int kThumbnailButtonNext = 1003;

// 任务栏缩略图工具栏。
//
// 鼠标悬停任务栏图标时，系统会在缩略图下方显示一排按钮。应用通过
// ITaskbarList3::ThumbBarSetImageList + ThumbBarAddButtons 把按钮交给
// 系统绘制，点击按钮会以 WM_COMMAND 的形式回传按钮 ID。
class ThumbnailToolbar {
 public:
  // 给窗口挂上缩略图工具栏。
  //
  // 必须在收到 "TaskbarButtonCreated" 窗口消息之后调用（任务栏按钮创建
  // 完成后系统才会发送该消息）。
  static void Attach(HWND window);

  // 切换播放/暂停按钮的图标（true = 正在播放，显示暂停图标）。
  static void SetPlaying(bool playing);

  // 工具栏是否已经挂载成功。
  static bool IsAttached();
};

}  // namespace mintmusic

#endif  // RUNNER_THUMBNAIL_TOOLBAR_H_
