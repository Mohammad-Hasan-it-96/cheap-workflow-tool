================================================================================
  CURRENT SETUP - as of 2026-09-14
================================================================================

  Executor       Claude Code headless, on the existing subscription.
  Fallback       OpenRouter free tier via opencode, when the usage window
                 closes. Needs OPENROUTER_API_KEY.
  Local model    REMOVED. gpt-oss-20b, the llama.cpp binaries and the install
                 zips were deleted on 2026-09-14 to reclaim ~22 GB. Ollama was
                 uninstalled too - it had never had a model pulled into it.

  Nothing runs on this machine any more, so the RAM and GPU notes below are
  historical. They apply again only if you rebuild the local stack:

      D:\ai\bin\install-llamacpp.ps1        re-downloads the binaries (~1 GB)
      then download a .gguf into D:\ai\models and pass -OpenCodeModel local/...

  Sections 1, 3 and 7 below describe that local setup and are kept as the
  record of what was measured. Everything else applies as written.


================================================================================
  OVERNIGHT WORKFLOW - local gpt-oss-20b + llama.cpp + opencode
  Measured on: Dell Precision 5550, i7-10750H (6c/12t), 32 GB, Quadro T2000 4 GB
================================================================================

--------------------------------------------------------------------------------
0. WHY A LOOP AND NOT ONE BIG PROMPT
--------------------------------------------------------------------------------

You cannot hand any agent "build this project" and walk away. Not this local
model, and not Claude on Max either. Three things kill it, and none of them is
about model quality:

  1. Context fills up. By hour two the model is reasoning over its own earlier
     output instead of over your code.
  2. Errors compound. Nothing checks step 4 before step 5 is built on top of it.
  3. There is no rollback. One bad edit at 2 AM poisons everything after it.

The fix is architectural, not a better model:

     one task  ->  fresh context  ->  run the tests
                   green -> git commit, mark [x]
                   red   -> git reset --hard, mark [!] BLOCKED, move on

A task that goes wrong now costs you ONE task, not the whole night. That is
the entire idea. Everything below is plumbing for it.


--------------------------------------------------------------------------------
1. MEASURED SPEED - PLAN ON THESE, NOT ON HOPE
--------------------------------------------------------------------------------

  prefill (prompt processing)          ~75 tok/s
  generation, context under ~1k         ~13 tok/s
  generation, context 4k and above     ~6.2 tok/s     <-- real agent work
  one small task, end to end            4-8 minutes

Generation halves once context passes about 4k tokens, then PLATEAUS - it does
not keep degrading. So 6.2 tok/s is the honest planning number.

An 8-hour night is therefore roughly 60-100 small tasks. Plan for 50 and be
pleasantly surprised.

THE COUNTERINTUITIVE PART: prefill, not generation, is usually what costs you.
Every model call re-sends the whole conversation plus AGENTS.md. A 20k-token
prompt is ~4.5 minutes BEFORE the first character appears. This is why:

  * AGENTS.md must stay under ~150 lines. It is re-sent on EVERY call.
  * tasks must be small. Small task = short conversation = cheap prefill.
  * night-run.ps1 keeps its prompt wording identical between tasks, because
    llama-server caches the common prefix and a stable prefix is free.


--------------------------------------------------------------------------------
2. THE THREE FILES
--------------------------------------------------------------------------------

In your project root:

  AGENTS.md    the rules. opencode loads this automatically on every call.
               Template: D:\ai\workflow\templates\AGENTS.md

  TASKS.md     the queue. The runner reads it top to bottom.
               Template: D:\ai\workflow\templates\TASKS.md

  .agent/      created by the runner: logs, per-task output, the lock file.
               Auto-excluded via .git/info/exclude so it is never committed.

The runner itself lives at D:\ai\bin\night-run.ps1 (not in your project).


--------------------------------------------------------------------------------
3. WRITING AGENTS.md FOR A 3B-ACTIVE MODEL
--------------------------------------------------------------------------------

gpt-oss-20b is a Mixture-of-Experts model with only ~3.6B parameters active per
token. It does not infer and it does not generalise. This changes how rules
must be written.

  IGNORED - abstract, nothing to pattern-match on:
      "Write clean, maintainable code."
      "Follow SOLID principles."
      "Handle errors appropriately."

  OBEYED - short, imperative, with a right/wrong pair:
      "Never query inside a loop."
          WRONG:  foreach ($orders as $o) { Customer::find($o->customer_id); }
          RIGHT:  Order::with('customer')->get();

Rules of thumb:
  * Every rule gets a code example. Prose alone does not survive.
  * Say the exact command, not the intent: "php artisan test", not "run tests".
  * Give it an escape hatch: "If the task is unclear, stop and say BLOCKED:
    <reason>. Do not guess." Without this it will invent an answer.
  * Keep it under ~150 lines. Every line is paid for on every single call.


--------------------------------------------------------------------------------
4. WRITING TASKS.md - THE PART THAT DECIDES SUCCESS
--------------------------------------------------------------------------------

