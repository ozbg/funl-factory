# The retro — run end

The orchestrator fills it when a milestone closes (`run-workflow.md` → "Goal reached"), after
`super-board report --log`. It writes `docs/super-board/runs/<date>-<slug>-retro.md` beside the
run manifest and commits both. Every number comes from the report or the walk's run folder;
nothing is measured twice. Plain, short lines. A section with nothing to say reads `none`.

```markdown
# Retro: <app> <milestone>, <date>

## Result

| | Target | This run |
|---|---|---|
| <each target line from the report> | | ✅ / ❌ / n/a <value> |

## Product quality

| | Result |
|---|---|
| Screens match the mock-up | <passed>/<screen cards>, and each screen that failed QA's match at least once |
| AI exams | #<card> <score>/<total> (pass <mark>) <model>, one per exam card |
| Agent walk | screens <p>/<n> · questions <a>/<q> · <passed / failed / findings accepted: why> |
| Walk findings | #<card> <one line>, one per finding filed |
| Cut from mock-up | <count>, and any cut the walk or the owner missed |
| Owner-found defects | what the owner found that the walk did not, one line each, or `none yet` |

## What worked

- <one line each>

## What broke

- <one line each: the symptom, then the cause>

## Factory changes

- <each change the factory needs, ticketed on the factory repo, not on this board>
```

Owner-found defects are the measure of the walk itself: anything the owner finds in the first
days of use that the walk passed is a gap in the walk's rubric. Add those lines when the owner
reports them, and ticket the rubric fix on the factory repo.
