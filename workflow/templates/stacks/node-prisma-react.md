# AGENTS.md

<!-- STACK: Express + Prisma + React + TypeScript. Keep under ~150 lines. -->

## Stack

- Node 20, TypeScript, Express in apps/api
- Prisma ORM, PostgreSQL
- React 18 + Vite in apps/web
- Shared Zod schemas in packages/shared
- Tests: Vitest (`npx vitest run`)

## Commands

```bash
npx vitest run                    # run all tests ONCE (never bare `vitest`)
npm run typecheck                 # tsc --noEmit
npx prisma migrate dev --name <n> # after editing schema.prisma
```

## Hard rules

1. Change only the files the task names. Never refactor unrelated code.
2. Never edit `.env`, `package-lock.json`, or anything in `node_modules/`.
3. Never edit an existing migration. Create a new one.
4. Do not edit any file under `tests/` or `*.test.ts` unless told to.
5. Run `npx vitest run` before you say the task is done.
6. If the task is unclear, stop and say `BLOCKED: <reason>`. Do not guess.
7. Never make a test pass by returning a hardcoded value.

## Code rules with examples

### Validate with a shared Zod schema, never by hand

WRONG:
```ts
if (!req.body.email || !req.body.email.includes('@')) {
  return res.status(400).json({ error: 'bad email' });
}
```

RIGHT:
```ts
// packages/shared/src/user.ts
export const createUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(255),
});

// apps/api/src/routes/user.ts
const data = createUserSchema.parse(req.body);
```

### Controllers stay thin - logic goes in a service

WRONG:
```ts
router.post('/products', async (req, res) => {
  const p = await prisma.product.create({ data: req.body });
  await sendEmail(p);
  res.json(p);
});
```

RIGHT:
```ts
router.post('/products', async (req, res) => {
  const data = createProductSchema.parse(req.body);
  res.status(201).json(await productService.create(data));
});
```

### Never query inside a loop

WRONG:
```ts
for (const order of orders) {
  order.customer = await prisma.customer.findUnique({ where: { id: order.customerId } });
}
```

RIGHT:
```ts
const orders = await prisma.order.findMany({ include: { customer: true } });
```

### No `any`. Infer from the schema.

WRONG:
```ts
function create(data: any) { ... }
```

RIGHT:
```ts
type CreateUser = z.infer<typeof createUserSchema>;
function create(data: CreateUser) { ... }
```

### Never use a named import from a CommonJS package

jsonwebtoken and bcrypt are CommonJS. A named import compiles and passes the
test suite, then throws the moment the server starts. Vitest hides this because
Vite rewrites CJS; `npm run dev` does not.

WRONG:
```ts
import { sign, verify } from 'jsonwebtoken';   // SyntaxError at boot
```

RIGHT:
```ts
import jsonwebtoken from 'jsonwebtoken';
const { sign, verify } = jsonwebtoken;
```

### End a Prisma argument builder with `satisfies`

Without it `'desc'` widens to `string`, and Prisma rejects the whole object. The
unit test still passes, because it only compares values.

WRONG:
```ts
return { orderBy: [{ createdAt: 'desc' }], take: perPage };
```

RIGHT:
```ts
import { Prisma } from '@prisma/client';
return { orderBy: [{ createdAt: 'desc' }], take: perPage } satisfies Prisma.OfferFindManyArgs;
```

### Never add a dependency and never invent a version

The runner does not run `npm install`, so a new dependency is never installed,
and a guessed version number does not exist and breaks the whole install.
If a task seems to need a package that is not already in package.json, output
`BLOCKED: needs <package>` and change nothing.

### Let validation errors reach the error middleware

A controller parses with a schema and lets it throw. Catching it and returning
your own response turns a 422 that names the bad field into an opaque 500.

WRONG:
```ts
try { schema.parse(req.body) } catch { res.status(500).json({ error: 'bad' }) }
```

RIGHT:
```ts
const data = schema.parse(req.body);   // the error middleware turns this into 422
```

### A green suite does not mean the code runs

Before saying a task is done, ask whether what you wrote is reachable by the
thing that will call it. A helper nothing imports, or an object whose type the
real caller rejects, passes its own test and is still useless.

## Definition of done

- `npx vitest run` passes with no new failures.
- `npm run typecheck` is clean.
- No file outside the task's scope was modified.
