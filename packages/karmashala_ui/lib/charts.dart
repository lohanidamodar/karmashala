/// Small, theme-aware charts painted by hand: linear and radial meters, a
/// sparkline, a time series with markers, bar charts, a segmented bar with
/// its legend, and headline stat tiles. Each carries a
/// semantics label, respects reduced motion, and sheds its axes when narrow.
library;

export 'src/charts/bar_chart.dart';
export 'src/charts/chart_support.dart'
    show ChartAlphas, ChartInk, chartMotion, drawDashedLine, kChartCompactWidth;
export 'src/charts/meters.dart';
export 'src/charts/number_format.dart';
export 'src/charts/segmented_bar.dart';
export 'src/charts/sparkline.dart';
export 'src/charts/stat_tile.dart';
export 'src/charts/time_series_chart.dart';
