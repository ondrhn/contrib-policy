# Split a markdown/rst/plain text file into sentence units.
# Output: FILE:LINE<TAB>sentence   (LINE = first line of the paragraph the sentence came from)
# Headings, list items and table rows are units of their own; wrapped paragraph
# lines are joined before splitting so a sentence broken over two lines stays one unit.
# usage: awk -v F=path/in/repo -f sentences.awk localfile

BEGIN { SEP = sprintf("%c", 1) }   # stands in for a dot that does not end a sentence

function emit(text, line,    n, i, s, parts) {
  gsub(/[ \t]+/, " ", text)
  # "(e.g. claude code)" must not end a sentence: splitting there cuts the rule
  # in half and the half without the verb reads like a different rule.
  gsub(/[eE]\.[gG]\./, "e" SEP "g" SEP, text)
  gsub(/[iI]\.[eE]\./, "i" SEP "e" SEP, text)
  gsub(/etc\./, "etc" SEP, text)
  gsub(/Etc\./, "Etc" SEP, text)
  gsub(/vs\./, "vs" SEP, text)
  gsub(/cf\./, "cf" SEP, text)
  gsub(/al\./, "al" SEP, text)
  gsub(/resp\./, "resp" SEP, text)
  gsub(/approx\./, "approx" SEP, text)
  n = split(text, parts, /[.!?][)"'\]]* +/)
  for (i = 1; i <= n; i++) {
    s = parts[i]
    gsub(SEP, ".", s)
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    if (length(s) > 2) printf "%s:%d\t%s\n", F, line, s
  }
}
function flush() {
  if (para != "") emit(para, pstart)
  para = ""
}
{
  sub(/\r$/, "")
  # markdown link targets and inline html tags carry no policy text and confuse splitting
  gsub(/\]\([^)]*\)/, "]")
  gsub(/<[^>]*>/, " ")
}
/^[ \t]*$/ { flush(); next }
# A list item starts a paragraph instead of being a unit on its own: policy
# bullets wrap, and the rule is usually in the part on the second line
# ("AI must not create / hypothetically correct code that hasn't been tested").
/^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ {
  flush()
  para = $0; pstart = NR
  next
}
/^#/ || /^[ \t]*\|/ || /^[=~^-]+[ \t]*$/ {
  flush()
  emit($0, NR)
  next
}
{
  if (para == "") pstart = NR
  para = para " " $0
}
END { flush() }
