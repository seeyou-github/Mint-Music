import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 歌曲列表在 Windows 上统一使用加宽的行边距。
///
/// 原来共享列表是「行左 12dp / 行右 0dp + 更多按钮内自带约 12dp」，本地列表
/// 是「外层 8dp + 行内 4dp」，鼠标操作下序号和「更多」按钮都太贴边。
/// Windows 上按下面的常量统一放大并保证左右严格对齐；
/// Android / iOS / macOS / Linux / Web 一律保持原有紧凑布局。
bool get useWideSongRowSpacing => !kIsWeb && io.Platform.isWindows;

/// Windows 上「序号文字 / ⋮ 图标」到屏幕边缘的距离。
/// 原来约 12dp，放大到 48dp（约 4 倍）；左右取同一个值，必然相等。
const double wideSongRowEdge = 48.0;

/// 序号列、「更多」按钮各自内部留的空白。
///
/// 序号左右各留这些，序号列因此变宽、和封面拉开；同时与「更多」按钮里
/// 图标自带的 ≈12dp 内侧留白对应，保证左右视觉对称。
const double wideSongIndexInset = 12.0;

/// 行外侧 padding = 边缘距离 - 控件内侧留白 = 36dp。
/// 左右都用它，序号左边距与「更多」按钮右边距始终相等。
const double wideSongRowPadding = wideSongRowEdge - wideSongIndexInset;

/// Windows 上序号列额外增加的宽度（左右各 [wideSongIndexInset]）。
const double wideSongIndexExtra = wideSongIndexInset * 2;
