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

Start the model server first (leave it running all night):

    powershell -ExecutionPolicy Bypass -File D:\ai\bin\start-server.ps1

Then, in a second window:

    # always dry-run first - validates preflight, makes no model calls
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project" -DryRun

    # the real thing
    D:\ai\bin\night-run.ps1 -Root "D:\work\my-project"

Options:
    -TestCmd "php artisan test"   override the auto-detected test command
    -TaskTimeoutMin 25            per-task hard timeout (default 20)
    -MaxRetries 0                 no retry on failure (default 1)
    -NoCommit                     run without committing (for trying it out)
    -DryRun                       list the queue and exit

Auto-detected test commands:
    artisan present      -> php artisan test
    pubspec.yaml         -> flutter test
    package.json + test  -> npm test
    pyproject.toml       -> pytest -q

PREFLIGHT REFUSALS - all of these are deliberate:
    "not a git repository"       rollback is impossible without git
    "working tree is dirty"      a rollback would destroy your own changes
    "night-run is already active" the lock file; see section 7
    "llama-server is not healthy" start the server first


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

Do not try to make the local model do everything. Split by what each is good at:

    Claude (Max)      architecture, decomposing a feature into TASKS.md lines,
                      reviewing what the night produced, unblocking [!] tasks
    Local model       the mechanical grind: CRUD, migrations, form requests,
                      boilerplate, translations, repetitive tests

The highest-value thing Claude does here is WRITE TASKS.md. A well-decomposed
queue is worth more than any prompt tuning - it is the difference between 50
green commits and 50 blocked tasks.
