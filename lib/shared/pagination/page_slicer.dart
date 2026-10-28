/// 列表分页切片：只负责「第几页、每页多少条、当前应该显示哪些」。
///
/// 数据本身由各页的 provider 累积（接口一次可能返回比一页更多/更少的条数，
/// 多出来的留在已加载列表里当缓冲，下一页直接接着用，不用重复请求）。
///
/// 缓冲区默认从第 1 页开始（[bufferBase] == 1）。搜索页跳页直达时会用目标页
/// 的数据替换缓冲区并 [rebase]，此后切片从缓冲区开头算起，[absoluteStart]
/// 仍返回全局下标供序号展示。
class PageSlicer {
  PageSlicer({required this.pageSize});

  /// 调整每页条数（页码会重置到第一页）。
  void updatePageSize(int size) {
    if (size <= 0 || size == pageSize) return;
    pageSize = size;
  }

  /// 每页显示多少条（界面口径，不是接口的每页条数）。
  ///
  /// 搜索结果这类「按接口实际返回量决定」的场景，首页回来后再改一次。
  int pageSize;

  int _page = 1;

  /// 缓冲区首条对应的页码。
  int _base = 1;

  /// 当前页（从 1 开始）。
  int get page => _page;

  /// 缓冲区里最早缓存到第几页（连续追加模型恒为 1）。
  int get bufferBase => _base;

  bool get canGoPrev => _page > 1;

  /// 当前页第一条在缓冲区里的下标。
  int get start => (_page - _base) * pageSize;

  /// 当前页最后一条之后的下标（缓冲区内，不含）。
  int get end => start + pageSize;

  /// 当前页第一条在整体列表（从第 1 页起）里的全局下标。
  ///
  /// 连续追加模型下与 [start] 相同；跳页直达后缓冲区从当前页开始，
  /// 序号展示仍要用全局下标。
  int get absoluteStart => (_page - 1) * pageSize;

  void reset() {
    _page = 1;
    _base = 1;
  }

  void jumpTo(int page) {
    _page = page < 1 ? 1 : page;
  }

  /// 跳页直达后调用：缓冲区已被替换成第 [page] 页的数据。
  void rebase(int page) {
    _base = page < 1 ? 1 : page;
    _page = _base;
  }

  void next() => _page += 1;

  void prev() {
    if (_page > 1) _page -= 1;
  }

  /// 当前页还差多少条数据（0 表示够了，或已经没有更多了）。
  ///
  /// 小于 [pageSize] 时说明接口给的每页条数不够铺满一页，需要再取一次。
  /// 目标页在缓冲区起点之前（跳页加载中）时差值为负，视为 0。
  int missing(int loaded, {required bool hasMore}) {
    if (!hasMore) return 0;
    final need = end - loaded;
    return need > 0 ? need : 0;
  }

  /// 已知数据下能翻到第几页。
  ///
  /// 还有更多（[hasMore]）且 [total] 为正数时以总数为准（跳页直达的窗口
  /// 缓冲里只有一页数据，不能拿 loaded 当页数依据）。加载结束后一律按
  /// 缓冲区覆盖的页数算：上游总数可能偏大（网易云搜索常见），最后一个
  /// 空页会把窗口缓冲的页码算错。总数未知时按缓冲区已覆盖的页数算，
  /// 还有更多则多留一个页码入口，点它才去接口取。
  int pageCount(int loaded, {required bool hasMore, int? total}) {
    if (hasMore && total != null && total > 0) {
      final count = total > loaded ? total : loaded;
      return (count + pageSize - 1) ~/ pageSize;
    }
    if (loaded <= 0) {
      if (_base <= 1) return 1;
      return _page + (hasMore ? 1 : 0);
    }
    final knownPages = _base - 1 + ((loaded + pageSize - 1) ~/ pageSize);
    // 还有更多时，正在加载的远页不能被收回；加载结束后就要按缓冲区
    // 实际覆盖的页数收尾，否则上游总数偏大会留下空白末页。
    var pages = hasMore && _base > 1 && knownPages < _page ? _page : knownPages;
    if (hasMore) pages += 1;
    return pages < 1 ? 1 : pages;
  }

  /// 数据变少时把页码收回有效范围；传入 [total] 可保留正在加载的远页。
  void clampTo(int loaded, {required bool hasMore, int? total}) {
    final pages = pageCount(loaded, hasMore: hasMore, total: total);
    if (_page > pages) _page = pages;
    if (_page < 1) _page = 1;
  }

  /// 取当前页要显示的那一段。
  ///
  /// 目标页还在缓冲区之前（跳页加载中）或超出已加载数据时返回空。
  List<T> slice<T>(List<T> all) {
    if (all.isEmpty) return const [];
    final from = start;
    if (from < 0 || from >= all.length) return const [];
    final to = from + pageSize > all.length ? all.length : from + pageSize;
    return all.sublist(from, to);
  }
}