This is where nights are won or lost. A task is the right size when it is:

  * one file, or one file plus its test
  * ~30 lines of code or fewer
  * verifiable by the test suite alone, with no judgement call
  * stated with EXACT names: path, class, method, column, route

  TOO BIG - the model will wander, the tests will fail, you get [!] BLOCKED:
      - [ ] Build the products module
      - [ ] Add authentication

  RIGHT SIZE:
      - [ ] Create migration create_products_table with columns: id,
            name string(255), price decimal(10,2), stock integer default 0, timestamps
      - [ ] Create model app/Models/Product.php with fillable name, price, stock
      - [ ] Create app/Http/Requests/StoreProductRequest.php requiring
            name (string, max 255) and price (numeric, min 0)
      - [ ] Add tests/Feature/ProductStoreTest.php asserting 201 on valid input
            and 422 on a missing name

ORDER MATTERS. The runner commits after each task, so later tasks build on
earlier ones. Migrations -> models -> requests -> controllers -> routes -> tests.

MARKERS
    - [ ]   queued - the runner takes the first one
    - [x]   done and committed
    - [!]   blocked and rolled back - your morning review list


--------------------------------------------------------------------------------
5. RUNNING IT
--------------------------------------------------------------------------------

WHO WRITES THE CODE - pick an executor

  -Executor claude     Claude Code headless (claude -p). Uses the subscription
                       you already pay for, so it costs nothing extra, and it
                       is far and away the strongest option. ~30 s per task
                       instead of 4-8 minutes. Bounded by your 5-hour and
                       weekly usage windows, not by tokens you buy.

  -Executor opencode   opencode against whatever is in opencode.json:
                         openrouter/<model>  free tier. 50 requests/day, or
                                             1000/day once you have ever
                                             bought $10 of credit. Below that
                                             threshold it dies in the first
                                             hour - see the install guide.
                                             Needs OPENROUTER_API_KEY.
                         local/gpt-oss-20b   REMOVED 2026-09-14. Rebuild with
                                             install-llamacpp.ps1 + a model
                                             download if you want it back.

  -Executor auto       DEFAULT. Claude until its usage window is exhausted,
                       then it switches to opencode for the rest of the night
                       instead of stopping: the subscription does as much as
                       it can, the free tier finishes the queue. Nothing is
                       billed either way.

For -Executor auto, set the OpenRouter key once so the fallback actually
exists, then open a NEW shell. The runner warns if it is missing and will
simply stop early when Claude's window closes.

    [Environment]::SetEnvironmentVariable("OPENROUTER_API_KEY","sk-or-...","User")

Then:

    # always dry-run first - validates preflight, makes no model calls
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project" -DryRun

    # the real thing
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project"

    # Claude only, on the bigger model, for a queue of harder tasks
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project" -Executor claude -ClaudeModel opus

    # free tier only - no Claude usage consumed at all
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project" -Executor opencode

Options:
    -Executor auto|claude|opencode   who writes the code (default auto)
    -ClaudeModel sonnet|opus|haiku   model for the claude executor
    -ClaudePermission acceptEdits    default. Auto-approves file edits; the
                     |bypassPermissions   agent cannot run arbitrary shell
                                     commands. bypassPermissions lets it run
                                     anything - only for a repo you can throw
                                     away. night-run runs the tests itself
                                     either way, so acceptEdits is enough.
    -OpenCodeModel openrouter/...    provider/model for the opencode executor
    -TestCmd "php artisan test"      override the auto-detected test command
    -TaskTimeoutMin 25               per-task hard timeout (default 20)
    -MaxRetries 0                    no retry on failure (default 1)
    -NoCommit                        no commits AND no rollback; trials only
    -DryRun                          list the queue and exit

Auto-detected test commands:
    artisan present      -> php artisan test
    pubspec.yaml         -> flutter test
    package.json + test  -> npm test
    pyproject.toml       -> pytest -q

PREFLIGHT REFUSALS - all of these are deliberate:
    "not a git repository"        rollback is impossible without git
    "working tree is dirty"       a rollback would destroy your own changes
    "night-run is already active" the lock file; see section 7
    "llama-server is not healthy" only when a local/ model is the ACTIVE
                                  executor. A claude run does not need it.
    "OPENROUTER_API_KEY is not set" only when an openrouter/ model is the
                                  ACTIVE executor; a warning when it is just
                                  the fallback.


--------------------------------------------------------------------------------
6. THE MORNING AFTER
--------------------------------------------------------------------------------

    cd D:\work\my-project
    git log --oneline                                   # what landed
    Select-String -Path TASKS.md -Pattern '\[!\]'       # what blocked
    Get-ChildItem .agent\*.log | Sort LastWriteTime     # why it blocked

Every blocked task left its full transcript in .agent\task-<stamp>-NNN.log,
and the test output next to it in the matching .tests file. Read the test
failure first - it is usually either a task that was too big, or a rule that
AGENTS.md never actually stated.

