# AGENTS.md

<!--
  Kept under ~60 lines on purpose. This file is re-sent on EVERY model call.
  Write for a model that does not infer: short, imperative, right-vs-wrong.
-->

## Stack

- Plain Node.js (CommonJS), no dependencies, no framework.
- Tests: `node tests/run.js`, plain `assert`.

## Commands

```bash
npm test
```

## Hard rules

1. Change only the file the task names. Never refactor unrelated code.
2. Never edit anything under `tests/`. The tests grade you; you do not write them.
3. Export with `module.exports = { name };` using the exact name the task gives.
4. No `require` of any package that is not built into Node. There is no
   `node_modules` here and there will not be one.
5. Run `npm test` before you say the task is done.
6. If the task is unclear, stop and say `BLOCKED: <reason>`. Do not guess.
7. Never make a test pass by returning a hardcoded value. Implement the real
   behaviour, or say `BLOCKED`.

## Code rules with examples

### Export exactly what the task names

WRONG:
```js
module.exports = slugify;          // not an object
export function slugify() {}       // ESM, this project is CommonJS
```

RIGHT:
```js
function slugify(str) { /* ... */ }
module.exports = { slugify };
```

### Never satisfy a test with a constant

WRONG:
```js
function formatMoney(n) {
  return '1,234.50';   // makes one assertion pass, implements nothing
}
```

RIGHT:
```js
function formatMoney(n) {
  const fixed = Math.abs(n).toFixed(2);
  const [whole, cents] = fixed.split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return (n < 0 ? '-' : '') + grouped + '.' + cents;
}
```

### Handle the edge cases the task lists, not just the happy path

If the task says "returns [] when valid", an empty array is the success value.
Do not return `true`, `null`, or a string.

## Definition of done

- `npm test` passes and the count of implemented modules went UP by one.
- No file outside the task's named file was modified.
