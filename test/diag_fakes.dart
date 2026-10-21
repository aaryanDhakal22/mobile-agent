import 'package:mobile_agent/core/device_platform.dart';
import 'package:mobile_agent/core/diag_models.dart';
import 'package:mobile_agent/core/discovery.dart';
import 'package:mobile_agent/core/models.dart';
import 'package:mobile_agent/features/diagnose/checks.dart';
import 'package:mobile_agent/features/diagnose/guides.dart';

const kSaved = 'http://192.168.1.219:8080';
final kNow = DateTime.utc(2026, 10, 20, 18);

const linkedSession = AgentProbe(state: 'ready', linkAvailable: true, sseState: 'connected', storeName: "Lombardi's");
const newSession = AgentProbe(state: 'unconfigured', linkAvailable: true);

const kitchen = DiagPrinter(id: 'p1', name: 'Kitchen', ip: '192.168.1.100', up: true);
const receipt = DiagPrinter(id: 'p2', name: 'Online', ip: '192.168.1.101', up: true, isReceipt: true);

DiagPrinter down(DiagPrinter p) => downAt(p, kNow);

DiagPrinter downAt(DiagPrinter p, DateTime at) =>
    DiagPrinter(id: p.id, name: p.name, ip: p.ip, up: false, isReceipt: p.isReceipt, downSince: at);

PiDiag diagOf({
  String mainState = 'connected',
  bool? reachable = true,
  List<DiagPrinter> printers = const [kitchen, receipt],
  PiHealth health = const PiHealth(),
  bool? openNow = true,
  DateTime? lastArrivedAt,
  int quiet = 90,
}) => PiDiag(
  version: '2.0.1',
  storeName: "Lombardi's",
  mainState: mainState,
  mainReachable: reachable,
  printers: printers,
  health: health,
  openNow: openNow,
  lastArrivedAt: lastArrivedAt ?? kNow.subtract(const Duration(minutes: 5)),
  quietAlertMinutes: quiet,
  fetchedAt: kNow,
);

/// A snapshot with everything healthy unless told otherwise.
CheckSnapshot snap({
  bool onNetwork = true,
  bool? internet = true,
  bool? mainFromTablet = true,
  PortState port = PortState.open,
  AgentProbe? session = linkedSession,
  bool piDown = false,
  PiDiag? diag,
  bool noDiag = false,
  PiDiag? lastDiag,
  List<DiscoveredPi> discovered = const [],
  DiscoveredPi? elsewhere,
  List<PrinterTestResult>? probe,
}) => CheckSnapshot(
  at: kNow,
  savedAddress: kSaved,
  device: DeviceChecks(wifi: onNetwork, ethernet: false, validated: internet == true, alarmVolume: 7, alarmMax: 7),
  internet: internet,
  mainFromTablet: mainFromTablet,
  piPort: piDown && port == PortState.open ? PortState.unreachable : port,
  session: piDown ? null : session,
  diag: piDown || noDiag ? null : (diag ?? diagOf()),
  lastDiag: lastDiag,
  discovered: discovered,
  piElsewhere: elsewhere,
  printerProbe: probe,
);

StepRecord rec(String id, String answer, [String result = '']) => StepRecord(id, answer, result: result, at: kNow);

/// Fake probes for runChecks / the guide controller; every field can change
/// between runs.
class FakeProbes implements DiagProbes {
  DeviceChecks? deviceChecks = const DeviceChecks(alarmVolume: 7, alarmMax: 7);
  bool? internetOk = true;
  bool? mainOk = true;
  PortState portState = PortState.open;
  AgentProbe? sessionAnswer = linkedSession;
  PiDiag? diagAnswer = diagOf();
  Object? diagError;
  List<DiscoveredPi> found = const [];
  Set<String> keyWorks = {};
  List<PrinterTestResult> printerResults = const [];
  int runs = 0;

  /// Delays every probe by this (to test the overall time limit).
  Duration delay = Duration.zero;

  Future<T> _d<T>(T v) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return v;
  }

  @override
  Future<DeviceChecks?> device() {
    runs++;
    return _d(deviceChecks);
  }

  @override
  Future<bool?> internet(DeviceChecks? device) => _d(internetOk);

  @override
  Future<bool?> mainHealth(String mainUrl) => _d(mainOk);

  @override
  Future<PortState> port(String address) => _d(portState);

  @override
  Future<AgentProbe?> session(String address) => _d(sessionAnswer);

  @override
  Future<PiDiag> diag() async {
    if (diagError != null) throw diagError!;
    if (diagAnswer == null) throw Exception('no answer');
    return _d(diagAnswer!);
  }

  @override
  Future<List<DiscoveredPi>> discover(String? savedAddress) => _d(found);

  @override
  Future<bool> keyWorksAt(String address) => _d(keyWorks.contains(address));

  @override
  Future<List<PrinterTestResult>> probePrinters() => _d(printerResults);
}
