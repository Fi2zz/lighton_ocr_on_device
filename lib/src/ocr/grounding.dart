class GroundingBlock {
  final String label;
  final List<int> bbox;
  final String text;
  final bool continues;

  const GroundingBlock({
    required this.label,
    required this.bbox,
    required this.text,
    required this.continues,
  });
}

final RegExp _marker = RegExp(
  r'!\[([A-Za-z_][\w-]*?)(\+?)\]\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)[ \t]*',
);

List<GroundingBlock> parseGrounding(String raw) {
  final matches = _marker.allMatches(raw).toList();
  final blocks = <GroundingBlock>[];

  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
    blocks.add(
      GroundingBlock(
        label: match.group(1)!,
        continues: match.group(2) == '+',
        bbox: [
          int.parse(match.group(3)!),
          int.parse(match.group(4)!),
          int.parse(match.group(5)!),
          int.parse(match.group(6)!),
        ],
        text: raw.substring(match.end, end).trim(),
      ),
    );
  }

  return blocks;
}

String groundingToMarkdown(
  String raw, {
  Set<String> drop = const {},
}) {
  final blocks = parseGrounding(raw);
  if (blocks.isEmpty) {
    return raw.trim().replaceAll('&dollar;', r'$');
  }

  final parts = <String>[];
  var previousKept = false;

  for (final block in blocks) {
    if (drop.contains(block.label) || block.text.isEmpty) {
      previousKept = false;
      continue;
    }
    if (block.continues && previousKept && parts.isNotEmpty) {
      parts[parts.length - 1] = '${parts.last} ${block.text}';
    } else {
      parts.add(block.text);
    }
    previousKept = true;
  }

  return parts.join('\n\n').replaceAll('&dollar;', r'$');
}
