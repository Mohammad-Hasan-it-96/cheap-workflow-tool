Some tasks in TASKS.md are marked `- [!]`  -  the runner tried them, the test
gate failed, and the working tree was rolled back so nothing of them survives.

For EACH blocked task:

1. Read its transcript in `.agent/task-*.log` and the test output in the
   matching `.tests` file. Read the failure before forming an opinion.

2. Decide which of these it actually was, in this order of likelihood:
   a. THE TASK WAS TOO BIG OR AMBIGUOUS  -> replace it with 2-4 smaller tasks,
      each naming one file and one exact behaviour.
   b. THE TEST WAS WRONG  -> this happens more than people expect. A fixture
      that contradicts the assertion, an assertion for behaviour nobody
      specified. Fix the test, keep the task as it was.
   c. A RULE AGENTS.md NEVER STATED  -> add the rule to AGENTS.md with a
      right/wrong code pair, then re-queue the task unchanged.
   d. THE MODEL GENUINELY FAILED  -> least common. Re-queue it unchanged, or
      note that it needs a stronger executor.

3. Apply the fix:
   - Change the `- [!]` back to `- [ ]` and strip the `<!-- BLOCKED ... -->`
     marker so the runner picks it up again.
   - If you split it, replace that one line with the smaller ones.
   - Never delete the history of what ran. Leave `- [x]` lines alone.

Do NOT implement any of the tasks. Fix the queue, the tests, or AGENTS.md  - 
nothing else.

When done, tell me for each blocked task which of a/b/c/d it was, in one line
each. If the same cause appears twice, say so  -  that is a rule worth adding to
AGENTS.md rather than fixing case by case.
