/// 列表分页切片：只负责「第几页、每页多少条、当前应该显示哪些」。
///
/// 数据本身由各页的 provider 累积（接口一次可能返回比一页更多/更少的条数，
/// 多出来的留在已加载列表里当缓冲，下一页直接接着用，不用重复请求）。
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

  /// 当前页（从 1 开始）。
  int get page => _page;

  bool get canGoPrev => _page > 1;

  /// 当前页第一条在整体列表里的下标。
  int get start => (_page - 1) * pageSize;

  /// 当前页最后一条之后的下标（不含）。
  int get end => _page * pageSize;

  void reset() => _page = 1;

  void jumpTo(int page) {
    _page = page < 1 ? 1 : page;
  }

  void next() => _page += 1;

  void prev() {
    if (_page > 1) _page -= 1;
  }

  /// 当前页还差多少条数据（0 表示够了，或已经没有更多了）。
  ///
  /// 小于 [pageSize] 时说明接口给的每页条数不够铺满一页，需要再取一次。
  int missing(int loaded, {required bool hasMore}) {
    if (!hasMore) return 0;
    final need = end - loaded;
    return need > 0 ? need : 0;
  }

  /// 已知数据下能翻到第几页。
  ///
  /// 总数未知时，只要还有更多数据就多留一个页码入口，点它才去接口取。
  int pageCount(int loaded, {required bool hasMore}) {
    if (loaded <= 0) return 1;
    var pages = (loaded + pageSize - 1) ~/ pageSize;
    if (hasMore) pages += 1;
    return pages < 1 ? 1 : pages;
  }

  /// 数据变少时（例如切音源 / 搜索词变化）把页码收回有效范围。
  void clampTo(int loaded, {required bool hasMore}) {
    final pages = pageCount(loaded, hasMore: hasMore);
    if (_page > pages) _page = pages;
    if (_page < 1) _page = 1;
  }

  /// 取当前页要显示的那一段。
  List<T> slice<T>(List<T> all) {
    if (all.isEmpty) return const [];
    final from = start;
    if (from >= all.length) return const [];
    final to = from + pageSize > all.length ? all.length : from + pageSize;
    return all.sublist(from, to);
  }
}
