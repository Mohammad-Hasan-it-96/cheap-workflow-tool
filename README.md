# Cheap Workflow Tool

Run a queue of small, test-gated coding tasks against whichever agent is
cheapest right now. Built for freelance work on a modest laptop: a Windows GUI
over a PowerShell runner, no server, no paid API, no pip install.

**It works on projects you already have.** Pointing it at a repo you have been
building for months only adds the two files it needs, and never overwrites
anything that is already there. Starting from an empty folder is supported, not
required.

---

## What it actually does

    pick one task  ->  run it in a fresh agent session  ->  run the tests
                       green -> git commit, mark [x]
                       red   -> git reset --hard, mark [!] BLOCKED, move on

One task per model call, fresh context each time. That is the whole idea, and
it is architectural rather than clever: a single long prompt always dies
because context fills, errors compound, and nothing verifies the result. Here a
task that goes wrong costs you one task, not the session.

Three things follow from it, and they are the point:

- **Nothing lands unverified.** A task is committed only if the test suite
  passes after it.
- **A task cannot fake its own pass.** An untagged task that modifies a test
  file is rejected and rolled back, even when the tests go green. This is not a
  hypothetical: given *"add div(a,b) and assert div(1,0) === 42"*, a model wrote
  `return 42;`, edited the test to match, and committed it.
- **A bad task is recoverable.** `[!]` in the morning means the tree was reset;
  nothing of it survives.

---

## Requirements

| | |
|---|---|
| Windows | PowerShell 5.1, which ships with it |
| Python 3.8+ | for the GUI only, stdlib and tkinter, nothing to install |
| git | rollback depends on it |
| An agent CLI | [Claude Code](https://claude.com/claude-code) and/or [opencode](https://opencode.ai) |

---

## Free setup, no credit card

`opencode` plus a Google AI Studio key gives you roughly **1000 requests a day
at no cost** — about 200 tasks.

```powershell
npm install -g opencode-ai
# free key, no card: https://aistudio.google.com/apikey
[Environment]::SetEnvironmentVariable('GEMINI_API_KEY','<paste>','User')
```

Open a new terminal afterwards so the variable is visible.

If you also have a Claude subscription, `-Executor auto` spends that first and
drops to free Gemini when the window closes, so a long queue finishes either
way.

---

## Start

```powershell
git clone https://github.com/Mohammad-Hasan-it-96/cheap-workflow-tool
cd cheap-workflow-tool
.\start-gui.bat
```

In the GUI: **Browse** to a project → **Settings → Set up this project** →
**Settings → Apply stack** → **Run → Dry run** → then a real run.

Each run opens in its own titled terminal window, so a Claude run and a Gemini
run are two separate things you can watch and kill independently.

Prefer the command line? The GUI is only a front end:

```powershell
.\bin\new-project.ps1 -Root "D:\work\my-project"
.\bin\night-run.ps1   -Root "D:\work\my-project" -DryRun
.\bin\night-run.ps1   -Root "D:\work\my-project" -Executor opencode
```

---

## The part that decides whether this works

Not the runner. **The queue.**

A well-written `TASKS.md` with a weak model beats a vague one with a strong
model, every time. A task is the right size when it is one file (or one file
plus its test), about 30 lines of code or fewer, verifiable by the suite alone,
and stated with exact names.

```
TOO BIG - the model wanders, tests fail, you get [!]
  - [ ] Build the products module
  - [ ] Add authentication

RIGHT SIZE
  - [ ] Create migration create_products_table with columns: id,
        name string(255), price decimal(10,2), stock int default 0
  - [ ] Create model app/Models/Product.php with fillable name, price, stock
```

You do not have to write it by hand. The GUI's **Tasks → Write tasks with
Claude...** button opens a ready prompt: pick what Claude should read, choose
how many tasks, edit it if you like, then **Copy and open Claude here** and
paste with Ctrl+V.

The prompt is the real artifact — it carries the sizing rules, the
append-don't-overwrite rule, and the test/implementation split. It lives in
`workflow/prompts/write-tasks.md`, so you can edit it once and have every
project benefit. There is a second one, `unblock.md`, behind **Fix blocked
tasks...** for the morning review.

**Never put a test and its implementation in the same task.** A task that can
edit both can always make them agree. Write the tests yourself, or have Claude
write them; the runner enforces the split.

---

## Stack presets

**Settings → Apply stack** writes an `AGENTS.md` tuned to your stack:

- Laravel + React
- Node + Prisma + React (TypeScript)
- Flutter
- Generic

`AGENTS.md` is the rules file re-sent on every model call. The presets are
written as short imperative rules with right/wrong code pairs, because a small
model pattern-matches examples and ignores abstract advice like "write clean
code". Open it after applying and replace the example versions and commands
with your project's real ones — the model has no other source for them.

---

## Reading the morning after

| | |
|---|---|
| `[x]` | done and committed. The queue mark and the code are in the **same** commit. |
| `[!]` | blocked and rolled back. Nothing of it survives in the tree. |

A `[!]` is usually **not** the model being stupid. In order of likelihood:

1. the task was too big or ambiguous → split it, re-queue
2. the test was wrong → check this before blaming the model
3. a rule `AGENTS.md` never actually stated → add the rule
4. the model genuinely failed → least common

Full transcript per task is in `.agent\task-<stamp>-NNN.log`, with test output
beside it. Select blocked rows in the GUI and click **Re-queue** to retry them.

---

## Known limits

- **Windows only.** The runner is PowerShell and the GUI shells out to it.
- **A green suite is not a good-looking site.** The gate gates what a test can
  see. Layout, copy, responsiveness and whether a page looks professional are
  exactly what it cannot check. Queue the backend; do the visual layer
  interactively.
- **The queue is your ceiling, not the model.** At 30–60 seconds per task, a
  full night would need hundreds of well-specified tasks, and nobody writes
  hundreds of good ones. The honest rhythm is write, run, review, fix the
  queue, run again — several times a day.
- Free tiers change without notice. Google retired Gemini Code Assist for
  individuals on 2026-06-18, which killed the Gemini CLI's free sign-in; the
  models stayed free through `opencode`. Expect that kind of thing.

---

## Layout

```
bin/night-run.ps1     the loop: one task per call, test, commit or roll back
bin/new-project.ps1   prepares a project; never overwrites existing files
gui/app.py            tkinter front end
workflow/templates/   AGENTS.md and TASKS.md, plus stacks/ presets
workflow/starter/     a 4-task demo project, known to pass 4/4 free
HOWTO.txt             the whole workflow on one page
```

Something not working? Run the demo — if it passes, your setup is fine and the
problem is in your queue:

```powershell
.\bin\new-project.ps1 -Root "D:\work\starter-demo" -Starter
.\bin\night-run.ps1   -Root "D:\work\starter-demo" -Executor opencode
```
