Read {SOURCE} and append {COUNT} new tasks to TASKS.md.

You are writing a QUEUE, not code. Write no implementation in this session.

HOW TO APPEND
- Add the new tasks at the END of the "## Queue" section.
- Never modify, reorder or delete a line that already exists, especially any
  `- [x]` or `- [!]` line. Those are the record of what already ran.
- Each task is exactly one line starting with `- [ ] `. No nesting, no bullets
  underneath, no blank line between tasks.
- Put nothing inside `<!-- -->`. The runner skips HTML comments, so a task
  written there is silently never executed.

HOW TO SIZE A TASK - this is the part that decides whether the run works
A task is the right size when it is:
- ONE file, or one file plus its test
- about 30 lines of code or fewer
- verifiable by the test suite ALONE, with no judgement call and no screenshot
- stated with EXACT names: file path, class, method, column, route, field

  TOO BIG - the model wanders, the tests fail, the task is rolled back:
    - [ ] Build the products module
    - [ ] Add authentication
    - [ ] Improve performance

  RIGHT SIZE:
    - [ ] Create migration create_products_table with columns: id, name
          string(255), price decimal(10,2), stock integer default 0, timestamps
    - [ ] Create app/Models/Product.php with fillable name, price, stock

ORDER MATTERS. The runner commits after each task, so a later task can rely on
an earlier one. Schema before models, models before services, services before
controllers, controllers before routes.

TESTS ARE SEPARATE TASKS. Never put a test and its implementation in the same
task: a task that can edit both can always make them agree, which is how a
model fakes a pass. Write the test task first and tag it `[test]`:

    - [ ] [test] Add tests/Feature/DivideTest.php asserting divide(6, 3) === 2
          and that divide(1, 0) throws InvalidArgumentException
    - [ ] Implement divide(float $a, float $b): float in app/Services/MathService.php
          so the existing DivideTest passes

The runner REJECTS any untagged task that modifies a test file, so an untagged
task that needs a test will be rolled back.

BEFORE YOU WRITE
1. Read AGENTS.md and match its stack, naming and conventions exactly.
2. Read the existing TASKS.md so you do not queue something already done.
3. Look at the real code to confirm what exists. Do not invent a file, column
   or route that is not there - a task naming something imaginary always fails.

WHAT NOT TO QUEUE
Anything a test cannot check: visual layout, copy, spacing, responsiveness,
"make it look professional". Those are for an interactive session, not this
queue. If the requirement is visual, skip it and say so at the end.

WHEN DONE
Show me the tasks you appended, then tell me in one line what you deliberately
left out and why.
