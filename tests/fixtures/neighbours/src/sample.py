# Stand-in for a neighbour module, so check_neighbours.sh can be graded without
# the network: three patterns, one list of two paths, no DCO handling.
RULES = [
    re.compile(r"no ai-generated code"),
    re.compile(r"must be fully human-written"),
    re.compile(r"all ai usage must be disclosed"),
]

CANDIDATE_FILES = [
    "AI_POLICY.md",
    "CONTRIBUTING.md",
]
