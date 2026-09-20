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

## Definition of done

- `npx vitest run` passes with no new failures.
- `npm run typecheck` is clean.
- No file outside the task's scope was modified.
