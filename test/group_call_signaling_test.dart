import 'package:chat_app/src/group_call_signaling.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_calls/realtime_calls.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('void group-call RPC treats a null result as success', () async {
    String? invokedFunction;
    Map<String, dynamic>? invokedParams;
    final gateway = SupabaseGroupCallGateway(
      client: SupabaseClient('https://example.supabase.co', 'test-key'),
      rpcInvoker: (function, params) async {
        invokedFunction = function;
        invokedParams = params;
        return null;
      },
    );

    await gateway.leave(callId: 'call-1');

    expect(invokedFunction, 'leave_group_call');
    expect(invokedParams, {'target_call_id': 'call-1'});
  });

  test('void group-call RPC converts PostgREST failures', () async {
    final gateway = SupabaseGroupCallGateway(
      client: SupabaseClient('https://example.supabase.co', 'test-key'),
      rpcInvoker: (_, _) => Future<dynamic>.error(
        const PostgrestException(
          message: 'That group call is no longer active',
          details: 'call ended',
        ),
      ),
    );

    await expectLater(
      gateway.leave(callId: 'call-1'),
      throwsA(
        isA<CallException>()
            .having(
              (error) => error.message,
              'message',
              'That group call is no longer active',
            )
            .having((error) => error.details, 'details', 'call ended'),
      ),
    );
  });
}
