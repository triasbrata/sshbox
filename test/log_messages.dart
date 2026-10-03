/// A log as the lines' messages alone, each without its timestamp and level.
///
/// A "the log holds no X" assertion must read this and not the raw log: a
/// short planted number (1985) is found by chance in a timestamp's
/// microseconds, which says nothing about a leak.
String logMessages(String log) => log
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'^\d{4}-\d\d-\d\dT\S+ [IWE] '), ''))
    .join('\n');
