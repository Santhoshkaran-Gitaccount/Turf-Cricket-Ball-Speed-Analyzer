/// Display formatting shared across screens.
library;

/// Speeds are shown rounded to the nearest whole km/h.
String formatSpeed(num? kmh) => kmh == null ? '–' : '${kmh.round()} km/h';

/// Release-to-finish time, to the hundredth of a second, e.g. "0.56 s".
String formatTravelTime(Duration d) => '${(d.inMicroseconds / 1e6).toStringAsFixed(2)} s';

String formatPitchLength(double meters) {
  final text = meters == meters.roundToDouble() ? meters.toStringAsFixed(0) : meters.toStringAsFixed(2);
  return meters == 20.12 ? '$text m (22 yards)' : '$text m';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String formatTime(DateTime d) =>
    [d.hour, d.minute, d.second].map((n) => n.toString().padLeft(2, '0')).join(':');

String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '${hours}h ${minutes}m ${seconds}s' : '${minutes}m ${seconds}s';
}
