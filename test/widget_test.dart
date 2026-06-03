import 'package:flutter_test/flutter_test.dart';
import 'package:afinador/main.dart';

void main() {
  testWidgets('App arranca', (WidgetTester tester) async {
    await tester.pumpWidget(const AfinadorApp());
    expect(find.text('Cromático'), findsOneWidget);
  });
}
