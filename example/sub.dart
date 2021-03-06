import 'package:dartros/dartros.dart';
import 'package:std_msgs/msgs.dart';
import 'package:dartx/dartx.dart';

Future<void> main(List<String> args) async {
  final node = await initNode('test_node', args, anonymize: true);
  final sub = node.subscribe<StringMessage>(
      '/chatter', StringMessage.$prototype, (message) {
    print('Got ${message.data}');
  });
  while (true) {
    await Future.delayed(2.seconds);
  }
}
