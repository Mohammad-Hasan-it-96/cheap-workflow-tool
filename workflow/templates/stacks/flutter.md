# AGENTS.md

<!-- STACK: Flutter + Dart. Keep under ~150 lines. -->

## Stack

- Flutter 3.x, Dart 3.x
- State: Riverpod
- HTTP: dio
- Tests: `flutter test`

## Commands

```bash
flutter test          # run all tests
dart format lib test  # format before finishing
flutter analyze       # must be clean
```

## Hard rules

1. Change only the files the task names. Never refactor unrelated code.
2. Never edit `pubspec.lock` or anything in `.dart_tool/`.
3. Do not add a package to `pubspec.yaml` unless the task says to.
4. Do not edit any file under `test/` unless the task explicitly says to.
5. Run `flutter test` before you say the task is done.
6. If the task is unclear, stop and say `BLOCKED: <reason>`. Do not guess.
7. Never make a test pass by returning a hardcoded value.

## Code rules with examples

### One widget per file, const constructors

WRONG:
```dart
class ProductCard extends StatelessWidget {
  ProductCard(this.product);
  final Product product;
```

RIGHT:
```dart
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.product});
  final Product product;
```

### No business logic in build()

WRONG:
```dart
Widget build(BuildContext context) {
  final total = items.fold<double>(0, (s, i) => s + i.price * i.qty);
  return Text('$total');
}
```

RIGHT:
```dart
// in the model or a provider
double get total => items.fold(0, (s, i) => s + i.price * i.qty);

Widget build(BuildContext context) => Text('${cart.total}');
```

### Always handle the error and loading states of an async value

WRONG:
```dart
final data = ref.watch(productsProvider).value!;
```

RIGHT:
```dart
return ref.watch(productsProvider).when(
  data: (products) => ProductList(products: products),
  loading: () => const Center(child: CircularProgressIndicator()),
  error: (e, _) => Center(child: Text('$e')),
);
```

### Null safety: no `!` unless you just checked

WRONG:
```dart
Text(user!.name);
```

RIGHT:
```dart
if (user == null) return const SizedBox.shrink();
return Text(user.name);
```

## Definition of done

- `flutter test` passes with no new failures.
- `flutter analyze` reports no issues.
- `dart format lib test` has been run.
- No file outside the task's scope was modified.
