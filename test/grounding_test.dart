import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/ocr/grounding.dart';

void main() {
  test('parses two blocks', () {
    final blocks = parseGrounding(
      '![title](10,20,30,40) # Hi\n\n![text](50,60,70,80) Body',
    );
    expect(blocks, hasLength(2));
    expect(blocks[0].label, 'title');
    expect(blocks[0].bbox, [10, 20, 30, 40]);
    expect(blocks[0].text, '# Hi');
    expect(blocks[1].text, 'Body');
  });

  test('continuation joins with a space', () {
    final markdown = groundingToMarkdown(
      '![text](0,0,10,10) one\n![text+](0,0,10,10) two',
    );
    expect(markdown, 'one two');
  });

  test('no markers returns raw', () {
    expect(groundingToMarkdown('plain text'), 'plain text');
  });

  test('drop removes header and footer', () {
    final markdown = groundingToMarkdown(
      '![header](0,0,10,10) H\n![text](0,0,10,10) Body\n![footer](0,0,10,10) F',
      drop: {'header', 'footer'},
    );
    expect(markdown, 'Body');
  });

  test('repairs dollar entities', () {
    expect(
      groundingToMarkdown('![text](0,0,10,10) a &dollar;x&dollar; b'),
      'a \$x\$ b',
    );
  });
}
