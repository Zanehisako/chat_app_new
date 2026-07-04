import 'package:chat_app/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders chat shell and sends local preview message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());

    expect(find.text('Design Studio'), findsOneWidget);
    expect(
      find.text('The new chat layout is in a good place.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'Hello Supabase');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Hello Supabase'), findsOneWidget);
  });
}
