/// pt-BR friendly sort key: lower case, accents folded ("Álvaro" sorts with
/// the As, before "Zé"), so a plain `compareTo` gives the order a person expects.
///
/// Pure (no Flutter, no Firebase): shared by the friends list and the
/// ranking (docs/91 §6), which must order names the same way.
String collationKey(String name) {
  const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyy';
  final buffer = StringBuffer();
  for (final rune in name.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i < 0 ? ch : to[i]);
  }
  return buffer.toString();
}
