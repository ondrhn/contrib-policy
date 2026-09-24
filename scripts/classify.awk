# Classify sentence units produced by sentences.awk.
# Input:  FILE:LINE<TAB>sentence
# Output: CLASS<TAB>FILE:LINE<TAB>sentence
# CLASS: FORBID | FORBID_PARTIAL | DISCLOSE | DISCLOSE_SOFT | OVERSIGHT | ALLOW | MENTION | ISSUE_ONLY | MEDIA_ONLY
#        NOAI_ATTEST | NOCOAUTHOR | CLA | NOCLA | DCO
# A sentence is only classified for AI stance when it names AI/LLM/agents itself;
# "do not open pull requests" without that context is not a policy hit.
# Portable awk: no \b, no \y; word boundaries are written out with W().

# Underscore is not a word character here: markdown emphasis writes _must not_,
# and a rule that only fires on unemphasised text is no rule at all.
function W(re) { return "(^|[^a-z0-9])(" re ")([^a-z0-9]|$)" }
# Leading boundary only: Spanish and French attach pronouns and endings to the
# verb ("debes indicarlo", "indiquez-le"), so the tail is left open.
function L(re) { return "(^|[^a-z0-9])(" re ")" }

BEGIN {
  # "tool-generated content", "note tool usage", "Assisted-by:": the LLVM policy
  # (adopted verbatim by QGIS and stac-utils) never writes "AI" in the sentence
  # that carries the rule. Only the compound forms count - a bare "tool" is a
  # screwdriver.
  TOOLGEN = "tool[- ](generated|assisted|written|produced|created)|tool (usage|use) in (their|your|the)|assisted-by|generated-by|code assistants?"
  # "co-pilot" with the hyphen is how EmulatorKit on Codeberg writes it, and it is
  # the only AI word in the sentence that carries its ban.
  AI = W("ai|a\\.i\\.|llms?|large language models?|language models?|chat ?bots?|machine (assistance|assisted|written|authored)|gpt[-0-9a-z]*|chatgpt|co-?pilot|claude|cursor|codex|gemini|generative|machine[- ]generated|vibe[- ]cod(ed|ing)|coding (agents?|assistants?)|ai[- ]?(generated|assisted|written|powered|tools?|agents?|assistants?|slop|usage|use|policy)|(autonomous|automated) (agents?|contributions?|pull requests?|prs?|submissions?)|agentic|slop|" TOOLGEN)
  AI_NOSLOP = W("ai|a\\.i\\.|llms?|large language models?|language models?|chat ?bots?|machine (assistance|assisted|written|authored)|gpt[-0-9a-z]*|chatgpt|co-?pilot|claude|cursor|codex|gemini|generative|machine[- ]generated|vibe[- ]cod(ed|ing)|coding (agents?|assistants?)|ai[- ]?(generated|assisted|written|powered|tools?|agents?|assistants?|usage|use|policy)|(autonomous|automated) (agents?|contributions?|pull requests?|prs?|submissions?)|agentic|" TOOLGEN)
  FORBID = W("(not|never|don'?t|do not|won'?t|cannot|can'?t|no longer) (be )?(accept|allow|permit|tolerat|want|merge|review|consider|welcome|read)[a-z]*|prohibit[a-z]*|forbidden|banned|ban|not (allowed|permitted|acceptable|welcome|accepted|tolerated|wanted|authori[sz]ed|sanctioned|approved|invited|endorsed|supported)|(must|may|should|shall|will|do|does|can) not (be )?(use|submit|open|creat|generat|contribut|send|includ|incorporat|introduc|employ|rely|contain|have|has)[a-z]*|refrain from|unacceptable|unwelcome|(will|may|are|is|get|gets|be) (be )?(closed|rejected|declined|deleted|ignored|blocked|banned|removed)( (without|immediately|on sight|unread|summarily|and|or))?|human[- ]only|(fully|entirely|100%|completely) human[- ](written|authored|made)|(strict(ly)?|absolutely|zero)[- ]?(no|tolerance)|no (ai|llms?|generative|machine|chatgpt|co-?pilot|llm/ai|ai/llm)|gtfo|zero tolerance|not (a )?place for|off[- ]limits|do not use (ai|llms?|generative|chatgpt|co-?pilot|claude)|refuse|refus(es|ed|ing)|(must|should|has to|have to|needs? to) be (written|authored|made|produced|created|done) by (a |an |real |actual )?(human|person|people)|reject(s|ed|ing)?|declin(e|es|ed|ing)|turned away|thrown out")
  NOFORBID = W("no (ai|llms?|generative ai|ai/llm|llm/ai)[- ]?(policy|policies|rule|rules|restriction|restrictions|guideline|guidelines|ban|stance)|not (prohibited|banned|forbidden|against|opposed to)|nothing wrong|not (to|a|an|our|intended to) ban|does not ban|is not a (ban|prohibition)")
  ISSUE_ONLY_SUBJECT = W("issues?|bug reports?|discussions?|comments?")
  # a ban that only bites when nobody is driving: the project still takes work a
  # human wrote with AI help, so this is an oversight rule and not a refusal
  # "autonomously" is the adverb: it says how the work was driven, which is the
  # oversight question. The adjective ("autonomous agents") names the actor and
  # belongs in AUTONOMY_WEAK below.
  AUTONOMY = W("unsupervised|unattended|unreviewed|unchecked|unverified|untested|blindly|autonomously|fully[- ](autonomous|automated)|purely (agentic|automated|ai)|entirely (generated|automated|by)|drive[- ]?by|without (meaningful |any )?(human )?(review|oversight|supervision|understanding|involvement)|no meaningful human")
  # these words name the agent rather than the way it is driven. On their own they
  # still mean "unattended work", but next to a plain AI word they are part of a
  # list ("contributions from Generative AI, LLMs or autonomous agents") and the
  # sentence is a refusal of AI work, not a rule about supervision.
  # "will be closed without review": the review that is missing is the
  # maintainer's, as a consequence. That is a refusal, not an oversight rule.
  # "written by a human, without machine assistance": the "without" is the ban
  # itself, not a condition on it.
  NOASSIST = W("without (any )?(machine|ai|llm|automated|generative) (assistance|help|involvement|aid|tools?)")
  CLOSED_UNREAD = W("(closed|rejected|deleted|ignored|removed|declined|discarded) (without|unread|immediately|on sight|summarily)")
  # ... unless the sentence makes it conditional on not saying so: "use of AI
  # without transparency may lead to submissions being rejected" is a
  # disclosure rule with a consequence attached.
  NOT_DISCLOSED_COND = W("without (transparency|disclosure|disclosing|declaring|declaration|saying so|telling us|mentioning it|attribution|credit)")
  AUTONOMY_WEAK = W("autonomous(ly)?|agentic|automated (agents?|systems?|tools?|submissions?|contributions?)|bots?")
  PLAIN_AI = W("ai|a\\.i\\.|llms?|large language models?|language models?|chat ?bots?|machine (assistance|assisted|written|authored)|language models?|chat ?bots?|machine (assistance|assisted|written|authored)|gpt[-0-9a-z]*|chatgpt|co-?pilot|claude|cursor|codex|gemini|generative|machine[- ]generated|vibe[- ]cod(ed|ing)|ai[- ]?(generated|assisted|written|powered|tools?|slop)")
  # "reply to questions with AI" is a rule about conversation, not about patches
  REPLY_SUBJECT = W("repl(y|ies|ying)|respond(ing)?|responses?|answer(ing|s)?|comment(ing|s)?|questions?|reviews?|reviewing")
  # a box the contributor has to tick affirming that no AI was involved
  # no {n,m} intervals below: mawk panics on an interval followed by a group,
  # and W() always appends one. Use * instead.
  NOAI_ATTEST = W("(has|have|was|were|is|are) not (been )?(created|generated|written|produced|made|authored|developed|assisted)|not (created|generated|written|produced|made|authored|developed) (with|by|using)|does not (include|contain|use|involve)|no (ai|llms?|generative ai|ai tools?|llm tools?)[a-z ]*(were|was) used|(i|we) (did not|didn'?t|have not|haven'?t) use[a-z]*|free of (ai|llm|generative)|without the (assistance|aid|use|help) of")
  IFCLAUSE = W("if|when|where|should you|in case")
  MEDIA_ONLY_SUBJECT = W("media|art|artwork|images?|pictures?|videos?|audio|music|icons?|logos?|graphics|illustrations?|translations?")
  PR_SUBJECT = W("pull requests?|prs?|merge requests?|mrs?|contributions?|patch(es)?|code|commits?|changes?|submissions?|work")
  # "no AI-generated media or text (other than code)", "code is the only
  # acceptable AI-generated content": both carve code out of a media ban
  EXCEPT = W("other than|apart from|except|but not|excluding|only")
  # "does not accept any substantial uses of AI-generated content", "does not
  # accept fully AI-generated pull requests": the ban has a size on it, so some
  # AI use is still allowed. That is a different verdict from a flat refusal.
  QUALIFIER = W("substantial(ly)?|substantive|significant(ly)?|entire(ly)?|full|fully|wholly|wholesale|purely|solely|exclusively|majority|mostly|primarily|predominantly|large (blocks?|parts?|portions?|amounts?)|bulk|mass|unedited|verbatim|raw|straight from")
  # the same shape, but the size on the ban is quality rather than quantity:
  # SearXNG blocks "people who produce bad contributions that are clearly AI".
  # Good AI-assisted work is still taken, so this is not a refusal of AI.
  # "slop" is deliberately absent: it is the usual word for AI output as such.
  QUALITY = W("slop|bad|low[- ]quality|poor(ly)?|sloppy|careless|thoughtless|lazy|broken|spam|spammy|junk|garbage|useless|nonsense|drive[- ]?by|incorrect|untested|unreviewed|half[- ]baked")
  # "These PRs will be closed immediately": the subject points back at a sentence
  # that is read on its own, so this one cannot carry a ban by itself.
  # Only the unambiguous back-references: "that's why X is not allowed" opens a
  # sentence with "that" and is a refusal in its own right.
  ANAPHOR = "^(these|those|such|the above|the former|the latter)([^a-z]|$)"
  # files written for the tool rather than for the contributor
  AGENTFILE = "(^|/)(agents\\.md|claude\\.md|gemini\\.md|\\.cursorrules|\\.windsurfrules|copilot-instructions\\.md|\\.clinerules)$"
  # "generated by an LLM or other fully-automated tools" lists a second subject;
  # the automation word is not a qualifier on the first one, so the ban stands
  ENUM = W("or (any )?other (fully[- ]?)?(automated|autonomous|agentic|ai|llm)[a-z-]*")
  # a rule whose consequence hangs on a condition ("if AI use is not disclosed the
  # pull request is closed") is the enforcement half of that condition, not a ban
  IFCOND = W("if|unless|only if|as long as|provided that|except when|so long as|in case|without")
  # conditions that qualify what is refused, as opposed to "if you are X"
  QUALCOND = W("unless|without|except when|as long as|provided that|so long as|only if|other than|apart from")
  # the ban bites the work nobody checked, which is a rule about oversight:
  # "do not submit code the user hasn't read", "if you cannot guarantee ... do not
  # submit it". GAP keeps the two halves inside one clause.
  GAP = "( [a-z'-]+)?( [a-z'-]+)?( [a-z'-]+)?( [a-z'-]+)?( [a-z'-]+)?"
  NEG_OVERSIGHT = W("(ha(ve|s|d)n'?t|have not|has not|had not|do not|don'?t|does not|doesn'?t|did not|didn'?t|cannot|can'?t|could not|couldn'?t|unable to|no one|nobody)" GAP " (read|understand|understood|review|reviewed|test|tested|verify|verified|check|checked|explain|guarantee|vouch|look at|looked at)")
  # what is being refused is the concealment, which means the project takes the
  # work when it is declared: "zero tolerance for failing to disclose AI usage"
  CONCEAL = W("fail(ing|s|ed)? to (disclose|declare|state|mention|say)|undisclosed|not disclos[a-z]*|misrepresent[a-z]*|mask(ing)? the use|pass(ing)? (it|them|this) off|conceal[a-z]*|hid(e|ing|den)|dishonest|deceptive|lie about|lying about|pretend[a-z]*")
  # "there is no need to tell us you used AI" is the opposite of a disclosure rule
  NODISCLOSE = W("(no|not|never) (need|required?|expected|obliged|necessary)[a-z]* to (disclos|declar|tell|state|mention|say|flag|label|note|credit|acknowledge)[a-z]*|(do|does|are|is) not (need|require|expect|have) to (disclos|declar|tell|state|mention|say)[a-z]*|don'?t (need|have) to (disclos|declar|tell|state|mention|say)[a-z]*|no (disclosure|declaration) (is )?(required|needed|necessary|expected)|without (having to|needing to) (disclos|declar|tell|state|mention)[a-z]*|(this|it|that) is not required|not required,? but|appreciated but not required|optional but (appreciated|welcome)")
  DISCLOSE = W("disclos[a-z]*|declar[a-z]*|attribut[a-z]*|generated-by|assisted-by|co-?authored-by|transparen[a-z]*|upfront|be honest about|(clearly |explicitly )?(state|stated|mention|mentioned|indicate|indicated|label|labeled|labelled|tag|tagged|flag|flagged|identify|identified|acknowledge|acknowledged|credit|credited|specify|specified|inform us|let us know|tell us|call out|note (in|that you))|describ[a-z]* (how|what|which|the (use|extent))")
  MANDATORY = W("must|required?|require[sd]?|need(s|ed)? to|have to|has to|should|shall|mandatory|always|expected to|obligat[a-z]*|be sure to|make sure|please|we ask (that )?(you|for)|are asked to|we request")
  # an invitation is not an obligation: pytest writes "consider adding
  # Co-authored-by trailers" and says in the next sentence that it is not
  # required. "You are welcome to tell us" is the same shape. A sentence that
  # carries a modal as well keeps it - "you must consider the licence and
  # disclose the tool" is still an obligation - so this only decides sentences
  # that have nothing stronger in them.
  SOFTENER = W("consider|optional(ly)?|if you (like|want|wish|prefer|choose)|may (want|wish|choose|like) to|feel free to|are welcome to|you can (also )?(tell|state|say|mention|indicate|declare|disclose|note|label|tag|flag|credit|add|include)|nice to have|up to you")
  # an imperative is an obligation even without a modal ("Tell us how AI helped"),
  # and it stays one behind a leading condition ("When you do not fully understand
  # the change, attribute the idea to AI").
  IMPERATIVE = "(please |kindly |clearly |explicitly |always |briefly |honestly )*(tell|state|say|mention|indicate|declare|disclose|document|note|label|tag|flag|specify|acknowledge|attribute|credit|include|let us know|call out)([^a-z]|$)"
  OVERSIGHT = W("review(ed|s)?|understand[a-z]*|explain[a-z]*|responsib[a-z]*|accountab[a-z]*|own(ership)?|human (in the loop|oversight|review|judg[a-z]*)|verif(y|ied|ies)|test(ed|s)?|vouch|stand behind|read (and|every|it)")
  ALLOW = W("welcome[ds]?|allowed|permitted|acceptable|fine|okay|ok|may use|can use|encourage[ds]?|feel free|no problem|happy to|are accepted|is accepted|do accept|we accept|nothing wrong|not (prohibited|banned|forbidden|against|opposed)")
  NOT_ALLOW = W("not (welcome|allowed|permitted|acceptable|accepted|okay|ok|fine)|isn'?t (welcome|allowed|acceptable|okay|ok|fine)|aren'?t (welcome|allowed|acceptable|okay|ok|fine)")
  NEG_COAUTHOR = W("no|not|never|don'?t|do not|must not|should not|avoid|remove|without")
  CLA = W("contributor licen[cs]e agreement|cla|cla-assistant|easycla|contributor agreement|eca|eclipse contributor agreement|icla|ccla")
  NOCLA = W("(no|not|don'?t|doesn'?t|does not|without|never|nor) (need|require|ask for|have|use|sign)[a-z]* (you )?(to sign )?(a |the |any )?(formal |signed |separate |explicit )?\\[?(cla|contributor licen[cs]e agreement)|no cla|cla is not required|cla-free|without (a |any )?cla")
  DCO = W("developer certificate of origin|dco|signed-off-by|sign-?off|sign your commits|git commit -s|commit -s")

  # ---------------------------------------------------------------- other languages
  # A policy is not always written in English, and the bans are not evenly
  # spread: GNOME (German and French translations), Japanese and Chinese
  # projects state the rule in their own language. The English machinery above
  # (qualifiers, anaphora, imperatives) reads English sentences and on a German
  # or Japanese one it would answer by accident rather than by rule, so these
  # patterns are matched on their own and answer two questions only: does the
  # sentence name AI, and does it refuse or ask for a declaration.
  #
  # The sentence is matched lowercased. mawk lowers ascii only, gawk in a UTF-8
  # locale lowers Cyrillic too, so a Cyrillic phrase carries both cases and an
  # ascii "AI" inside a CJK phrase is written in lowercase. Every latin phrase
  # is bounded with W() - "indicar" must not fire on "indicate", "declare" is
  # left out of the Spanish set for the same reason.
  AI_DE = "künstliche intelligenz|ki-(generiert|generierte[a-z]*|erzeugt|erzeugte[a-z]*|geschrieben|unterstützt)|generative[a-z]* ki|sprachmodell|" W("ki")
  # no empty alternative anywhere below: mawk rejects "(a|b|)" at compile time
  AI_FR = "intelligence artificielle|généré(e|s|es)? par (l'|une |des )?ia|modèles? de langage|" W("ia")
  AI_ES = "inteligencia artificial|generado(s|a|as)? (con|por) (la )?ia|modelos? de lenguaje|" W("ia")
  AI_RU = "скусственн(ый|ого|ым) интеллект|ейросет|зыков(ая|ой|ые) модел|ИИ|ии"
  AI_JA = "人工知能|生成ai|ai生成|大規模言語モデル"
  AI_ZH = "人工智能|人工智慧|生成式|大语言模型|大型語言模型|ai 生成|ai生成"
  AI_XX = AI_DE "|" AI_FR "|" AI_ES "|" AI_RU "|" AI_JA "|" AI_ZH

  FORBID_DE = W("nicht (akzeptiert|erlaubt|gestattet|zulässig|erwünscht)|verboten|untersagt|keine ki|abgelehnt|werden geschlossen")
  FORBID_FR = W("(n'est|ne sont) pas (accepté|acceptés|acceptée|acceptées|autorisé|autorisés|autorisée|autorisées)|interdit(e|s|es)?|refusé(e|s|es)?|seront (fermées|fermés|rejetés|rejetées)")
  FORBID_ES = W("no se (acepta|aceptan|permite|permiten)|prohibid(o|a|os|as)|no está permitido|(será|serán) (cerrado|cerrados|rechazado|rechazados)|rechazad(o|a|os|as)")
  FORBID_RU = "е принима(ются|ется)|апрещ(ено|ена|ены|ается)|е допускается|будут закрыты|тклоняются"
  FORBID_JA = "受け付けて(いません|おりません)|受け付けません|受け入れません|禁止|お断り|認められません"
  FORBID_ZH = "不接受|禁止|不允许|不允許|将被关闭|將被關閉|拒绝|拒絕"
  FORBID_XX = FORBID_DE "|" FORBID_FR "|" FORBID_ES "|" FORBID_RU "|" FORBID_JA "|" FORBID_ZH

  # "inform" is not in the Spanish set and "declare" not in either latin set:
  # both are English words and would take the sentence away from the rules above,
  # which grade an English disclosure rule more carefully than this path can.
  DISCLOSE_DE = W("offen(legen|gelegt|zulegen)|ange(ben|geben)|anzugeben|kennzeichnen|kenntlich|hinweisen|vermerken")
  DISCLOSE_FR = L("divulgu(er|ez|é)|indiqu(er|ez)|signal(er|ez|é)|mentionn(er|ez|é)|déclar(er|ez|é)|précis(er|ez|é)")
  DISCLOSE_ES = L("divulg(ar|ue)|indic(ar|ue)|declarar|mencion(ar|e)|revel(ar|e)|señal(ar|e)")
  DISCLOSE_RU = "кажите|указать|ообщите|аскры(ть|вать)|пометьте|отметьте"
  DISCLOSE_JA = "明記|記載|開示|申告"
  DISCLOSE_ZH = "说明|說明|注明|註明|披露|声明|聲明|标注|標註"
  DISCLOSE_XX = DISCLOSE_DE "|" DISCLOSE_FR "|" DISCLOSE_ES "|" DISCLOSE_RU "|" DISCLOSE_JA "|" DISCLOSE_ZH

  # the same cancellation the English path has: a project that says the note is
  # welcome but not required is not asking for one
  NODISCLOSE_XX = "nicht (erforderlich|notwendig|verpflichtend|vorgeschrieben)|freiwillig|" \
                  "n'est pas (obligatoire|requis|requise)|facultati(f|ve)|" \
                  "no es (obligatorio|necesario)|opcional|" \
                  "не обязательно|необязательно|" \
                  "必須ではありません|任意です|" \
                  "不是必须的|非強制|并非必须"
}

