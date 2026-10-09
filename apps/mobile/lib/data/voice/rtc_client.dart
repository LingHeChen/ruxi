import 'rtc_contract.dart';
import 'rtc_stub.dart'
    if (dart.library.js_interop) 'rtc_web.dart'
    if (dart.library.io) 'rtc_native.dart'
    as platform;
export 'rtc_contract.dart';

VolcRtcClient createRtcClient() => platform.createRtcClient();
