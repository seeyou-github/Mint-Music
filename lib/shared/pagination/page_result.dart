class PageResult<T> {
  const PageResult({this.items = const [], this.total, this.isEnd});

  final List<T> items;
  final int? total;
  final bool? isEnd;
}
