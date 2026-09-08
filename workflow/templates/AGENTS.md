# AGENTS.md

<!--
  BUDGET: keep this file under ~150 lines / ~1500 tokens.
  It is re-sent on EVERY model call. At ~75 tok/s prefill, 1500 tokens costs
  ~20 s per call and a task takes 4-6 calls. A bloated AGENTS.md is the single
  easiest way to halve how many tasks finish overnight.

  WRITE FOR A 3B-ACTIVE MODEL. It does not infer and it does not generalise.
  Abstract principles ("write clean code", "follow SOLID") are ignored.
  Every rule must be short, imperative, and show right vs wrong.
-->

## Stack

<!-- Replace with your real versions. Be specific; the model has no other source. -->
- Laravel 12, PHP 8.2
- MySQL 8
- Tests: Pest
- Format: `./vendor/bin/pint`

## Commands

```bash
php artisan test              # run all tests
./vendor/bin/pint             # format before finishing
```

## Hard rules

1. Change only the files the task names. Never refactor unrelated code.
2. Never edit `.env`, `composer.lock`, `package-lock.json`, or anything in `vendor/`.
3. Never create a migration that drops or renames an existing column.
4. Every new endpoint gets a test in `tests/Feature/`.
5. Run `php artisan test` before you say the task is done.
6. If the task is unclear or needs a decision you cannot make, stop and say
   `BLOCKED: <reason>`. Do not guess.
7. Never make a test pass by returning a hardcoded value. Implement the real
   behaviour, or say `BLOCKED`.
8. Do not edit any file under `tests/` unless the task explicitly says to.

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
    return response()->json($service->create($request->validated()));
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

### Never satisfy a test with a constant

WRONG (this is real - the model did exactly this when the task was impossible):
```php
public function divide(float $a, float $b): float
{
    return 42.0;   // makes the assertion pass, implements nothing
}
```

RIGHT:
```php
public function divide(float $a, float $b): float
{
    if ($b == 0.0) {
        throw new InvalidArgumentException('Division by zero');
    }
    return $a / $b;
}
```

If the task cannot be implemented honestly, output `BLOCKED: <reason>` instead.

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

## Definition of done

A task is done only when ALL of these are true:
- The change works.
- `php artisan test` passes with no new failures.
- `./vendor/bin/pint` has been run.
- No file outside the task's scope was modified.
