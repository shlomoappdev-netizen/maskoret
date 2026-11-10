import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/ui/link_text.dart';

List<String> urls(String text) => [for (final l in findLinks(text)) l.uri.toString()];
List<String> shown(String text) => [for (final l in findLinks(text)) text.substring(l.start, l.end)];

void main() {
  test('finds http and https links in Hebrew text', () {
    expect(urls('שלום, הסבר כאן: https://example.com/a?b=1 ותודה'), ['https://example.com/a?b=1']);
    expect(urls('ישן: http://example.org'), ['http://example.org']);
  });

  test('www addresses open as https', () {
    expect(urls('באתר www.example.co.il.'), ['https://www.example.co.il']);
    expect(shown('באתר www.example.co.il.'), ['www.example.co.il']);
  });

  test('sentence punctuation stays out of the link', () {
    expect(shown('ראו https://example.com/page, ואז (https://example.com/x).'),
        ['https://example.com/page', 'https://example.com/x']);
    expect(shown('https://en.wikipedia.org/wiki/Foo_(bar)'), ['https://en.wikipedia.org/wiki/Foo_(bar)']);
  });

  test('Hebrew right after the address is not part of it', () {
    expect(shown('https://example.comלחצו'), ['https://example.com']);
  });

  test('other schemes are not links', () {
    expect(urls('javascript:alert(1) file:///etc/passwd mailto:a@b.c tel:123'), isEmpty);
    expect(urls('no links here'), isEmpty);
  });
}
