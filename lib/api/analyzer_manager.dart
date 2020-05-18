import 'package:eso/api/analyzer.dart';
import 'package:eso/api/analyzer_html.dart';
import 'package:eso/api/analyzer_js.dart';
import 'package:eso/api/analyzer_jsonpath.dart';
import 'package:eso/api/analyzer_regexp.dart';
import 'package:eso/api/analyzer_xpath.dart';

class AnalyzerManager {
  final dynamic _content;
  final int _idJsEngine;

  AnalyzerManager(this._content, this._idJsEngine);

  /// from https://github.com/dart-lang/sdk/issues/2336
  String Function(Match) _replacement(String pattern) => (Match match) =>
      pattern.replaceAllMapped(RegExp(r'\$(\d+)'), (m) => match[int.parse(m[1])]);

  String Function(String) replaceSmart(String replace) {
    if (null == replace || replace.isEmpty) return (String s) => s;
    final r = replace.split("##");
    final match = RegExp(r[0]);
    if (r.length == 1) {
      return (String s) => s.replaceAll(match, "");
    } else {
      final pattern = r[1];
      if (pattern.contains("\$")) {
        if (r.length == 2) {
          return (String s) => s.replaceAllMapped(match, _replacement(pattern));
        } else {
          return (String s) => s.replaceFirstMapped(match, _replacement(pattern));
        }
      } else {
        if (r.length == 2) {
          return (String s) => s.replaceAll(match, pattern);
        } else {
          return (String s) => s.replaceFirst(match, pattern);
        }
      }
    }
  }

  List<String> Function(List<String>) replaceListSmart(String replace) {
    if (null == replace || replace.isEmpty) return (List<String> s) => s;
    final _replaceSmart = replaceSmart(replace);
    return (List<String> ls) => ls.map((s) => _replaceSmart(s)).toList();
  }

  Future<List<dynamic>> getElements(String rule) async {
    var result = <dynamic>[];
    if (null == rule) return result;
    rule = rule.trimLeft();
    if (rule.isEmpty) return result;

    for (final r in splitRuleReversed(rule).reversed) {
      final temp =
          await r.analyzer.parse(result.isNotEmpty ? result : _content).getElements(rule);
      if (temp is List) {
        result = temp;
      } else {
        result = [temp];
      }
    }
    return result;
  }

  Future<List<String>> getStringList(String rule) async {
    var result = <String>[];
    if (null == rule) return result;
    rule = rule.trimLeft();
    if (rule.isEmpty) return result;

    for (final r in splitRuleReversed(rule).reversed) {
      final temp =
          await r.analyzer.parse(result.isNotEmpty ? result : _content).getElements(rule);
      if (temp is List<String>) {
        result = replaceListSmart(r.replace)(temp);
      } else if (temp is List) {
        result =
            replaceListSmart(r.replace)(temp.where((e) => null != e).map((e) => '$e'));
      } else {
        result = [replaceSmart(r.replace)(temp)];
      }
    }
    return result;
  }

  final expressionPattern = RegExp(r"\{\{(.*?)\}\}", dotAll: true);

  Future<String> _getString(SingleRule r, [String rule]) async {
    if (null == rule) {
      rule = r.rule;
    }
    var result = "";
    if (r.rule.contains("&&")) {
      final rs = <String>[];
      for (final rSimple in r.rule.split("&&")) {
        final temp = await _getString(r, rSimple);
        if (temp.isNotEmpty) rs.add(temp);
      }
      return rs.join(", ");
    } else if (r.rule.contains("||")) {
      for (final rSimple in r.rule.split("&&")) {
        final temp = await _getString(r, rSimple);
        if (temp.isNotEmpty) return temp;
      }
    } else {
      final temp = await r.analyzer.getString(rule);
      if (temp is List) {
        result = temp
            .where((s) => null != s)
            .map((s) => '$s'.trim())
            .where((s) => s.isNotEmpty)
            .join(", ");
      } else {
        result = null == temp ? '' : '$temp'.trim();
      }
    }
    return replaceSmart(r.replace)(result);
  }

  Future<String> getString(String rule) async {
    var result = "";
    if (null == rule) return result;
    rule = rule.trimLeft();
    if (rule.isEmpty) return result;

    final pLeft = rule.lastIndexOf("{{");
    final pRight = rule.lastIndexOf("}}");
    if (-1 < pLeft && pLeft < pRight) {
      var position = 0;
      final rs = <String>[];
      for (final match in expressionPattern.allMatches(rule)) {
        rs.add(rule.substring(position, match.start));
        rs.add(await getString(match.group(1)));
        position = match.end;
      }
      if (position < rule.length) {
        rs.add(rule.substring(position));
      }
      return rs.join();
    }

    for (final r in splitRuleReversed(rule).reversed) {
      r.analyzer.parse(result.isNotEmpty ? result : _content);
      result = await _getString(r);
    }
    return result;
  }

  final ruleTypePattern = RegExp(r"@css:|@json:|@js:|@xpath:|^", caseSensitive: false);

  /// 形如 `rule##replaceRegex##replacement##replaceFirst`
  ///
  /// 其中 `rule` 可以是 `js` 或 `css` 或 `xpath` 或 `jsonpath` , 形式如下:
  ///
  /// `@js:js code`
  ///
  /// `@json:$.name` 或 `$.name`
  ///
  /// `@css:li` 或 `li`
  ///
  /// `@xpath://li` 或 `//li`
  ///
  /// `:regex`
  ///
  /// 规则从后往前解析
  List<SingleRule> splitRuleReversed(String rule) {
    final ruleList = <SingleRule>[];
    var lastStart = rule.length;
    for (var m in ruleTypePattern.allMatches(rule).toList().reversed) {
      var r = rule.substring(m.start, lastStart).trimLeft();
      if (r.isEmpty) {
        lastStart = m.start;
        continue;
      }
      Analyzer analyzer;
      switch (r[0]) {
        case r"$":
          analyzer = AnalyzerJSonPath();
          break;
        case "@":
          if (r.startsWith(RegExp(r"@js:", caseSensitive: false))) {
            r = r.substring(4);
            analyzer = AnalyzerJS(_idJsEngine);
          } else if (r.startsWith(RegExp(r"@css:", caseSensitive: false))) {
            r = r.substring(5);
            analyzer = AnalyzerHtml();
          } else if (r.startsWith(RegExp(r"@json:", caseSensitive: false))) {
            r = r.substring(6);
            analyzer = AnalyzerHtml();
          } else if (r.startsWith(RegExp(r"@xpath:", caseSensitive: false))) {
            r = r.substring(7);
            analyzer = AnalyzerXPath();
          }
          break;
        case ":":
          r = r.substring(1);
          analyzer = AnalyzerRegExp();
          break;
        case "/":
          analyzer = AnalyzerXPath();
          break;
        default:
      }

      final position = r.indexOf("##");
      if (!(analyzer is AnalyzerJS) && position > -1) {
        ruleList.add(
            SingleRule(analyzer, r.substring(0, position), r.substring(position + 2)));
      } else {
        ruleList.add(SingleRule(analyzer, r, ""));
      }
      lastStart = m.start;
    }
    return ruleList;
  }
}

class SingleRule {
  final Analyzer analyzer;
  final String rule;
  final String replace;
  SingleRule(this.analyzer, this.rule, this.replace);
}
