# openness.awk - "will a pull request from an outsider be read here?"
#
# usage: awk -v archived=BOOL -v has_prs=BOOL -v policy=STR \
#            -v total=N -v ext=N -v sample=N -v checked=0|1 -f openness.awk
#
# Prints: SCORE<TAB>TEXT, where SCORE is 0-10 or the word "null" when the merge
# statistics were not read. Every input may be the string "null" (the GitHub API
# field was absent) and is then treated as unknown rather than as a zero.
#
# The scale is deliberately blunt; it answers one question and the numbers behind
# it are printed next to it, so a reader can disagree with the weighting and
# still use the counts.
#   0   the door is shut: archived, pull requests disabled, or the repository
#       only takes them from collaborators
#   1   nothing from outside was merged in 90 days
#   3   one or two
#   5   three to nine
#   7   ten to forty-nine
#   8   fifty or more
#   +1  at least a fifth of the merges came from outside
#   +2  at least half did
# ext is an estimate: the search API returns at most 100 items, so the outside
# share of the sample is projected onto the total. sample is printed for that
# reason - a 12/400 with a sample of 100 is a weaker number than a 12/40.
BEGIN {
  if (archived == "true")            { print "0\t0/10 (the repository is archived)"; exit }
  if (has_prs == "false")            { print "0\t0/10 (pull requests are disabled)"; exit }
  if (policy == "collaborators_only"){ print "0\t0/10 (pull_request_creation_policy: collaborators_only - only collaborators may open one)"; exit }
  if (checked != 1 || total == "null" || total == "") {
    print "null\tnot scored (90-day merge statistics not read), PR policy: " (policy == "" ? "null" : policy)
    exit
  }
  t = total + 0; e = ext + 0; s = sample + 0

  if (t == 0)       score = 0
  else if (e == 0)  score = 1
  else if (e <= 2)  score = 3
  else if (e <= 9)  score = 5
  else if (e <= 49) score = 7
  else              score = 8

  if (t > 0 && e > 0) {
    r = e / t
    if (r >= 0.5)      score += 2
    else if (r >= 0.2) score += 1
  }
  if (score > 10) score = 10

  printf "%d\t%d/10 (external merges 90d: %d/%d, sample %d, PR policy: %s)\n", \
         score, score, e, t, s, (policy == "" ? "null" : policy)
}
