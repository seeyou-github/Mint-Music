import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/pagination/page_slicer.dart';

/// 模拟「接口每页返回 [perPage] 条」的分页接口。
class _FakeApi {
  _FakeApi({required this.total, required this.perPage});

  final int total;
  final int perPage;
  int page = 0;

  bool hasMore(int loaded) => loaded < total;

  /// 返回这一接口页的数据（已到末尾时返回空）。
  List<int> fetchNext() {
    page += 1;
    final from = (page - 1) * perPage;
    if (from >= total) return const [];
    final to = (from + perPage) > total ? total : from + perPage;
    return [for (var i = from; i < to; i++) i + 1];
  }
}

/// 按「当前页需要多少条就取多少接口页」的规则补齐数据，返回当前页切片。
Future<List<int>> _loadPage(
  PageSlicer pager,
  _FakeApi api,
  List<int> loaded,
) async {
  var guard = 0;
  while (guard++ < 30) {
    if (pager.missing(loaded.length, hasMore: api.hasMore(loaded.length)) ==
        0) {
      break;
    }
    final before = loaded.length;
    loaded.addAll(api.fetchNext());
    if (loaded.length == before) break; // 接口没数据了
  }
  return pager.slice(loaded);
}

void main() {
  group('PageSlicer 基本行为', () {
    test('每页条数与页数', () {
      final pager = PageSlicer(pageSize: 10);
      expect(pager.page, 1);
      expect(pager.pageCount(0, hasMore: true), 1);
      // 已加载 10 条且还有更多 → 多给一个页码入口
      expect(pager.pageCount(10, hasMore: true), 2);
      expect(pager.pageCount(10, hasMore: false), 1);
      expect(pager.pageCount(25, hasMore: false), 3);
      expect(pager.pageCount(25, hasMore: true), 4);
    });

    test('切片与缺失计算', () {
      final pager = PageSlicer(pageSize: 3);
      final all = [1, 2, 3, 4, 5, 6, 7];
      expect(pager.slice(all), [1, 2, 3]);
      expect(pager.missing(7, hasMore: true), 0);
      pager.jumpTo(3);
      expect(pager.slice(all), [7]);
      expect(pager.missing(7, hasMore: true), 2);
      expect(pager.missing(7, hasMore: false), 0);
      // 超出数据范围时页码收回
      pager.jumpTo(9);
      pager.clampTo(7, hasMore: false);
      expect(pager.page, 3);
    });
  });

  group('接口条数与每页条数不一致时的缓冲', () {
    test('接口一次给 65 条 / 每页 30：多出的留到下一页', () async {
      final api = _FakeApi(total: 65, perPage: 65);
      final pager = PageSlicer(pageSize: 30);
      final loaded = <int>[];

      // 第 1 页：取一次接口就够（65 >= 30）
      expect(await _loadPage(pager, api, loaded), [
        for (var i = 1; i <= 30; i++) i,
      ]);
      expect(api.page, 1);
      expect(loaded.length, 65);

      // 第 2 页：31~60，缓冲里还有，不用再请求
      pager.next();
      expect(await _loadPage(pager, api, loaded), [
        for (var i = 31; i <= 60; i++) i,
      ]);
      expect(api.page, 1);

      // 第 3 页：61~65，仍不用请求
      pager.next();
      expect(await _loadPage(pager, api, loaded), [61, 62, 63, 64, 65]);
      expect(api.page, 1);
    });

    test('接口一次给 65 条、总量更多时，缺了才继续取', () async {
      final api = _FakeApi(total: 130, perPage: 65);
      final pager = PageSlicer(pageSize: 30);
      final loaded = <int>[];

      await _loadPage(pager, api, loaded);
      expect(api.page, 1);

      // 第 3 页要 90 条，65 不够 → 再取一次
      pager.jumpTo(3);
      final page3 = await _loadPage(pager, api, loaded);
      expect(page3.first, 61);
      expect(page3.last, 90);
      expect(api.page, 2);
    });

    test('接口每页 20 条 / 每页 30：取两次凑一页，多出的暂存', () async {
      final api = _FakeApi(total: 100, perPage: 20);
      final pager = PageSlicer(pageSize: 30);
      final loaded = <int>[];

      // 第 1 页：需要 30 → 取两次接口（40 条），显示 1~30
      final page1 = await _loadPage(pager, api, loaded);
      expect(page1.first, 1);
      expect(page1.last, 30);
      expect(api.page, 2);
      expect(loaded.length, 40); // 31~40 暂存

      // 第 2 页：31~60（缓冲里已有 31~40，只需再取一次）
      pager.next();
      final page2 = await _loadPage(pager, api, loaded);
      expect(page2.first, 31);
      expect(page2.last, 60);
      expect(api.page, 3);
      expect(loaded.length, 60);

      // 第 3 页：61~90
      pager.next();
      final page3 = await _loadPage(pager, api, loaded);
      expect(page3.first, 61);
      expect(page3.last, 90);
      expect(api.page, 5);
    });

    test('接口到末尾后不再请求', () async {
      final api = _FakeApi(total: 25, perPage: 20);
      final pager = PageSlicer(pageSize: 30);
      final loaded = <int>[];

      final page1 = await _loadPage(pager, api, loaded);
      expect(page1.length, 25);
      expect(api.page, 2);

      pager.next();
      final page2 = await _loadPage(pager, api, loaded);
      expect(page2, isEmpty);
      expect(api.page, 2);
      expect(pager.pageCount(loaded.length, hasMore: false), 1);
    });
  });

  test('搜索结果：每页条数按接口首页返回量（25~50）', () {
    final pager = PageSlicer(pageSize: 30);
    expect(25.clamp(25, 50), 25);
    expect(65.clamp(25, 50), 50);
    pager.updatePageSize(25);
    expect(pager.pageSize, 25);
    expect(pager.pageCount(50, hasMore: false), 2);
  });
}
