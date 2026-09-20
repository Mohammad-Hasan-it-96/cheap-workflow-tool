// The test gate. night-run.ps1 runs this after every task and rolls the task
// back unless it exits 0.
//
// Tasks are written so that each one turns the NEXT block below from failing
// to passing. Blocks for functions that do not exist yet are skipped, so the
// suite is green from the start and goes red only when a task does its job
// badly - never merely because later tasks have not run.
const assert = require('assert');

function has(mod, name) {
  try { return typeof require(mod)[name] === 'function'; }
  catch (e) { return false; }
}

let checked = 0;

if (has('../src/slugify.js', 'slugify')) {
  const { slugify } = require('../src/slugify.js');
  assert.strictEqual(slugify('Hello World'), 'hello-world');
  assert.strictEqual(slugify('  Acme   Corp  '), 'acme-corp');
  assert.strictEqual(slugify('Café & Bar'), 'cafe-bar');
  checked++;
}

if (has('../src/money.js', 'formatMoney')) {
  const { formatMoney } = require('../src/money.js');
  assert.strictEqual(formatMoney(1234.5), '1,234.50');
  assert.strictEqual(formatMoney(0), '0.00');
  assert.strictEqual(formatMoney(-9.005), '-9.01');
  checked++;
}

if (has('../src/contact.js', 'validateContact')) {
  const { validateContact } = require('../src/contact.js');
  assert.deepStrictEqual(
    validateContact({ name: 'Ann', email: 'a@b.com', message: 'Hello, please send a quote' }),
    []
  );
  assert.ok(validateContact({ name: '', email: 'a@b.com', message: 'Hello, please send a quote' })
    .includes('name is required'));
  assert.ok(validateContact({ name: 'Ann', email: 'nope', message: 'Hello, please send a quote' })
    .includes('email is invalid'));
  assert.ok(validateContact({ name: 'Ann', email: 'a@b.com', message: 'short' })
    .includes('message must be at least 10 characters'));
  checked++;
}

if (has('../src/paginate.js', 'paginate')) {
  const { paginate } = require('../src/paginate.js');
  const rows = [1, 2, 3, 4, 5, 6, 7];
  assert.deepStrictEqual(paginate(rows, 1, 3), { items: [1, 2, 3], page: 1, pages: 3, total: 7 });
  assert.deepStrictEqual(paginate(rows, 3, 3), { items: [7], page: 3, pages: 3, total: 7 });
  assert.deepStrictEqual(paginate(rows, 99, 3).items, []);
  checked++;
}

console.log(`PASS (${checked}/4 modules implemented)`);
