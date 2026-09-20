STARTER PROJECT - copy this, do not run it in place
===================================================

This is a working example of the whole workflow: four pre-written tasks, a
pre-written test gate, and rules a small model can actually follow. Use it to
prove your setup works before pointing the runner at anything real.

USE IT

    # 1. copy it somewhere outside D:\ai
    Copy-Item -Recurse D:\ai\workflow\starter D:\work\starter-demo
    cd D:\work\starter-demo

    # 2. it MUST be a git repo with one commit - rollback depends on it
    git init
    git add -A
    git commit -m "init"

    # 3. see the queue without calling any model
    D:\ai\bin\night-run.ps1 -Root "D:\work\starter-demo" -DryRun

    # 4. run it on the free executor
    D:\ai\bin\night-run.ps1 -Root "D:\work\starter-demo" -Executor gemini

    # 5. see what happened
    git log --oneline
    npm test

WHAT TO EXPECT

Four commits, one per task, and `npm test` reporting 4/4 modules implemented.
A task that goes wrong is rolled back and marked [!] in TASKS.md - that is the
system working, not a failure. Read .agent\task-*.log to see why.

WHY THE TESTS ARE ALREADY WRITTEN

A task that can edit both its code and the test that grades it can always make
them agree. The model is good at making a stated test pass and bad at deciding
what should be tested. So the tests are yours to write, always.

The suite is green from the start: each block is skipped until its module
exists. So it goes red only when a task does its job BADLY, never just because
later tasks have not run yet.
