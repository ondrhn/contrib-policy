# Split a markdown/rst/plain text file into sentence units.
# Output: FILE:LINE<TAB>sentence   (LINE = first line of the paragraph the sentence came from)
# Headings, list items and table rows are units of their own; wrapped paragraph
# lines are joined before splitting so a sentence broken over two lines stays one unit.
# usage: awk -v F=path/in/repo -f sentences.awk localfile
#
# The text is normalised before it is split, because the file comes from a
# stranger and the classifier is patterns over ASCII words: a rule that was
# written to be read but not matched ("A<200C>I", "АI" with a Cyrillic A,
# "Ａ Ｉ", "A<!-- -->I", "&#65;I", "A*I*") has to read as "AI" here. The
# characters that were removed or mapped are reported by policy_scan.sh's
# injection screen; this file only makes sure the rule is seen.

BEGIN {
  SEP = sprintf("%c", 1)   # stands in for a dot that does not end a sentence
  AIWORD = "(^|[^a-z])(ai|a\\.i\\.|llms?|generative|chatgpt|co-?pilot|claude|gemini|cursor|codex|gpt[-0-9a-z]*|language models?|machine|bots?|agents?|assistants?|automated|autonomous)([^a-z]|$)"
}

# Invisible format characters that carry no text: ZWSP, ZWNJ, ZWJ, CGJ, word
# joiner, invisible times/separator/plus, U+180E, soft hyphen, Hangul fillers,
# halfwidth Hangul filler, BOM. They are removed everywhere: in an emoji or an
# Arabic word the removal changes nothing a pattern would see, and inside a
# Latin word it is the point.
function strip_invisible(s) {
  gsub(/\342\200\213|\342\200\214|\342\200\215|\315\217|\342\201\240|\342\201\241|\342\201\242|\342\201\243|\342\201\244|\341\240\216|\302\255|\343\205\244|\341\205\237|\341\205\240|\357\276\240|\357\273\277/, "", s)
  return s
}
# A Cyrillic or Greek letter that looks like a Latin one is mapped to it only
# when it touches a Latin letter: a Russian or Greek word stays what it is, a
# Latin word with one foreign letter in it becomes the Latin word.
function map_homoglyphs(s,    m, pre, post) {
  while (match(s, /[A-Za-z](\320\220|\320\222|\320\225|\320\232|\320\234|\320\235|\320\236|\320\240|\320\241|\320\242|\320\245|\320\260|\320\265|\320\276|\321\200|\321\201|\321\203|\321\205|\321\226|\321\230|\316\221|\316\222|\316\225|\316\226|\316\227|\316\231|\316\232|\316\234|\316\235|\316\237|\316\241|\316\244|\316\245|\316\247|\316\277)|(\320\220|\320\222|\320\225|\320\232|\320\234|\320\235|\320\236|\320\240|\320\241|\320\242|\320\245|\320\260|\320\265|\320\276|\321\200|\321\201|\321\203|\321\205|\321\226|\321\230|\316\221|\316\222|\316\225|\316\226|\316\227|\316\231|\316\232|\316\234|\316\235|\316\237|\316\241|\316\244|\316\245|\316\247|\316\277)[A-Za-z]/)) {
    pre = substr(s, 1, RSTART - 1); m = substr(s, RSTART, RLENGTH); post = substr(s, RSTART + RLENGTH)
    gsub(/\320\220/, "A", m); gsub(/\320\222/, "B", m); gsub(/\320\225/, "E", m); gsub(/\320\232/, "K", m)
    gsub(/\320\234/, "M", m); gsub(/\320\235/, "H", m); gsub(/\320\236/, "O", m); gsub(/\320\240/, "P", m)
    gsub(/\320\241/, "C", m); gsub(/\320\242/, "T", m); gsub(/\320\245/, "X", m)
    gsub(/\320\260/, "a", m); gsub(/\320\265/, "e", m); gsub(/\320\276/, "o", m); gsub(/\321\200/, "p", m)
    gsub(/\321\201/, "c", m); gsub(/\321\203/, "y", m); gsub(/\321\205/, "x", m); gsub(/\321\226/, "i", m); gsub(/\321\230/, "j", m)
    gsub(/\316\221/, "A", m); gsub(/\316\222/, "B", m); gsub(/\316\225/, "E", m); gsub(/\316\226/, "Z", m)
    gsub(/\316\227/, "H", m); gsub(/\316\231/, "I", m); gsub(/\316\232/, "K", m); gsub(/\316\234/, "M", m)
    gsub(/\316\235/, "N", m); gsub(/\316\237/, "O", m); gsub(/\316\241/, "P", m); gsub(/\316\244/, "T", m)
    gsub(/\316\245/, "Y", m); gsub(/\316\247/, "X", m); gsub(/\316\277/, "o", m)
    s = pre m post
  }
  return s
}
# Fullwidth ASCII (U+FF01-U+FF5E) to ASCII: the letters, and the marks that
# take part in a rule. Written out, because sprintf("%c") in a UTF-8 locale
# encodes a code point rather than emitting a byte.
function map_fullwidth(s) {
  gsub(/\357\274\241/, "A", s); gsub(/\357\275\201/, "a", s)
  gsub(/\357\274\242/, "B", s); gsub(/\357\275\202/, "b", s)
  gsub(/\357\274\243/, "C", s); gsub(/\357\275\203/, "c", s)
  gsub(/\357\274\244/, "D", s); gsub(/\357\275\204/, "d", s)
  gsub(/\357\274\245/, "E", s); gsub(/\357\275\205/, "e", s)
  gsub(/\357\274\246/, "F", s); gsub(/\357\275\206/, "f", s)
  gsub(/\357\274\247/, "G", s); gsub(/\357\275\207/, "g", s)
  gsub(/\357\274\250/, "H", s); gsub(/\357\275\210/, "h", s)
  gsub(/\357\274\251/, "I", s); gsub(/\357\275\211/, "i", s)
  gsub(/\357\274\252/, "J", s); gsub(/\357\275\212/, "j", s)
  gsub(/\357\274\253/, "K", s); gsub(/\357\275\213/, "k", s)
  gsub(/\357\274\254/, "L", s); gsub(/\357\275\214/, "l", s)
  gsub(/\357\274\255/, "M", s); gsub(/\357\275\215/, "m", s)
  gsub(/\357\274\256/, "N", s); gsub(/\357\275\216/, "n", s)
  gsub(/\357\274\257/, "O", s); gsub(/\357\275\217/, "o", s)
  gsub(/\357\274\260/, "P", s); gsub(/\357\275\220/, "p", s)
  gsub(/\357\274\261/, "Q", s); gsub(/\357\275\221/, "q", s)
  gsub(/\357\274\262/, "R", s); gsub(/\357\275\222/, "r", s)
  gsub(/\357\274\263/, "S", s); gsub(/\357\275\223/, "s", s)
  gsub(/\357\274\264/, "T", s); gsub(/\357\275\224/, "t", s)
  gsub(/\357\274\265/, "U", s); gsub(/\357\275\225/, "u", s)
  gsub(/\357\274\266/, "V", s); gsub(/\357\275\226/, "v", s)
  gsub(/\357\274\267/, "W", s); gsub(/\357\275\227/, "w", s)
  gsub(/\357\274\270/, "X", s); gsub(/\357\275\230/, "x", s)
  gsub(/\357\274\271/, "Y", s); gsub(/\357\275\231/, "y", s)
  gsub(/\357\274\272/, "Z", s); gsub(/\357\275\232/, "z", s)
  gsub(/\357\274\215/, "-", s)
  gsub(/\357\274\216/, ".", s)
  gsub(/\357\274\214/, ",", s)
  gsub(/\357\274\232/, ":", s)
  gsub(/\343\200\200/, " ", s)
  return s
}
# &#65; &#x41; and the named entities that appear in policy text.
function decode_entities(s,    m, n, c, hex, i, d) {
  while (match(s, /&#[0-9]+;/)) {
    n = substr(s, RSTART + 2, RLENGTH - 3) + 0
    c = (n >= 32 && n < 127) ? sprintf("%c", n) : " "
    s = substr(s, 1, RSTART - 1) c substr(s, RSTART + RLENGTH)
  }
  while (match(s, /&#[xX][0-9A-Fa-f]+;/)) {
    hex = tolower(substr(s, RSTART + 3, RLENGTH - 4)); n = 0
    for (i = 1; i <= length(hex); i++) { d = index("0123456789abcdef", substr(hex, i, 1)) - 1; n = n * 16 + d }
    c = (n >= 32 && n < 127) ? sprintf("%c", n) : " "
    s = substr(s, 1, RSTART - 1) c substr(s, RSTART + RLENGTH)
  }
  gsub(/&nbsp;/, " ", s); gsub(/&quot;/, "\"", s); gsub(/&apos;/, "'", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s)
  return s
}
# Emphasis markers inside a word ("A*I*-generated", "A`I`") split it for a
# pattern and not for a reader. Markers around a word are left alone: the
# classifier reads "**Not allowed:**" as a list heading.
function join_intraword(s,    m) {
  while (match(s, /[A-Za-z][*`~]+[A-Za-z]/)) {
    m = substr(s, RSTART, RLENGTH); gsub(/[*`~]/, "", m)
    s = substr(s, 1, RSTART - 1) m substr(s, RSTART + RLENGTH)
  }
  return s
}

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
function flush(    t) {
  if (para != "") {
    emit(para, pstart)
    # "Not allowed:" followed by a list: the items are the rule, and they carry
    # the heading. Only a short label qualifies, and only one that does not name
    # AI itself: under "It is not acceptable to use AI tools to:" the items are
    # specific uses, and reading each as a blanket ban would be wrong.
    t = para; gsub(/^[ \t]+|[ \t]+$/, "", t); sub(/[*_`~ \t]+$/, "", t)
    if (!inlist && t ~ /:$/ && length(t) <= 40 && tolower(t) !~ AIWORD) { lead = t; sub(/^[*_`~#> \t]+/, "", lead) } else if (!inlist) lead = ""
  }
  para = ""; inlist = 0
}
{
  sub(/\r$/, "")
  # Control characters and escape sequences hide text from a reader or rewrite
  # the terminal the verdict is printed on; none of them carries policy text.
  gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, " ")
  gsub(/\033[@-Z\\-_]/, " ")
  gsub(/[\001-\010\013-\037\177]/, " ")
  gsub(/\r/, " ")
  $0 = strip_invisible($0)
  $0 = map_fullwidth($0)
  $0 = map_homoglyphs($0)
  $0 = decode_entities($0)
  # markdown link targets and inline html carry no policy text and confuse
  # splitting. Block-level tags end a run of text; an inline tag or a comment
  # in the middle of a word ("A<b></b>I", "A<!-- -->I") does not.
  gsub(/\]\([^)]*\)/, "]")
  gsub(/<\/?(p|div|br|li|ul|ol|tr|td|th|table|h[1-6]|blockquote|pre|hr|section|details|summary|dd|dt|dl)([ \t][^>]*)?\/?>/, " ")
  gsub(/<[^>]*>/, "")
  $0 = join_intraword($0)
}
/^[ \t]*$/ { flush(); next }
# A list item starts a paragraph instead of being a unit on its own: policy
# bullets wrap, and the rule is usually in the part on the second line
# ("AI must not create / hypothetically correct code that hasn't been tested").
/^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ {
  flush()
  para = $0; pstart = NR; inlist = 1
  if (lead != "") { item = $0; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", item); para = lead " " item }
  next
}
/^#/ || /^[ \t]*\|/ || /^[=~^-]+[ \t]*$/ {
  flush(); lead = ""
  emit($0, NR)
  next
}
{
  if (para == "") { pstart = NR; if (!inlist) lead = "" }
  para = para " " $0
}
END { flush() }
