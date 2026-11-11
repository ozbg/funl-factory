# Exam card

An AI feature can pass every test on the fake model and still be useless. The exam asks the real
model the owner's day-one questions, through the app's own code, and scores the answers.

**An AI feature** is a must-have served by an AI call: chat, an agent, a summary, a draft, a search
that asks a model. `/to-board` cuts **one exam card per AI feature**, after the slice cards that build
it and before the Demo card.

## Questions

- Take every `- M<n>: <question> → <expected answer>` line for that must-have from
  `## Day-one questions` in north-star.md.
- Fewer than 10: top up from the spec, the mock-up's sample data and the must-have's own words,
  until there are **10 or more**. Mark each top-up `(spec)`. Keep the owner's lines word for word.
- Each question has an **expected answer** and a **judge**:
  - `facts:` the exact facts that must appear in the answer, for example `51 824 753 556`,
    `Harbour Freight`. Prefer this: the script checks it.
  - `rubric:` one short line, only when no fact fits, for example `asks before sending; names the
    recipient`. The QA agent scores it from the recorded answer.
- **Pass mark:** at least 8 of 10, scaled for more (8/10, 10/12). Higher for a feature the core loop
  rests on. Set it here; nobody lowers it later.

## The exam

- **One script or test in the app**, for example `tests/exam/<feature>.exam.ts`, run by one
  command, for example `npm run exam:<feature>`. The default test command never runs it: exclude it
  by file pattern or folder, so the offline test run stays offline.
- **Real model only.** It uses the provider and model the app is configured for. It refuses to
  start on the fake or mock model and exits non-zero with `exam: needs the real model`.
- **The app's own path.** Each question goes through the same entry point a user's question does
  (route, action or agent function), with the same context, tools and rules. Never a hand-made
  prompt straight to the provider.
- **Seeded realistically.** Its own seed, made up but realistic: the mock-up's sample data plus every
  fact the questions need, at about the north star's volumes. Never the owner's real data.
- **Privacy.** It runs locally. It sends only what the app itself would send to that provider, and
  to no other host. No logging service, no judge on another provider.
- **Output.** One line per question (`pass`, `fail` or `rubric`, with the answer) and a last line
  `score: <passed>/<total> · pass mark <n> · model <model id>`. The full answers go to the QA
  evidence folder, never committed.

## Layout

The card template's sections, with these differences:

- Title: `🧪 [test] exam: M<n> <feature> on the real model`
- **Files:** the exam file, its seed file, and the file that holds the exam command and the
  exclusion (for example `package.json`). At most 5.
- **Zone:** the zone the files give. Even when green, the wave sends an exam card to QA: QA must run the exam.
- **Must-have served:** the AI feature's number.
- **Pattern:** the foundation's test file.
- **Needs judgement:** `yes — AI exam on the real model`. Build and QA run on Sonnet. Exam cards do
  not count toward the one-in-ten limit.
- A `## Exam` section after `## Context`:

  ```markdown
  ## Exam
  Pass mark: 8/10 · command: `npm run exam:<feature>`

  | # | Question | Expected answer | Judge |
  |---|---|---|---|
  | 1 | What's my ABN? | 51 824 753 556 | facts: 51 824 753 556 |
  | 2 | Which company is Dana Lee with? | Harbour Freight | facts: Harbour Freight |
  ```

- ACs (test hints as usual):
  - the exam file holds every question, expected answer and judge in `## Exam`, unchanged
  - the default test command does not run the exam, and the exam refuses the fake model
  - the seed holds every fact the questions need
  - on the real model, the exam scores at or above the pass mark
- `## Blocked by`: the slice cards that build the AI feature.

## Rules for the lanes

- The builder never edits a question, an expected answer, a judge or the pass mark. Those are the
  owner's. A low score is fixed in the feature (context, tools, data it can reach), not by
  tuning the prompt to the questions.
- A low score that a spec rule causes (for example, an invariant that keeps tool results from the
  model) is not the builder's to fix: the card goes Blocked, 🙋, naming the rule.
- QA runs the exam and records the score (`lanes/qa.md` → "Exam cards").
