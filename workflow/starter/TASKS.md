# TASKS.md

<!--
  THE QUEUE. night-run.ps1 reads this top to bottom, one task per model call.

    - [ ]  queued        <- the runner takes the first of these
    - [x]  done, committed
    - [!]  blocked, rolled back  (your morning review list)

  Every task below names ONE file, ONE function, and the EXACT behaviour the
  test already asserts. That is what makes them safe to run unattended.

  The tests in tests/run.js are already written and must not be edited - which
  is why none of these tasks carries a [test] tag. Writing the tests is your
  job, not the model's; the model is good at making a stated test pass and bad
  at deciding what should be tested.
-->

## Queue

- [ ] Create src/slugify.js exporting slugify(str): lowercase the string, strip accents so "Café" becomes "cafe", replace every run of non-alphanumeric characters with a single hyphen, and trim leading and trailing hyphens

- [ ] Create src/money.js exporting formatMoney(n): return n with exactly two decimals, comma-separated thousands, and a leading minus for negatives, so 1234.5 becomes "1,234.50" and -9.005 becomes "-9.01"

- [ ] Create src/contact.js exporting validateContact(obj): return an array of error strings for a contact form, empty when valid; push "name is required" when name is empty or whitespace, "email is invalid" when email does not match a basic address pattern, and "message must be at least 10 characters" when message is shorter than 10 characters

- [ ] Create src/paginate.js exporting paginate(rows, page, perPage): return { items, page, pages, total } where items is the requested slice of rows, total is rows.length, pages is the number of pages rounded up with a minimum of 1, and items is an empty array when page is beyond the last page
