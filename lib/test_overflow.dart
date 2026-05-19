import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: TestApp()));

class TestApp extends StatelessWidget {
  const TestApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 100, // Constrained width like SfCalendar slot
          height: 50,
          color: Colors.red.shade100,
          child: RichText(
            softWrap: false,
            overflow: TextOverflow.visible,
            text: TextSpan(
              text: 'This is a very long text that should force the container to be wide',
              style: TextStyle(
                color: Colors.white,
                backgroundColor: Colors.blue.withOpacity(0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
