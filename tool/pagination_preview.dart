import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/shared/pagination/page_slicer.dart';
import 'package:mintmusic/shared/widgets/page_bar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
  runApp(const PaginationPreview());
}

class PaginationPreview extends StatefulWidget {
  const PaginationPreview({super.key});
  @override
  State<PaginationPreview> createState() => _PaginationPreviewState();
}

class _PaginationPreviewState extends State<PaginationPreview> {
  final pager = PageSlicer(pageSize: 10);
  int total = 400;
  int loaded = 20;
  bool known = true;
  bool dark = false;
  bool narrow = false;
  bool loading = false;

  bool get hasMore => loaded < total;

  Future<void> jump(int page) async {
    setState(() {
      pager.jumpTo(page);
      loading = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    setState(() {
      loaded = (page * 10).clamp(loaded, total);
      loading = false;
    });
  }

  void choose(int count, {bool isKnown = true}) {
    setState(() {
      total = count * 10;
      known = isKnown;
      loaded = isKnown ? 20.clamp(0, total) : 210;
      pager.jumpTo(isKnown ? 1 : 20);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = dark ? ThemeColors.dark : ThemeColors.light;
    return ProviderScope(
      overrides: [themeColorsProvider.overrideWithValue(colors)],
      child: L10n(
        locale: AppLocale.zhCn,
        child: MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: Scaffold(
            backgroundColor: colors.background,
            body: SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final n in [1, 10, 20, 40])
                          TextButton(onPressed: () => choose(n), child: Text('$n 页')),
                        TextButton(onPressed: () => choose(24, isKnown: false), child: const Text('未知总数')),
                        TextButton(onPressed: () => setState(() => dark = !dark), child: const Text('切换深浅色')),
                        TextButton(onPressed: () => setState(() => narrow = !narrow), child: const Text('切换 320 宽度')),
                      ],
                    ),
                    const SizedBox(height: 48),
                    Text('当前页 ${pager.page}；已加载 $loaded；末页 ${!hasMore}', style: TextStyle(color: colors.textPrimary)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: narrow ? 320 : 1200,
                      child: PageBar(
                        currentPage: pager.page,
                        pageCount: pager.pageCount(loaded, hasMore: hasMore, total: known ? total : null),
                        totalKnown: known || !hasMore,
                        loading: loading,
                        onChanged: jump,
                      ),
                    ),
                    const SizedBox(height: 48),
                    for (final current in [1, 8, 20])
                      SizedBox(
                        width: narrow ? 320 : 1200,
                        child: PageBar(currentPage: current, pageCount: 20, onChanged: (_) {}),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
