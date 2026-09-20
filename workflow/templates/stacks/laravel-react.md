# AGENTS.md

<!-- STACK: Laravel + React. Keep under ~150 lines: re-sent on EVERY call. -->

## Stack

- Laravel 12, PHP 8.2, MySQL 8
- React 18 + Vite in resources/js
- Tests: Pest (`php artisan test`)
- Format: `./vendor/bin/pint`

## Commands

```bash
php artisan test              # run all tests
./vendor/bin/pint             # format before finishing
npm run build                 # only if you changed resources/js
```

## Hard rules

1. Change only the files the task names. Never refactor unrelated code.
2. Never edit `.env`, `composer.lock`, `package-lock.json`, or `vendor/`.
3. Never create a migration that drops or renames an existing column.
4. Do not edit any file under `tests/` unless the task explicitly says to.
5. Run `php artisan test` before you say the task is done.
6. If the task is unclear, stop and say `BLOCKED: <reason>`. Do not guess.
7. Never make a test pass by returning a hardcoded value.

## Code rules with examples

### Controllers stay thin - logic goes in a service

WRONG:
```php
public function store(Request $request)
{
    $validated = $request->validate(['name' => 'required']);
    $product = Product::create($validated);
    Mail::to($request->user())->send(new ProductCreated($product));
    return response()->json($product);
}
```

RIGHT:
```php
public function store(StoreProductRequest $request, ProductService $service)
{
    return response()->json($service->create($request->validated()), 201);
}
```

### Always use a FormRequest, never inline validation

WRONG:
```php
$request->validate(['email' => 'required|email']);
```

RIGHT:
```php
// app/Http/Requests/StoreUserRequest.php
public function rules(): array
{
    return ['email' => ['required', 'email', 'max:255']];
}
```

### Never query inside a loop

WRONG:
```php
foreach ($orders as $order) {
    $order->customer = Customer::find($order->customer_id);
}
```

RIGHT:
```php
$orders = Order::with('customer')->get();
```

### Always type-hint returns

WRONG:
```php
public function total()
{
    return $this->items->sum('price');
}
```

RIGHT:
```php
public function total(): float
{
    return (float) $this->items->sum('price');
}
```

### React: one component per file, typed props

WRONG:
```jsx
export default function Row(props) {
  return <tr><td>{props.item.name}</td></tr>;
}
```

RIGHT:
```jsx
export default function ProductRow({ product }) {
  return <tr><td>{product.name}</td></tr>;
}
```

## Definition of done

- `php artisan test` passes with no new failures.
- `./vendor/bin/pint` has been run.
- No file outside the task's scope was modified.