{
  split($0, f, "\t")
  loc = f[1]; s = f[2]; l = tolower(s)
  # markdown emphasis sits inside sentences: "PRs _must not_ incorporate" has to
  # read as "must not incorporate". The quote keeps the original bytes.
  gsub(/[_*`~>]+/, " ", l)
  gsub(/  +/, " ", l)
  cls = ""
  fname = loc; sub(/:[^:]*$/, "", fname)

  # A tick box inside an HTML comment is a note to the author, not a line the
  # pull request carries: github.com renders none of it. pytest keeps its whole
  # checklist inside <!-- ... --> and calls it "a quick checklist that should be
  # present in PRs"; attrs and gentoo put their AI boxes after the comment
  # closes, where a contributor actually ticks them. The state is tracked per
  # file in the order the sentences arrive, and here rather than further down
  # because the sentence that opens the comment usually has no AI word in it and
  # leaves this block early. Only the tick box depends on the state: text inside
  # a comment is still read as policy text.
  if (fname != cmtfile) { cmtfile = fname; incomment = 0 }
  boxpos = match(s, /\[[ xX]\]/)
  inbox = incomment
  if (boxpos) {
    openpos = index(s, "<!--"); closepos = index(s, "-->")
    if (!inbox && openpos && openpos < boxpos) inbox = 1
    if (inbox && closepos && closepos < boxpos) inbox = 0
  }
  cmt = s
  while (match(cmt, /<!--|-->/)) {
    incomment = (substr(cmt, RSTART, 4) == "<!--")
    cmt = substr(cmt, RSTART + RLENGTH)
  }
  tickbox = boxpos && !inbox

  if (l ~ CLA && l !~ NOCLA) print "CLA\t" loc "\t" s
  if (l ~ NOCLA) print "NOCLA\t" loc "\t" s
  if (l ~ DCO) print "DCO\t" loc "\t" s

  # A rule in another language is answered before the English path: a Japanese
  # sentence that names AI and says the project does not take it is a refusal,
  # and no amount of English grammar in the rules below would find that out.
  # Both halves have to be in the same sentence - naming AI is not a rule, and a
  # refusal with no AI word in it is about something else.
  if (l ~ AI_XX || l ~ AI) {
    if (l ~ FORBID_XX)                              { print "FORBID\t" loc "\t" s; next }
    if (l ~ DISCLOSE_XX && l !~ NODISCLOSE_XX)      { print "DISCLOSE\t" loc "\t" s; next }
  }
  if (l !~ AI) {
    # named in another language, but no rule in the sentence
    if (l ~ AI_XX) print "MENTION\t" loc "\t" s
    next
  }

  if (l ~ W("co-?author(ed-by|ed|s|ship)?") && l ~ NEG_COAUTHOR) { print "NOCOAUTHOR\t" loc "\t" s; next }
  # "slop" alone is a quality rule, not an AI rule
  if (l !~ AI_NOSLOP) { print "MENTION\t" loc "\t" s; next }

  forbid = (l ~ FORBID) && (l !~ NOFORBID)
  unread = (l ~ CLOSED_UNREAD) && (l !~ NOT_DISCLOSED_COND)
  head = l
  sub(/^[-*+#>[:space:]]+/, "", head)
  sub(/^[0-9]+[.)][ \t]+/, "", head)
  sub(/^\[[ x]\][ \t]*/, "", head)
  # AGENTS.md and friends are written at the tool. A prohibition there that
  # addresses the reader ("refuse to open the pull request yourself") limits what
  # the tool may do unattended; it is not the project refusing AI-assisted work.
  # A rule with no "you" in it ("AI-generated patches are not accepted") still
  # reads as a refusal wherever it is written.
  agentfile = (tolower(fname) ~ AGENTFILE) && (l ~ W("you|your|yourself"))
  # "automated AI code review is not permitted" is a rule about reviewing. The
  # word "code" in "code review" must not read as the subject of the sentence.
  rl = l; gsub(/code review[a-z]*/, "review", rl)
  # a list heading keeps its colon under the emphasis markers: Processing writes
  # "**Not allowed (generative use):**", which still introduces a list.
  colon = s; sub(/[*_`~ \t]+$/, "", colon)
  mandatory = (l ~ MANDATORY) || (head ~ "^" IMPERATIVE) \
              || (head ~ "^(when|if|where|before|after|while|once)[^,]*, *" IMPERATIVE)
  # "be honest about it when asked" is an answer to a question, not a declaration
  if (l ~ W("when asked|if asked|upon request|on request|when we ask")) mandatory = 0
  # A sentence that offers the choice is not an obligation, even under an
  # imperative heading: pytest heads the paragraph "**Credit AI tools via
  # attribution.**" and then writes "consider adding ``Co-authored-by``
  # trailers". A sentence that says both ("you must consider the licence and
  # disclose the tool") keeps its modal.
  if ((l ~ SOFTENER) && (l !~ W("must|shall|mandatory|requir(e|es|ed|ement)s?"))) mandatory = 0
  disclose = (l ~ DISCLOSE) && (l !~ NODISCLOSE)
  allow = ((l ~ ALLOW) && (l !~ NOT_ALLOW)) || (l ~ NODISCLOSE)
  # a checkbox in a pull request template is a required declaration - but only
  # when the box is about declaring AI use. "I read the AI guidelines" is an
  # acknowledgement, and "I am not using AI tools" is the empty branch of it.
  checkbox = tickbox && disclose
  # a line that carries a word and its negation ("Acceptable vs Unacceptable Use
  # of AI", a table header) is a contrast, not a rule
  if (l ~ /acceptable/ && l ~ /unacceptable/) { print "MENTION\t" loc "\t" s; next }

  # "this contribution was not created with AI" is neither a ban nor a
  # disclosure on its own; what it means depends on whether the same project
  # also offers a way to declare that AI was used. policy_scan.sh decides.
  # "this repository does not use automated AI code review" has the shape of an
  # attestation but is a statement about reviewing, not about the contribution.
  reviewonly = (rl ~ REPLY_SUBJECT) && (rl !~ W("code|patch(es)?|diffs?"))
  noai = (l ~ NOAI_ATTEST) && !reviewonly
  if (noai && l !~ IFCLAUSE && !(l ~ ALLOW && l !~ NOT_ALLOW)) { print "NOAI_ATTEST\t" loc "\t" s; next }

  if (forbid) {
    if (l ~ CONCEAL) {
      if (mandatory) cls = "DISCLOSE"; else cls = "DISCLOSE_SOFT"
    } else if (noai || tickbox) {
      # a checklist line the contributor confirms ("if AI was used, the code does
      # not include regurgitated code"), phrased as a negation. A tick box is one
      # of these even when it reads like a ban: TorchGeo's disclosure form offers
      # "[ ] No AI usage: written by humans, for humans" as one of its options.
      print "NOAI_ATTEST\t" loc "\t" s; next
    } else if (agentfile) {
      cls = "OVERSIGHT"
    } else if (l ~ NEG_OVERSIGHT) {
      cls = "OVERSIGHT"
    } else if (l ~ IFCOND && !unread && (disclose || l ~ OVERSIGHT)) {
      if (disclose) cls = "DISCLOSE"; else cls = "OVERSIGHT"
    } else if (l !~ ENUM && !unread && (l ~ AUTONOMY || (l ~ AUTONOMY_WEAK && l !~ PLAIN_AI))) {
      cls = "OVERSIGHT"
    } else if (rl ~ REPLY_SUBJECT && rl !~ W("code|patch(es)?|diffs?") && !unread) {
      cls = "ISSUE_ONLY"
    } else if (l ~ ISSUE_ONLY_SUBJECT && l !~ PR_SUBJECT) {
      cls = "ISSUE_ONLY"
    } else if (l ~ MEDIA_ONLY_SUBJECT && (l !~ PR_SUBJECT || l ~ EXCEPT)) {
      cls = "MEDIA_ONLY"
    } else if ((l ~ QUALIFIER || l ~ QUALITY) && l !~ ENUM) {
      cls = "FORBID_PARTIAL"
    } else if (head ~ ANAPHOR) {
      # the subject points back at the previous sentence, which is read on its
      # own: "These PRs will be closed immediately, as AI cannot hold copyright"
      cls = "FORBID_PARTIAL"
    } else if (colon ~ /:[ \t]*$/) {
      # "It is not acceptable to use Generative AI tools to:", "Not allowed
      # (generative use):" introduce a list. The items that follow are read on
      # their own, so the heading is not the blanket ban it looks like.
      cls = "FORBID_PARTIAL"
    } else if (l ~ QUALCOND && !unread && l !~ NOASSIST) {
      # the refusal carries a qualifier it did not have to carry ("PRs that
      # result from running an AI tool over the codebase without prior context",
      # "unless specifically requested by the maintainers"). "If you are X, get
      # out" is not one of these: that condition is about the contributor.
      cls = "FORBID_PARTIAL"
    } else {
      cls = "FORBID"
    }
  } else if (checkbox) {
    cls = "DISCLOSE"
  } else if (disclose) {
    if (mandatory) cls = "DISCLOSE"; else cls = "DISCLOSE_SOFT"
  } else if (l ~ OVERSIGHT && mandatory) {
    cls = "OVERSIGHT"
  } else if (allow) {
    cls = "ALLOW"
  } else {
    cls = "MENTION"
  }
  print cls "\t" loc "\t" s
}
