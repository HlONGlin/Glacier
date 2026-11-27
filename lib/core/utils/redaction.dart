String redactSensitiveText(String input) {
  var s = input;

  s = s.replaceAllMapped(
    RegExp(r':\/\/([^\/\s:@]+):([^\/\s@]+)@'),
    (_) => '://***:***@',
  );

  s = s.replaceAllMapped(
    RegExp(
        r'([?&](?:api[_-]?key|apikey|token|access[_-]?token|x-emby-token)=)[^&\s]+',
        caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  s = s.replaceAllMapped(
    RegExp(r'(Authorization\s*[:=]\s*Basic\s+)[A-Za-z0-9+/=_-]+',
        caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  s = s.replaceAllMapped(
    RegExp(r'((?:password|passwd|pwd)\s*[:=]\s*)[^,;\s]+',
        caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  s = s.replaceAllMapped(
    RegExp(
        r'(["\x27]?(?:X-Emby-Token|api[_-]?key|access[_-]?token|password|passwd|pwd|token)["\x27]?\s*[:=]\s*["\x27]?)[^,;\s"\x27}]+',
        caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  return s;
}