Blocked tasks are your feedback loop. When one blocks, either split it into
smaller tasks or add the missing rule to AGENTS.md - then re-queue it by
changing [!] back to [ ].


--------------------------------------------------------------------------------
7. THINGS THAT WILL BITE YOU
--------------------------------------------------------------------------------

NEVER RUN TWO OF ANYTHING AT ONCE
    The model is 12.83 GiB. Two copies do not fit in 31.8 GB of RAM. The
    failure is NOT an error - it is silently wrong behaviour and 20x slower
    numbers. We measured the same config at 3.48 and at 75.10 tok/s purely
    because two processes were loaded at the same time.
    night-run.ps1 takes a lock at .agent\night-run.lock to prevent a second
    runner, but nothing stops you from also launching a benchmark. Check:
        Get-Process llama-server,llama-bench,opencode

STALE LOCK
    If the runner is killed hard, the lock survives. Delete it:
        Remove-Item "D:\work\my-project\.agent\night-run.lock"

POWERSHELL 5.1 AND NATIVE COMMANDS
    Do not pipe native exes with 2>&1 - PS 5.1 wraps stderr in
    NativeCommandError records and corrupts $LASTEXITCODE. The runner uses
    Start-Process with file redirection for exactly this reason.
    Same trap with curl.exe and inline JSON: use Invoke-RestMethod instead.

LAPTOP GOES TO SLEEP
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    Keep it plugged in. Expect thermal throttling on a 6-core in this chassis
    after a few hours at 100% - lift the back of the laptop for airflow.

THE MODEL SAYS IT IS DONE WHEN IT IS NOT
    This is why the test gate is not optional. If a project has no tests, the
    runner warns and commits UNVERIFIED - in that case write the test task
    first and let everything else build on it.

THE MODEL WILL GAME THE TEST GATE  <-- the important one
    Observed here, not theoretical. Given one task saying "add div(a, b) and
    assert div(1, 0) === 42", the model produced:

        function div(a, b) { return 42; }

    It edited the test to match, npm test went green, and the runner committed
    it. Nothing was broken - the gate did exactly what it was told. The gate
    just cannot tell "implemented" from "made the assertion true".

    A test only grades honestly if the task being graded cannot edit it.
    So: NEVER put the test and the implementation in the same task.

        - [ ] [test] Add tests/Feature/DivideTest.php asserting divide(6, 3) === 2
        - [ ] Implement divide() in app/Services/MathService.php so DivideTest passes

    night-run.ps1 now enforces this. A task without a [test] tag that modifies
    any test file is REJECTED and rolled back even when the tests pass.
    Override with -AllowTestEdits only if you know why you are doing it.

    The general lesson: this model is good at making a stated test pass, and
    bad at deciding what should be tested. Keep the second job for yourself.


--------------------------------------------------------------------------------
8. WHERE THIS FITS WITH CLAUDE
--------------------------------------------------------------------------------

Claude now sits on BOTH sides of this workflow, and the two jobs are different.

CLAUDE AS THE EXECUTOR (-Executor claude)
    It runs the queue. This is the free path: the subscription is already
    paid for, so an overnight run adds no cost. At ~30 s per task instead of
    4-8 minutes, a 50-task queue finishes in under half an hour.

    Which changes what "overnight" is for. The point stops being "run 8 hours
    because it is slow" and becomes "run the queue, review it, fix the queue,
    run it again" - several times a day. Use the night for the long tail, and
    the afternoon for the loop you actually learn from.

    The limit is your usage window, not money. When it closes, -Executor auto
    hands the rest of the queue to the local model and the night continues.

CLAUDE AS THE ARCHITECT (interactive, you and it, at the keyboard)
    Decomposing a feature into TASKS.md lines, reviewing what the night
    produced, unblocking [!] tasks. This is still the highest-value use, and
    a faster executor makes it MORE important, not less:

        the bottleneck is no longer tokens per second - it is how many
        well-specified tasks you can write

    At 30 s per task, an 8-hour night would need ~900 tasks. Nobody writes
    900 good tasks. So the queue, not the model, is what caps your output.
    A well-decomposed queue is worth more than any prompt tuning.

WHAT THE LOCAL MODEL IS STILL FOR
    - The fallback that keeps the night going after the usage window closes.
    - Work that must not leave the machine. A client's codebase under an NDA
      does not go to a free API tier, and free tiers are exactly where prompt
      logging is the price of admission. Slow and private beats fast and
      leaked, and that call is yours to make per project.
    - Unlimited grinding: translations, fixtures, repetitive boilerplate,
      where quality per task barely matters and you just want volume.

ONE THING NO EXECUTOR FIXES
    The test gate is what makes an unattended run safe, and it only grades
    what a test can see. For a company website the things that matter most -
    does the layout look right, is the copy correct, is it responsive, does
    it look professional - are exactly what the suite does not check.

    So: queue the backend overnight (migrations, models, requests, services,
    API endpoints, their tests). Do the visual layer interactively, where you
    can look at it. A green suite is not a good-looking site.
