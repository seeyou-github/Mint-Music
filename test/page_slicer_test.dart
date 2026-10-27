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

  group('已知总数与加载完成后的校正', () {
    test('已知总数向上取整，不额外添加下一页入口', () {
      final pager = PageSlicer(pageSize: 10);
      expect(pager.pageCount(0, hasMore: true, total: 1), 1);
      expect(pager.pageCount(10, hasMore: true, total: 100), 10);
      expect(pager.pageCount(10, hasMore: true, total: 101), 11);
      expect(pager.pageCount(10, hasMore: true, total: 200), 20);
      expect(pager.pageCount(10, hasMore: true, total: 201), 21);
      // 上游低估总数时，不能丢掉已经加载的数据。
      expect(pager.pageCount(35, hasMore: true, total: 20), 4);
    });

    test('已知但未缓存的远页不会被 clampTo 收回', () {
      final pager = PageSlicer(pageSize: 10)..jumpTo(20);
      pager.clampTo(10, hasMore: true, total: 201);
      expect(pager.page, 20);
      expect(pager.missing(10, hasMore: true), 190);
      expect(pager.slice(List.generate(10, (i) => i)), isEmpty);
      pager.jumpTo(99);
      pager.clampTo(10, hasMore: true, total: 201);
      expect(pager.page, 21);
      pager.clampTo(0, hasMore: true, total: 201);
      expect(pager.page, 21);
    });

    test('加载结束后按实际 loaded 校正总数及当前页', () {
      final pager = PageSlicer(pageSize: 10)..jumpTo(20);
      expect(pager.pageCount(35, hasMore: false, total: 201), 4);
      pager.clampTo(35, hasMore: false, total: 201);
      expect(pager.page, 4);
      expect(pager.missing(35, hasMore: false), 0);
      expect(pager.slice(List.generate(35, (i) => i)), [30, 31, 32, 33, 34]);
      expect(pager.pageCount(35, hasMore: false, total: 1), 4);
      expect(pager.pageCount(0, hasMore: false, total: 201), 1);
      pager.clampTo(0, hasMore: false, total: 201);
      expect(pager.page, 1);
    });

    test('零、负数和缺省总数按未知处理，结束时至少一页', () {
      final pager = PageSlicer(pageSize: 10);
      for (final total in <int?>[null, 0, -1, -100]) {
        expect(pager.pageCount(0, hasMore: true, total: total), 1);
        expect(pager.pageCount(25, hasMore: true, total: total), 4);
        expect(pager.pageCount(25, hasMore: false, total: total), 3);
        expect(pager.pageCount(0, hasMore: false, total: total), 1);
        pager.jumpTo(20);
        pager.clampTo(25, hasMore: true, total: total);
        expect(pager.page, 4);
        pager.clampTo(25, hasMore: false, total: total);
        expect(pager.page, 3);
      }
    });

    test('远页补齐按 missing 请求，多余接口数据仍作为缓存', () async {
      final api = _FakeApi(total: 300, perPage: 65);
      final pager = PageSlicer(pageSize: 30)..jumpTo(7);
      final loaded = <int>[];
      pager.clampTo(0, hasMore: true, total: api.total);
      expect(pager.page, 7);
      expect(await _loadPage(pager, api, loaded), [
        for (var i = 181; i <= 210; i++) i,
      ]);
      expect(api.page, 4);
      expect(loaded.length, 260);
      pager.next();
      expect(await _loadPage(pager, api, loaded), [
        for (var i = 211; i <= 240; i++) i,
      ]);
      expect(api.page, 4);
      pager.updatePageSize(20);
      expect(
        pager.pageCount(loaded.length, hasMore: true, total: api.total),
        15,
      );
      expect(await _loadPage(pager, api, loaded), [
        for (var i = 141; i <= 160; i++) i,
      ]);
      expect(api.page, 4);
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

  group('跳页直达（缓冲区基页）', () {
    test('rebase 后切片从缓冲区开头算起，序号仍用全局下标', () {
      final pager = PageSlicer(pageSize: 30);
      expect(pager.bufferBase, 1);
      pager.rebase(12);
      expect(pager.bufferBase, 12);
      expect(pager.page, 12);
      expect(pager.start, 0);
      expect(pager.end, 30);
      expect(pager.absoluteStart, 330);
      // 相邻页追加后切片接续缓冲区
      pager.next();
      expect(pager.start, 30);
      expect(pager.absoluteStart, 360);
    });

    test('窗口缓冲下已知总数按总数算页数，未知总数保留当前页入口', () {
      final pager = PageSlicer(pageSize: 30)..rebase(12);
      // total=600：缓冲里只有 30 条也不能按 loaded 算成 1 页
      expect(pager.pageCount(30, hasMore: true, total: 600), 20);
      expect(pager.pageCount(30, hasMore: false, total: 600), 20);
      // 未知总数：至少给到当前页 + 下一页入口
      expect(pager.pageCount(30, hasMore: true), 13);
      expect(pager.pageCount(30, hasMore: false), 12);
    });

    test('目标页在缓冲区之前时切片为空、missing 为 0，clamp 不收回', () {
      final pager = PageSlicer(pageSize: 30)..rebase(12);
      pager.jumpTo(11);
      expect(pager.slice([1, 2, 3]), isEmpty, reason: '第 11 页还没加载');
      expect(pager.missing(30, hasMore: true), 0);
      pager.clampTo(30, hasMore: true, total: 600);
      expect(pager.page, 11, reason: '正在加载的回翻页不被 clamp 收走');
    });

    test('reset 恢复连续追加模型', () {
      final pager = PageSlicer(pageSize: 30)..rebase(12);
      pager.reset();
      expect(pager.bufferBase, 1);
      expect(pager.page, 1);
      expect(pager.absoluteStart, 0);
    });
  });
}
