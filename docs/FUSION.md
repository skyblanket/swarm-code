# Fusion Research and Council Prototype

## OpenRouter pipeline

OpenRouter Fusion is bounded test-time orchestration, not a separately trained
foundation model:

1. An outer model decides whether the prompt benefits from deliberation.
2. One to eight panel models answer in parallel.
3. Each panel model may use OpenRouter web search and web fetch.
4. A judge compares responses and returns structured consensus,
   contradictions, partial coverage, unique insights, and blind spots.
5. The outer model writes the final answer from that structured analysis.

The default Quality preset uses current Opus, GPT, and Gemini Pro aliases.
Panels and the judge are configurable. OpenRouter documents partial-panel
success, judge degradation to raw responses, all-panel failure, and recursion
protection. A default three-model panel costs roughly four to five times a
single completion.

OpenRouter reported that roughly three quarters of Fusion's benchmark lift
came from synthesis and one quarter from model diversity. On its 100-task
DRACO deep-research run, stronger panels beat solo Fable 5; a budget panel
using Gemini Flash, Kimi K2.6, and DeepSeek V4 Pro landed within about one
point of Fable 5 at roughly half the cost. This is evidence for deep research,
not autonomous coding.

Primary references:

- https://openrouter.ai/docs/guides/routing/routers/fusion-router
- https://openrouter.ai/docs/guides/features/server-tools/fusion
- https://arxiv.org/abs/2602.11685

## swarm-code prototype

`scripts/council.sh` mirrors the useful shape while making panelists
repository-aware:

- three parallel perspectives: architect, skeptic, and operator;
- a read-only, non-recursive `council_panel` execution context;
- a no-tools `council_judge` context;
- per-stage wall-clock deadlines and output-token caps;
- structured synthesis headings instead of majority voting;
- optional profile diversity through `SWARM_COUNCIL_PROFILES`.

The first unconstrained experiment recursively delegated and ran too long.
The first bounded attempt timed out because panelists spent their budget
discovering paths and reading broadly. After requiring relative paths and a
six-tool-call research budget, all three panelists completed and the judge
produced a useful synthesis. The panel also found a real fail-open issue:
missing or unknown execution contexts were not denied. That boundary now
fails closed and has unit and integration coverage.

## Production gaps

- Add a true workspace filesystem sandbox before calling panel isolation
  production-grade.
- Move orchestration from the shell prototype into a native module and CLI
  surface.
- Persist run manifests, panel outputs, timings, token usage, and estimated
  cost.
- Preserve useful partial outputs when a panelist reaches its deadline.
- Add cancellation that terminates panel and judge children as one run.
- Filter schemas by execution context so restricted agents do not see tools
  they cannot call.
- Benchmark council quality and cost against single-agent review on real
  repository tasks.
