# TASKS.md

<!--
  THE QUEUE. night-run.ps1 reads this top to bottom, one task per model call.

  MARKERS
    - [ ]  queued        <- the runner picks the first of these
    - [x]  done, committed
    - [!]  blocked, rolled back  (review these in the morning)

  HOW TO SIZE A TASK  - this is the part that decides whether the night works.

  A task is the right size when it is:
    * ONE file, or one file plus its test
    * roughly 30 lines of code or fewer
    * verifiable by the test suite alone, with no judgement call
    * stated with the exact names to use - path, class, method, column, route

  Budget on this machine: ~4-8 minutes per task
  (~75 tok/s prefill, ~6.2 tok/s generation, 4-6 model calls per task).
  An 8-hour night is therefore roughly 60-100 tasks. Plan for 50.

  WRONG - too big, too vague, needs decisions the model cannot make:
    - [ ] Build the products module
    - [ ] Add authentication
    - [ ] Improve performance

  RIGHT - one file, named things, testable:
    - [ ] Create migration create_products_table with columns: id, name string(255), price decimal(10,2), stock integer default 0, timestamps
    - [ ] Create model app/Models/Product.php with fillable name, price, stock and a casts() returning price => decimal:2
    - [ ] Create app/Http/Requests/StoreProductRequest.php requiring name (string, max 255) and price (numeric, min 0)
    - [ ] Create ProductController@store using StoreProductRequest and returning 201 with the created product
    - [ ] Add route POST /api/products to routes/api.php pointing at ProductController@store
    - [ ] Add tests/Feature/ProductStoreTest.php asserting 201 on valid input and 422 on a missing name

  ORDER MATTERS. The runner commits after each task, so a later task can rely
  on an earlier one. Put migrations before models, models before controllers,
  controllers before routes, and the test last.

  NEVER PUT THE TEST AND THE IMPLEMENTATION IN THE SAME TASK.
  This is not style advice - it was demonstrated. Given a single task saying
  "add div(a, b) and assert div(1, 0) === 42", the model wrote:

      function div(a, b) { return 42; }

  ...edited the test to match, went green, and got committed. A task that can
  edit both its code and its test can always make them agree.

  So split it, and tag the test task with [test]:

      - [ ] [test] Add tests/Feature/DivideTest.php asserting divide(6, 3) === 2
            and that divide(1, 0) throws InvalidArgumentException
      - [ ] Implement divide(float $a, float $b): float in app/Services/MathService.php
            so the existing DivideTest passes

  night-run.ps1 enforces this: a task WITHOUT the [test] tag that modifies any
  test file is rejected and rolled back, even if the tests pass.

  Best of all: write the test tasks yourself (or have Claude write them). The
  local model is good at making a test pass and bad at deciding what the test
  should be.
-->

## Queue

- [ ] 
- [ ] 
- [ ] 
