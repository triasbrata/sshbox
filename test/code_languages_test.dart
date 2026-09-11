import 'package:flutter_test/flutter_test.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:sshbox/src/ui/code_languages.dart';

Mode? _mode(String path) => codeThemeFor(path)?.languages.values.single.mode;

void main() {
  test('colours a file by its name', () {
    expect(_mode('/srv/app/config.yml'), langYaml);
    expect(_mode('/home/me/.zshrc'), langBash);
    expect(_mode('/srv/app/Dockerfile'), langDockerfile);
    expect(_mode('/srv/app/.env'), langIni);
    expect(_mode('/etc/systemd/system/app.service'), langIni);
  });

  test('anything under nginx is nginx, whatever it is called', () {
    expect(_mode('/etc/nginx/sites-available/default'), langNginx);
    expect(_mode('/etc/nginx/conf.d/site.conf'), langNginx);
  });

  test('leaves the rest plain rather than guessing', () {
    expect(codeThemeFor('/home/me/notes.txt'), isNull);
    expect(codeThemeFor('/home/me/README'), isNull);
    expect(codeThemeFor('/var/log/syslog'), isNull);
  });
}
