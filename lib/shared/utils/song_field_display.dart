/// 本地歌曲「专辑」字段的显示与匹配口径。
///
/// 曲库索引里，没有专辑信息的歌曲可能存着两种值：
/// * 空串（新扫描 / 用户清空专辑后）；
/// * [`unknownAlbum`] 占位（老版本扫描写入的）。
///
/// 两者都表示「没有专辑信息」：界面统一显示 `-`，匹配与写文件时按空处理，
/// 避免把「未知专辑」这四个字写进歌曲文件、或拿它去和在线结果比对专辑。
library;

/// 老版本扫描给空专辑补的占位文案。
const String unknownAlbum = '未知专辑';

/// 是否真有专辑信息（空串与「未知专辑」占位都算没有）。
bool hasAlbumInfo(String? album) {
  final text = (album ?? '').trim();
  return text.isNotEmpty && text != unknownAlbum;
}

/// 展示用：没有专辑信息时显示 `-`。
String displayAlbum(String? album) {
  final text = (album ?? '').trim();
  return hasAlbumInfo(text) ? text : '-';
}

/// 编辑表单 / 匹配用：没有专辑信息时返回空串。
///
/// 表单里不能写 `-`：它会被当成真实专辑名保存进歌曲文件。
String albumForEdit(String? album) {
  final text = (album ?? '').trim();
  return hasAlbumInfo(text) ? text : '';
}
