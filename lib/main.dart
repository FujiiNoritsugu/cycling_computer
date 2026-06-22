import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cycling_analyzer/src/rust/api/simple.dart';
import 'package:cycling_analyzer/src/rust/frb_generated.dart';
import 'secrets.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

// ------------------------------------------------------------
// グローバル定数
// ------------------------------------------------------------
const String kTileStoreName = 'cyclingMapStore';
const String kTileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String kUserAgentPackage = 'com.fujii.cycling_computer';
const int kPrefetchMinZoom = 10;
const int kPrefetchMaxZoom = 16;
const double kPrefetchBufferMeters = 2000; // ルート沿い ±2km

// Google Maps Platform 共通 API キー
// Directions / Elevation 両方で使用。Cloud Console で各 API を有効化しておくこと。
// 実値は lib/secrets.dart（.gitignore 対象・リポジトリ非公開）に記載する。
// 詳細なセットアップ手順は lib/secrets.dart.example を参照。
const String kGoogleApiKey = googleApiKey;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // FMTC（オフラインタイルキャッシュ）の初期化
  await FMTCObjectBoxBackend().initialise();
  await const FMTCStore(kTileStoreName).manage.create();

  runApp(const CyclingComputerApp());
}

class CyclingComputerApp extends StatelessWidget {
  const CyclingComputerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'サイコン',
      theme: ThemeData.dark(),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class RecordedPoint {
  final LatLng position;
  final DateTime time;
  final double altitude;
  final double speedKmh;
  RecordedPoint(this.position, this.time, this.altitude, this.speedKmh);
}

// 音声ナビ用ステップ
class NavStep {
  final LatLng location;        // maneuver の位置
  final String instruction;     // 「左折」「右折」など正規化済み文言
  final String streetName;      // 次の道路名（あれば）
  bool announced500 = false;
  bool announced200 = false;
  bool announced50 = false;
  bool announcedAt = false;
  NavStep(this.location, this.instruction, this.streetName);
}

// 最近接点情報
class NearestOnRoute {
  final double distM;     // 最短距離 (m)
  final int segIdx;       // 線分インデックス
  final double t;         // 線分内補間 [0,1]
  final double cumKm;     // ルート始点からの累積距離 (km)
  NearestOnRoute(this.distM, this.segIdx, this.t, this.cumKm);
}

class RideSummary {
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final double elevationGainM;
  final DateTime startTime;
  final DateTime endTime;

  RideSummary({
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
    required this.elevationGainM,
    required this.startTime,
    required this.endTime,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  // GPS データ
  double _lat = 0.0;
  double _lng = 0.0;
  double _speed = 0.0;
  double _altitude = 0.0;
  bool _gpsValid = false;

  // 天気データ
  String _weatherDesc = '取得中...';
  double _temperature = 0.0;
  double _rainProb = 0.0;

  // ルートAIデータ
  String _aiAnalysis = '';
  double _totalDistance = 0.0;
  int _totalDuration = 0;
  double _totalElevation = 0.0;
  bool _isLoadingRoute = false;

  // マップ切替（true=オフライン/OSM、false=オンライン/Google）
  bool _useOfflineMap = false;

  // flutter_map（OSMタブ）
  final MapController _mapController = MapController();
  bool _mapReady = false;

  // google_maps_flutter（Googleタブ）
  gmaps.GoogleMapController? _googleMapController;
  // Google マップの現在ズーム（onCameraMove で随時更新）
  double _googleZoom = 13.0;
  // プログラム由来のカメラ移動を識別するためのフラグ（追従モード保持）
  bool _isSystemMoving = false;
  // 進行方向を上に固定するモード（ヘディングアップ）
  bool _headingUpMode = false;
  double _lastHeading = 0.0;

  // 共通
  LatLng? _destLatLng;
  bool _followMode = true;
  bool _isFullScreenMap = false;

  // ルートポリライン
  List<LatLng> _aiRoutePoints = [];
  List<LatLng> _gpxRoutePoints = [];
  bool _isGpxLoaded = false;

  // 標高プロファイル用（_aiRoutePoints と同じ長さで並走）
  List<double> _aiRouteElevations = [];
  List<double> _aiRouteCumDistKm = [];
  List<double> _gpxRouteElevations = [];
  List<double> _gpxRouteCumDistKm = [];

  // ルート上の現在地（標高プロファイルのピン用）
  double? _currentRouteCumKm;

  // ルート逸脱検知
  static const double kOffRouteThresholdM = 50;
  static const int kOffRouteSeconds = 15;
  int _offRouteSecAcc = 0;
  DateTime? _lastOffRouteCheck;
  bool _offRouteAlerted = false;
  bool _isReroutingPromptOpen = false;

  // 音声ターン案内
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;
  bool _voiceNavEnabled = true;
  List<NavStep> _navSteps = [];
  int _currentNavIdx = 0;

  // 走行ログ
  bool _isRecording = false;
  List<RecordedPoint> _recordedPoints = [];
  DateTime? _recordingStartTime;
  double _totalDistanceKm = 0.0;
  LatLng? _lastRecordedPoint;
  RideSummary? _lastRideSummary;
  List<FileSystemEntity> _logFiles = [];

  // 目的地
  final _destController = TextEditingController();

  static const String _baseUrl =
      'https://cycling-backend-1010478563120.asia-northeast1.run.app';

  StreamSubscription<Position>? _positionSub;
  Timer? _weatherTimer;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyWakelockForCurrentTab();
    _initGps();
    _initTts();
    _startWeatherTimer();
    _loadLogFiles();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('ja-JP');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ttsReady = true;
    } catch (e) {
      debugPrint('TTS init エラー: $e');
    }
  }

  Future<void> _speak(String text) async {
    if (!_ttsReady || !_voiceNavEnabled) return;
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS speak エラー: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _positionSub?.cancel();
    _weatherTimer?.cancel();
    _destController.dispose();
    _mapController.dispose();
    _googleMapController?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンドでは画面を点けっぱなしにする必要は無いので解除
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      WakelockPlus.disable();
    } else if (state == AppLifecycleState.resumed) {
      _applyWakelockForCurrentTab();
    }
  }

  // タブごとに画面常時 ON を切替（ログ画面では不要）
  void _applyWakelockForCurrentTab() {
    if (_currentIndex == 0 || _currentIndex == 1) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  Future<void> _initGps() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    // UI 即時反映のため一度だけ getCurrentPosition で初期取得
    try {
      final initial = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _handlePosition(initial);
    } catch (e) {
      debugPrint('GPS 初期取得エラー: $e');
    }

    // 以降はストリーム購読: 5m 動いたら更新（停車中は更新が来ず省電力）
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      _handlePosition,
      onError: (e) => debugPrint('GPS ストリームエラー: $e'),
    );

    await _updateWeather();
  }

  // ストリーム/初期取得共通: 1 件の Position を処理
  void _handlePosition(Position pos) {
    if (!mounted) return;
    setState(() {
      _lat = pos.latitude;
      _lng = pos.longitude;
      _speed = pos.speed * 3.6;
      _altitude = pos.altitude;
      _gpsValid = true;
    });
    _onPositionUpdated(pos);
  }

  // setState 後の派生処理（記録への追加、heading 更新、カメラ追従）
  void _onPositionUpdated(Position pos) {
    try {
      // 進行方向（heading）の更新: 1m/s 以上で移動中のみ採用（停止時の暴れ抑制）
      if (pos.heading >= 0 && pos.speed > 1.0) {
        _lastHeading = pos.heading;
      }

      // 記録中の場合はポイントを追加
      if (_isRecording && _gpsValid) {
        final current = LatLng(_lat, _lng);
        if (_lastRecordedPoint != null) {
          _totalDistanceKm += _calcDistance(_lastRecordedPoint!, current);
        }
        _recordedPoints.add(RecordedPoint(
          current,
          DateTime.now(),
          _altitude,
          _speed,
        ));
        _lastRecordedPoint = current;
      }

      // ルート追従処理（標高ピン更新 + 逸脱検知）
      _updateRouteFollowing();
      // 音声ターン案内
      _maybeSpeakNavigation();

      // 追従モードがONの場合はカメラを現在地に移動（必要ならヘディングアップ回転も）
      if (_followMode) {
        if (_useOfflineMap && _mapReady) {
          if (_headingUpMode) {
            // flutter_map の rotate は「カメラのコンパスベアリング（時計回り、北=0）」を取る。
            // GPS の heading と同じ向きなので、そのまま渡せばヘディングアップになる。
            _mapController.moveAndRotate(
              LatLng(_lat, _lng),
              _mapController.camera.zoom,
              _lastHeading,
            );
          } else {
            _mapController.move(
                LatLng(_lat, _lng), _mapController.camera.zoom);
          }
        } else if (!_useOfflineMap && _googleMapController != null) {
          _isSystemMoving = true;
          if (_headingUpMode) {
            _googleMapController!.animateCamera(
              gmaps.CameraUpdate.newCameraPosition(
                gmaps.CameraPosition(
                  target: gmaps.LatLng(_lat, _lng),
                  zoom: _googleZoom,
                  bearing: _lastHeading,
                ),
              ),
            );
          } else {
            _googleMapController!.animateCamera(
              gmaps.CameraUpdate.newLatLng(gmaps.LatLng(_lat, _lng)),
            );
          }
          Future.delayed(const Duration(milliseconds: 600), () {
            _isSystemMoving = false;
          });
        }
      }
    } catch (e) {
      debugPrint('GPS エラー: $e');
    }
  }

  Future<void> _updateWeather() async {
    if (!_gpsValid) return;
    try {
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final res = await http
          .get(
            Uri.parse('$_baseUrl/api/weather?lat=$_lat&lng=$_lng&date=$date'),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body)['data'];
        setState(() {
          _weatherDesc = data['description'] ?? '';
          _temperature = (data['temperature'] ?? 0).toDouble();
          _rainProb = (data['precipitation_probability'] ?? 0).toDouble();
        });
      }
    } catch (e) {
      debugPrint('天気エラー: $e');
    }
  }

  Future<void> _getRoutePlan() async {
    if (!_gpsValid) {
      debugPrint('GPS無効のため中止');
      return;
    }
    if (_destController.text.isEmpty) {
      debugPrint('目的地未入力のため中止');
      return;
    }

    setState(() => _isLoadingRoute = true);
    debugPrint('ルート検索開始: ${_destController.text}');

    try {
      double destLat;
      double destLng;

      // 「緯度,経度」形式かチェック
      final coordRegex = RegExp(r'^-?\d+\.?\d*,\s*-?\d+\.?\d*$');
      if (coordRegex.hasMatch(_destController.text.trim())) {
        final parts = _destController.text.trim().split(RegExp(r',\s*'));
        destLat = double.parse(parts[0]);
        destLng = double.parse(parts[1]);
        debugPrint('座標直接入力: ($destLat, $destLng)');
      } else {
        // ジオコード
        final geoUrl =
            '$_baseUrl/api/geocode?query=${Uri.encodeComponent(_destController.text)}&country=JP';
        final geoRes = await http
            .get(Uri.parse(geoUrl))
            .timeout(const Duration(seconds: 10));

        if (geoRes.statusCode != 200) {
          setState(() => _isLoadingRoute = false);
          return;
        }

        final geoData = jsonDecode(geoRes.body);
        List candidates = geoData['data'] ?? [geoData];
        if (candidates.isEmpty) {
          setState(() => _isLoadingRoute = false);
          return;
        }

        Map nearest = candidates[0];
        double minDist = double.infinity;
        for (final c in candidates) {
          final dist = (c['lat'] - _lat).abs() + (c['lng'] - _lng).abs();
          if (dist < minDist) {
            minDist = dist;
            nearest = c;
          }
        }

        destLat = (nearest['lat'] as num).toDouble();
        destLng = (nearest['lng'] as num).toDouble();
        debugPrint('選択した目的地: ${nearest['name']} ($destLat, $destLng)');
      }

      // 目的地マーカーを設定
      setState(() {
        _destLatLng = LatLng(destLat, destLng);
      });

      // ルートプラン
      debugPrint('ルートプランAPI呼び出し開始');
      final planRes = await http
          .post(
            Uri.parse('$_baseUrl/api/plan'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'origin': {'lat': _lat, 'lng': _lng, 'name': '現在地'},
              'destination': {
                'lat': destLat,
                'lng': destLng,
                'name': _destController.text,
              },
              'preferences': {
                'difficulty': 'moderate',
                'avoid_traffic': true,
                'prefer_scenic': true,
              },
              'departure_time': DateTime.now().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 120));

      debugPrint('ルートプランStatus: ${planRes.statusCode}');

      if (planRes.statusCode == 200) {
        String analysis = '';
        double distance = 0.0;
        int duration = 0;
        double elevation = 0.0;

        for (final line in planRes.body.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          try {
            final event = jsonDecode(line.substring(6));
            final type = event['type'];
            final data = event['data'];
            if (type == 'route_data') {
              distance = (data['total_distance_km'] ?? 0).toDouble();
              duration = (data['total_duration_min'] ?? 0).toInt();
              elevation = (data['total_elevation_gain_m'] ?? 0).toDouble();
            } else if (type == 'token') {
              analysis += data.toString();
            }
          } catch (_) {}
        }

        if (_useOfflineMap) {
          await _getDirectionsRoute(destLat, destLng);
        } else {
          await _getGoogleDirectionsRoute(destLat, destLng);
        }

        // マップを現在地と目的地が収まるようにズーム
        _fitMapToBounds(LatLng(_lat, _lng), LatLng(destLat, destLng));

        setState(() {
          _aiAnalysis = analysis;
          _totalDistance = distance;
          _totalDuration = duration;
          _totalElevation = elevation;
          _isLoadingRoute = false;
        });
        debugPrint('ルート取得完了: ${distance}km');
      }
    } catch (e) {
      debugPrint('ルートエラー: $e');
      setState(() => _isLoadingRoute = false);
    }
  }

  // OSRM 公開デモサーバを使った道路ルート取得（オフラインタブ用）
  Future<void> _getDirectionsRoute(double destLat, double destLng) async {
    final url = 'https://router.project-osrm.org/route/v1/cycling/'
        '$_lng,$_lat;$destLng,$destLat'
        '?overview=full&geometries=polyline&steps=true';

    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['code'] == 'Ok' && (data['routes'] as List).isNotEmpty) {
          final encoded = data['routes'][0]['geometry'] as String;
          final routePoints = _decodePolyline(encoded);
          setState(() {
            _aiRoutePoints = routePoints;
            _aiRouteCumDistKm = _buildCumDistKm(routePoints);
            _aiRouteElevations = [];
            _resetNavigation();
          });
          _fitMapToPoints(routePoints);
          // 標高取得（非同期、失敗してもルート表示は維持）
          _fetchElevationsForAiRoute();
          // ターン案内のステップを取得
          _navSteps = _parseOsrmSteps(data);
          _currentNavIdx = 0;
          if (_navSteps.isNotEmpty) {
            _speak('ナビゲーションを開始します');
          }
          debugPrint('OSRMルート取得成功: ${routePoints.length}ポイント, '
              'ステップ${_navSteps.length}');
        } else {
          debugPrint('OSRMエラー: ${data['code']}');
        }
      }
    } catch (e) {
      debugPrint('Directionsエラー: $e');
    }
  }

  // Google Directions API を使った道路ルート取得（オンラインタブ用）
  Future<void> _getGoogleDirectionsRoute(
      double destLat, double destLng) async {
    final url = 'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$_lat,$_lng'
        '&destination=$destLat,$destLng'
        '&mode=bicycling'
        '&language=ja'
        '&key=$kGoogleApiKey';

    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK') {
          final encoded =
              data['routes'][0]['overview_polyline']['points'] as String;
          final routePoints = _decodePolyline(encoded);
          setState(() {
            _aiRoutePoints = routePoints;
            _aiRouteCumDistKm = _buildCumDistKm(routePoints);
            _aiRouteElevations = [];
            _resetNavigation();
          });
          _fitMapToPoints(routePoints);
          // 標高取得（非同期）
          _fetchElevationsForAiRoute();
          // Google のステップをパース
          _navSteps = _parseGoogleSteps(data);
          _currentNavIdx = 0;
          if (_navSteps.isNotEmpty) {
            _speak('ナビゲーションを開始します');
          }
          debugPrint('Google Directionsルート取得成功: ${routePoints.length}ポイント, '
              'ステップ${_navSteps.length}');
        } else {
          debugPrint('Google Directions APIエラー: ${data['status']}');
        }
      }
    } catch (e) {
      debugPrint('Google Directionsエラー: $e');
    }
  }

  // 両マップ共通: 2点が収まるようカメラを合わせる
  void _fitMapToBounds(LatLng a, LatLng b) {
    final swLat = a.latitude < b.latitude ? a.latitude : b.latitude;
    final neLat = a.latitude > b.latitude ? a.latitude : b.latitude;
    final swLng = a.longitude < b.longitude ? a.longitude : b.longitude;
    final neLng = a.longitude > b.longitude ? a.longitude : b.longitude;

    if (_useOfflineMap && _mapReady) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(LatLng(swLat, swLng), LatLng(neLat, neLng)),
          padding: const EdgeInsets.all(60),
        ),
      );
    } else if (!_useOfflineMap && _googleMapController != null) {
      _isSystemMoving = true;
      _googleMapController!.animateCamera(
        gmaps.CameraUpdate.newLatLngBounds(
          gmaps.LatLngBounds(
            southwest: gmaps.LatLng(swLat, swLng),
            northeast: gmaps.LatLng(neLat, neLng),
          ),
          60,
        ),
      );
      Future.delayed(const Duration(milliseconds: 800), () {
        _isSystemMoving = false;
      });
    }
  }

  // 両マップ共通: ポリライン全体が収まるようカメラを合わせる
  void _fitMapToPoints(List<LatLng> points) {
    if (points.isEmpty) return;
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _fitMapToBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  // ヘディングアップ切替
  void _toggleHeadingUp() {
    setState(() {
      _headingUpMode = !_headingUpMode;
      // ON にしたら追従も自動で ON（向きを上に保つには追従が前提）
      if (_headingUpMode) _followMode = true;
    });

    if (!_headingUpMode) {
      // OFF にしたら回転を 0 に戻す
      if (_useOfflineMap && _mapReady) {
        _mapController.rotate(0);
      } else if (!_useOfflineMap && _googleMapController != null) {
        _isSystemMoving = true;
        _googleMapController!.animateCamera(
          gmaps.CameraUpdate.newCameraPosition(
            gmaps.CameraPosition(
              target: gmaps.LatLng(_lat, _lng),
              zoom: _googleZoom,
              bearing: 0.0,
            ),
          ),
        );
        Future.delayed(const Duration(milliseconds: 600), () {
          _isSystemMoving = false;
        });
      }
    }
  }

  // Polylineエンコード文字列をLatLngリストに変換
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1F) << shift;
        shift += 5;
      } while (byte >= 0x20);
      int dLat = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lat += dLat;

      shift = 0;
      result = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1F) << shift;
        shift += 5;
      } while (byte >= 0x20);
      int dLng = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lng += dLng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  double _calcDistance(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * 3.14159 / 180;
    final dLng = (b.longitude - a.longitude) * 3.14159 / 180;
    final x = dLat * dLat +
        dLng *
            dLng *
            (cos(a.latitude * 3.14159 / 180) *
                cos(b.latitude * 3.14159 / 180));
    return R * sqrt(x);
  }

  // ----------------------------------------------------------
  // 共通ジオメトリヘルパー
  // ----------------------------------------------------------

  /// 緯度経度を簡易メートル射影し、点 p からセグメント a-b への
  /// 最短距離 (m) と、セグメント上の補間係数 t [0..1] を返す。
  ({double dist, double t}) _pointToSegmentMeters(
      LatLng p, LatLng a, LatLng b) {
    const mLat = 111320.0;
    final mLng = 111320.0 * cos(p.latitude * pi / 180);
    final ax = a.longitude * mLng, ay = a.latitude * mLat;
    final bx = b.longitude * mLng, by = b.latitude * mLat;
    final px = p.longitude * mLng, py = p.latitude * mLat;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    double t = lenSq == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lenSq;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    final dist =
        sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
    return (dist: dist, t: t);
  }

  /// ルート全体に対する最近接点情報。標高プロファイルのピン位置や
  /// 逸脱判定の両方で使う共通基盤。route には対応する累積距離テーブル cum が必要。
  NearestOnRoute? _nearestOnRoute(
      LatLng p, List<LatLng> route, List<double> cumKm) {
    if (route.length < 2) return null;
    double minD = double.infinity;
    int minI = 0;
    double minT = 0;
    for (int i = 0; i < route.length - 1; i++) {
      final r = _pointToSegmentMeters(p, route[i], route[i + 1]);
      if (r.dist < minD) {
        minD = r.dist;
        minI = i;
        minT = r.t;
      }
    }
    // 累積距離: 線分始点 + 補間距離
    double cum = 0;
    if (cumKm.length == route.length) {
      final segKm = (cumKm[minI + 1] - cumKm[minI]);
      cum = cumKm[minI] + segKm * minT;
    }
    return NearestOnRoute(minD, minI, minT, cum);
  }

  /// 各ポイントの累積距離 (km) を計算
  List<double> _buildCumDistKm(List<LatLng> route) {
    final cum = List<double>.filled(route.length, 0.0);
    for (int i = 1; i < route.length; i++) {
      cum[i] = cum[i - 1] + _calcDistance(route[i - 1], route[i]);
    }
    return cum;
  }

  // ----------------------------------------------------------
  // 標高プロファイル
  // ----------------------------------------------------------

  /// AIルート向けに Google Elevation API で標高を取得し、線形補間で全点に展開。
  /// Google は 1 リクエスト最大 512 点までなので 100 点に間引いて GET で問い合わせる。
  /// （Cloud Console で「Elevation API」を有効化しておくこと）
  Future<void> _fetchElevationsForAiRoute() async {
    if (_aiRoutePoints.length < 2) return;

    final n = _aiRoutePoints.length;
    final step = (n / 100).ceil().clamp(1, n);
    final sampledIdx = <int>[];
    final sampled = <LatLng>[];
    for (int i = 0; i < n; i += step) {
      sampledIdx.add(i);
      sampled.add(_aiRoutePoints[i]);
    }
    if (sampledIdx.last != n - 1) {
      sampledIdx.add(n - 1);
      sampled.add(_aiRoutePoints.last);
    }

    // Google Elevation API: locations=lat,lng|lat,lng|... 形式
    final locParam = sampled
        .map((p) =>
            '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}')
        .join('|');
    final url = 'https://maps.googleapis.com/maps/api/elevation/json'
        '?locations=$locParam'
        '&key=$kGoogleApiKey';

    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        debugPrint('Elevation API HTTP 失敗: ${res.statusCode}');
        return;
      }
      final body = jsonDecode(res.body);
      final status = body['status'] as String?;
      if (status != 'OK') {
        debugPrint('Elevation API ステータス異常: $status / '
            '${body['error_message'] ?? ''}');
        return;
      }

      final results = (body['results'] as List)
          .map((r) => (r['elevation'] as num).toDouble())
          .toList();

      if (results.length != sampledIdx.length) {
        debugPrint('Elevation 件数不一致: ${results.length} vs '
            '${sampledIdx.length}');
        return;
      }

      // 線形補間で全点に展開
      final elev = List<double>.filled(n, 0.0);
      for (int i = 0; i < sampledIdx.length - 1; i++) {
        final i0 = sampledIdx[i], i1 = sampledIdx[i + 1];
        final e0 = results[i], e1 = results[i + 1];
        for (int k = i0; k <= i1; k++) {
          final t = (i1 == i0) ? 0.0 : (k - i0) / (i1 - i0);
          elev[k] = e0 + (e1 - e0) * t;
        }
      }

      if (!mounted) return;
      setState(() {
        _aiRouteElevations = elev;
        _aiRouteCumDistKm = _buildCumDistKm(_aiRoutePoints);
      });
      debugPrint('標高取得完了 (Google): ${elev.length}点');
    } catch (e) {
      debugPrint('標高取得エラー: $e');
    }
  }

  /// アクティブなルート（AI優先、なければGPX）の elevations / cumKm を返す
  ({List<double> elev, List<double> cumKm, List<LatLng> pts})?
      _activeRouteWithElev() {
    if (_aiRoutePoints.isNotEmpty &&
        _aiRouteElevations.length == _aiRoutePoints.length) {
      return (
        elev: _aiRouteElevations,
        cumKm: _aiRouteCumDistKm,
        pts: _aiRoutePoints
      );
    }
    if (_gpxRoutePoints.isNotEmpty &&
        _gpxRouteElevations.length == _gpxRoutePoints.length) {
      return (
        elev: _gpxRouteElevations,
        cumKm: _gpxRouteCumDistKm,
        pts: _gpxRoutePoints
      );
    }
    return null;
  }

  // ----------------------------------------------------------
  // ルート逸脱検知 + 音声ターン案内
  // ----------------------------------------------------------

  /// 現在地のルート上スナップ位置を更新し、逸脱検知も同時に行う。
  /// 標高プロファイルのピンと逸脱判定で同じ最近接点を共有する。
  void _updateRouteFollowing() {
    final route =
        _aiRoutePoints.isNotEmpty ? _aiRoutePoints : _gpxRoutePoints;
    final cum = _aiRoutePoints.isNotEmpty
        ? _aiRouteCumDistKm
        : _gpxRouteCumDistKm;
    if (route.length < 2 || !_gpsValid) {
      if (_currentRouteCumKm != null) {
        setState(() => _currentRouteCumKm = null);
      }
      return;
    }

    final near = _nearestOnRoute(LatLng(_lat, _lng), route, cum);
    if (near == null) return;

    // 標高プロファイルのピン位置を更新（毎回 setState すると重いので差分で）
    if (_currentRouteCumKm == null ||
        (_currentRouteCumKm! - near.cumKm).abs() > 0.005) {
      setState(() => _currentRouteCumKm = near.cumKm);
    }

    // 逸脱判定は AI ルート（目的地が設定されている）時だけ
    if (_aiRoutePoints.isNotEmpty && _destLatLng != null) {
      _evaluateOffRoute(near.distM);
    } else {
      _offRouteSecAcc = 0;
      _offRouteAlerted = false;
      _lastOffRouteCheck = null;
    }
  }

  void _evaluateOffRoute(double distM) {
    final now = DateTime.now();
    if (distM > kOffRouteThresholdM) {
      if (_lastOffRouteCheck != null) {
        _offRouteSecAcc += now.difference(_lastOffRouteCheck!).inSeconds;
      }
      if (_offRouteSecAcc >= kOffRouteSeconds && !_offRouteAlerted) {
        _offRouteAlerted = true;
        HapticFeedback.heavyImpact();
        _speak('ルートから外れています');
        _showRerouteDialog();
      }
    } else {
      _offRouteSecAcc = 0;
      _offRouteAlerted = false;
    }
    _lastOffRouteCheck = now;
  }

  Future<void> _showRerouteDialog() async {
    if (_isReroutingPromptOpen || !mounted) return;
    _isReroutingPromptOpen = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('ルート逸脱',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'ルートから50m以上離れています。\n現在地から再検索しますか？',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('そのまま',
                style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('再検索',
                style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
    _isReroutingPromptOpen = false;
    if (ok == true) {
      _getRoutePlan();
    }
  }

  // ----------------------------------------------------------
  // OSRM / Google レスポンスからナビゲーションステップを抽出
  // ----------------------------------------------------------

  List<NavStep> _parseOsrmSteps(Map data) {
    final steps = <NavStep>[];
    try {
      final routes = data['routes'] as List;
      if (routes.isEmpty) return steps;
      final legs = routes[0]['legs'] as List;
      for (final leg in legs) {
        for (final s in (leg['steps'] as List)) {
          final m = s['maneuver'] as Map;
          final loc = m['location'] as List;
          final point = LatLng(
              (loc[1] as num).toDouble(), (loc[0] as num).toDouble());
          final type = (m['type'] ?? '') as String;
          final modifier = (m['modifier'] ?? '') as String;
          final name = (s['name'] ?? '') as String;
          final phrase = _humanizeManeuver(type, modifier);
          if (phrase.isEmpty) continue;
          steps.add(NavStep(point, phrase, name));
        }
      }
    } catch (e) {
      debugPrint('OSRMステップ解析エラー: $e');
    }
    return steps;
  }

  List<NavStep> _parseGoogleSteps(Map data) {
    final steps = <NavStep>[];
    try {
      final routes = data['routes'] as List;
      if (routes.isEmpty) return steps;
      final legs = routes[0]['legs'] as List;
      for (final leg in legs) {
        for (final s in (leg['steps'] as List)) {
          final start = s['start_location'] as Map;
          final point = LatLng(
              (start['lat'] as num).toDouble(),
              (start['lng'] as num).toDouble());
          // html_instructions から HTML タグを除去
          final html = (s['html_instructions'] ?? '') as String;
          final plain = html
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (plain.isEmpty) continue;
          steps.add(NavStep(point, plain, ''));
        }
      }
    } catch (e) {
      debugPrint('Googleステップ解析エラー: $e');
    }
    return steps;
  }

  String _humanizeManeuver(String type, String mod) {
    if (type == 'depart') return '出発';
    if (type == 'arrive') return '目的地に到着しました';
    switch (mod) {
      case 'left':
        return '左折';
      case 'right':
        return '右折';
      case 'slight left':
        return '左方向';
      case 'slight right':
        return '右方向';
      case 'sharp left':
        return '鋭く左折';
      case 'sharp right':
        return '鋭く右折';
      case 'straight':
        return '直進';
      case 'uturn':
        return 'Uターン';
      default:
        // 'turn' でも modifier が無い場合などは一旦読み上げ対象から外す
        if (type == 'continue' || type == 'merge' ||
            type == 'roundabout' || type == 'rotary') {
          return type == 'roundabout' || type == 'rotary'
              ? 'ロータリー'
              : '直進';
        }
        return '';
    }
  }

  void _resetNavigation() {
    _navSteps = [];
    _currentNavIdx = 0;
    _offRouteSecAcc = 0;
    _offRouteAlerted = false;
    _lastOffRouteCheck = null;
    _currentRouteCumKm = null;
  }

  /// 現在地に応じて未通知の最も近いステップを音声でアナウンス。
  /// 500m / 200m / 50m / 通過時 の4段階。
  void _maybeSpeakNavigation() {
    if (_navSteps.isEmpty || !_gpsValid || !_voiceNavEnabled) return;
    final cur = LatLng(_lat, _lng);

    for (int i = _currentNavIdx; i < _navSteps.length; i++) {
      final step = _navSteps[i];
      final d = _calcDistance(cur, step.location) * 1000; // m

      final phrase = step.streetName.isNotEmpty
          ? '${step.instruction}、${step.streetName}'
          : step.instruction;

      if (d < 25 && !step.announcedAt) {
        step.announcedAt = true;
        _speak(phrase);
        _currentNavIdx = i + 1;
        return;
      } else if (d < 60 && !step.announced50) {
        step.announced50 = true;
        _speak('まもなく$phrase');
        return;
      } else if (d < 220 && !step.announced200) {
        step.announced200 = true;
        _speak('200メートル先、$phrase');
        return;
      } else if (d < 520 && !step.announced500) {
        step.announced500 = true;
        _speak('500メートル先、$phrase');
        return;
      }
      // このステップが遠すぎる場合は後続も同様に遠いはずなので打ち切り
      if (d > 1000) break;
    }
  }

  Future<void> _saveRecordingAsGpx() async {
    if (_recordedPoints.isEmpty) return;

    final now = DateTime.now();
    final fileName =
        'ride_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.gpx';

    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<gpx version="1.1" creator="SaikonApp">');
    buffer.writeln('<trk><name>$fileName</name><trkseg>');
    for (final pt in _recordedPoints) {
      final timeStr = pt.time.toUtc().toIso8601String();
      buffer.writeln('<trkpt lat="${pt.position.latitude}" lon="${pt.position.longitude}">'
          '<ele>${pt.altitude.toStringAsFixed(1)}</ele>'
          '<time>$timeStr</time>'
          '<extensions>'
          '<speed>${(pt.speedKmh / 3.6).toStringAsFixed(2)}</speed>'
          '</extensions>'
          '</trkpt>');
    }
    buffer.writeln('</trkseg></trk></gpx>');

    final dir = await getExternalStorageDirectory();
    final file = File('${dir!.path}/$fileName');
    await file.writeAsString(buffer.toString());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存しました: $fileName'),
          backgroundColor: Colors.green,
        ),
      );
    }

    // 先にライドサマリーダイアログを表示
    await _showRideSummaryDialog();

    await _showRustAnalysisDialog(file);
  }

  Future<void> _showRustAnalysisDialog(File file) async {
    try {
      final gpxContent = await file.readAsBytes();
      final rustSummary = await parseGpxAndSummarize(
        gpxBytes: gpxContent.toList(),
      );
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            '🔍 詳細解析（Rust）',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _summaryRow(
                  Icons.straighten,
                  '総距離',
                  '${rustSummary.totalDistanceKm.toStringAsFixed(2)} km',
                  Colors.green),
              _summaryRow(
                  Icons.timer,
                  '総時間',
                  '${(rustSummary.durationSeconds / 60).toStringAsFixed(0)} 分',
                  Colors.orange),
              _summaryRow(
                  Icons.directions_run,
                  '移動時間',
                  '${(rustSummary.movingTimeSec.toInt() / 60).toStringAsFixed(0)} 分',
                  Colors.cyan),
              _summaryRow(
                  Icons.pause,
                  '停止時間',
                  '${(rustSummary.stoppedTimeSec.toInt() / 60).toStringAsFixed(0)} 分',
                  Colors.grey),
              _summaryRow(
                  Icons.speed,
                  '平均速度（移動中）',
                  '${rustSummary.avgMovingSpeedKmh.toStringAsFixed(1)} km/h',
                  Colors.yellow),
              _summaryRow(
                  Icons.flash_on,
                  '最高速度',
                  '${rustSummary.maxSpeedKmh.toStringAsFixed(1)} km/h',
                  Colors.red),
              _summaryRow(
                  Icons.trending_up,
                  '獲得標高',
                  '${rustSummary.elevationGainM.toStringAsFixed(0)} m',
                  Colors.orange),
              _summaryRow(
                  Icons.trending_down,
                  '損失標高',
                  '${rustSummary.elevationLossM.toStringAsFixed(0)} m',
                  Colors.blue),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('閉じる', style: TextStyle(color: Colors.green)),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Rust解析エラー: $e');
    }
  }

  Future<void> _loadLogFiles() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) return;
    final files = dir.listSync().where((f) => f.path.endsWith('.gpx')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() => _logFiles = files);
  }

  void _toggleRecording() {
    if (_isRecording) {
      _isRecording = false;
      final endTime = DateTime.now();

      // 統計計算
      double maxSpeed = 0.0;
      double elevationGain = 0.0;
      double? prevAlt;

      for (final pt in _recordedPoints) {
        if (pt.speedKmh > maxSpeed) maxSpeed = pt.speedKmh;
        if (prevAlt != null && pt.altitude > prevAlt) {
          elevationGain += pt.altitude - prevAlt;
        }
        prevAlt = pt.altitude;
      }

      final duration = endTime.difference(_recordingStartTime!);
      final avgSpeed = duration.inSeconds > 0
          ? _totalDistanceKm / (duration.inSeconds / 3600)
          : 0.0;

      setState(() {
        _lastRideSummary = RideSummary(
          distanceKm: _totalDistanceKm,
          duration: duration,
          avgSpeedKmh: avgSpeed,
          maxSpeedKmh: maxSpeed,
          elevationGainM: elevationGain,
          startTime: _recordingStartTime!,
          endTime: endTime,
        );
      });

      _saveRecordingAsGpx();
    } else {
      setState(() {
        // 記録開始
        _isRecording = true;
        _recordedPoints = [];
        _recordingStartTime = DateTime.now();
        _totalDistanceKm = 0.0;
        _lastRecordedPoint = null;
      });
    }
  }

  Future<void> _showRideSummaryDialog() async {
    if (_lastRideSummary == null || !mounted) return;
    final s = _lastRideSummary!;
    final h = s.duration.inHours;
    final m = s.duration.inMinutes % 60;
    final sec = s.duration.inSeconds % 60;
    final timeStr = '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}';

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          '🚴 ライドサマリー',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _summaryRow(Icons.straighten, '総距離',
                '${s.distanceKm.toStringAsFixed(2)} km', Colors.green),
            _summaryRow(Icons.timer, '走行時間', timeStr, Colors.orange),
            _summaryRow(Icons.speed, '平均速度',
                '${s.avgSpeedKmh.toStringAsFixed(1)} km/h', Colors.cyan),
            _summaryRow(Icons.flash_on, '最高速度',
                '${s.maxSpeedKmh.toStringAsFixed(1)} km/h', Colors.yellow),
            _summaryRow(Icons.trending_up, '獲得標高',
                '${s.elevationGainM.toStringAsFixed(0)} m', Colors.red),
            const SizedBox(height: 8),
            Text(
              '開始: ${DateFormat('HH:mm').format(s.startTime)}  '
              '終了: ${DateFormat('HH:mm').format(s.endTime)}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('閉じる', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _loadGpxFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
    );
    if (result == null) return;

    final file = File(result.files.single.path!);
    final contents = await file.readAsString();
    final document = XmlDocument.parse(contents);

    final points = <LatLng>[];
    final elevations = <double>[];
    final trkpts = document.findAllElements('trkpt');
    for (final pt in trkpts) {
      final lat = double.tryParse(pt.getAttribute('lat') ?? '');
      final lng = double.tryParse(pt.getAttribute('lon') ?? '');
      if (lat != null && lng != null) {
        points.add(LatLng(lat, lng));
        // <ele> タグが直下にある想定
        final eleEl = pt.findElements('ele').firstOrNull;
        final ele = double.tryParse(eleEl?.innerText ?? '') ?? 0.0;
        elevations.add(ele);
      }
    }

    // rteptも対応
    if (points.isEmpty) {
      final rtepts = document.findAllElements('rtept');
      for (final pt in rtepts) {
        final lat = double.tryParse(pt.getAttribute('lat') ?? '');
        final lng = double.tryParse(pt.getAttribute('lon') ?? '');
        if (lat != null && lng != null) {
          points.add(LatLng(lat, lng));
          final eleEl = pt.findElements('ele').firstOrNull;
          final ele = double.tryParse(eleEl?.innerText ?? '') ?? 0.0;
          elevations.add(ele);
        }
      }
    }

    if (points.isEmpty) return;

    setState(() {
      _gpxRoutePoints = points;
      _gpxRouteElevations = elevations;
      _gpxRouteCumDistKm = _buildCumDistKm(points);
      _isGpxLoaded = true;
    });

    // マップをルート全体が収まるようにズーム（両マップ共通）
    _fitMapToPoints(points);
  }

  // ----------------------------------------------------------
  // オフラインタイル: ルート沿いプリフェッチ
  // ----------------------------------------------------------
  Future<void> _prefetchTilesForActiveRoute() async {
    final route = _aiRoutePoints.isNotEmpty ? _aiRoutePoints : _gpxRoutePoints;
    if (route.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先にルートを設定してください')),
      );
      return;
    }

    // ダウンロード対象領域: ルート沿い ±2km、z10〜z16
    final region = LineRegion(route, kPrefetchBufferMeters);
    final downloadable = region.toDownloadable(
      minZoom: kPrefetchMinZoom,
      maxZoom: kPrefetchMaxZoom,
      options: TileLayer(
        urlTemplate: kTileUrlTemplate,
        userAgentPackageName: kUserAgentPackage,
      ),
    );

    // 進捗ストリーム。broadcast 化して StreamBuilder と完了監視で共用する。
    final stream = const FMTCStore(kTileStoreName)
        .download
        .startForeground(
          region: downloadable,
          // OSM 公式タイルサーバへの配慮: 並列度1、レート制限
          parallelThreads: 1,
          maxBufferLength: 100,
          rateLimit: 60, // 1分あたり最大60タイル
        )
        .asBroadcastStream();

    // 完了したらダイアログを自動で閉じる
    final completionSub = stream.listen((event) {
      if (event.isComplete && mounted && Navigator.canPop(context)) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('🗺️ オフラインタイル取得中',
            style: TextStyle(color: Colors.white)),
        content: StreamBuilder(
          stream: stream,
          builder: (ctx, snap) {
            final ev = snap.data;
            final total = ev?.maxTiles ?? 0;
            final done = ev == null ? 0 : (ev.cachedTiles + ev.skippedTiles);
            final pct = total == 0 ? null : done / total;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: pct),
                const SizedBox(height: 12),
                Text('$done / ${total == 0 ? '?' : total} タイル',
                    style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 4),
                Text(
                  'z$kPrefetchMinZoom〜z$kPrefetchMaxZoom / 沿線±${(kPrefetchBufferMeters / 1000).toStringAsFixed(1)}km',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await const FMTCStore(kTileStoreName).download.cancel();
              if (Navigator.canPop(ctx)) Navigator.of(ctx).pop();
            },
            child:
                const Text('キャンセル', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    await completionSub.cancel();
  }

  Future<void> _showCacheDialog() async {
    final store = const FMTCStore(kTileStoreName);
    final stats = store.stats;
    final tileCount = await stats.length;
    final size = await stats.size; // KiB
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('💾 オフラインキャッシュ',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _summaryRow(Icons.layers, 'タイル数', '$tileCount', Colors.green),
            _summaryRow(Icons.sd_storage, '使用容量',
                '${(size / 1024).toStringAsFixed(1)} MB', Colors.cyan),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await store.manage.reset();
              if (mounted) {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('キャッシュを削除しました')),
                );
              }
            },
            child: const Text('全削除', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  void _startWeatherTimer() {
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _updateWeather(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: IndexedStack(
        index: _currentIndex,
        children: [_buildMainScreen(), _buildRouteScreen(), _buildLogScreen()],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleRecording,
        backgroundColor: _isRecording ? Colors.red : Colors.green,
        child: Icon(
          _isRecording ? Icons.stop : Icons.play_arrow,
          color: Colors.white,
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.grey[900],
        selectedItemColor: Colors.green,
        unselectedItemColor: Colors.grey,
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          // タブ切替に応じて画面常時 ON を再評価（ログ画面では解除）
          _applyWakelockForCurrentTab();
          if (i == 2) {
            _loadLogFiles();
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.speed), label: 'サイコン'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'ルート'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'ログ'),
        ],
      ),
    );
  }

  // メイン画面
  Widget _buildMainScreen() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _gpsValid ? Icons.gps_fixed : Icons.gps_not_fixed,
                  color: _gpsValid ? Colors.green : Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _gpsValid ? 'GPS有効' : 'GPS待機中',
                  style: TextStyle(
                    color: _gpsValid ? Colors.green : Colors.red,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            // 記録中の走行情報
            if (_isRecording) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '記録中 ${_totalDistanceKm.toStringAsFixed(2)} km',
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Text(
                    _speed.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 96,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'km/h',
                    style: TextStyle(color: Colors.grey, fontSize: 24),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _infoCard(
                  Icons.terrain,
                  '高度',
                  '${_altitude.toStringAsFixed(0)} m',
                  Colors.orange,
                ),
                _infoCard(
                  Icons.thermostat,
                  '気温',
                  '${_temperature.toStringAsFixed(1)} ℃',
                  Colors.cyan,
                ),
                _infoCard(
                  Icons.umbrella,
                  '降水確率',
                  '${_rainProb.toStringAsFixed(0)} %',
                  Colors.blue,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Icon(Icons.wb_sunny, color: Colors.yellow, size: 24),
                const SizedBox(width: 8),
                Text(
                  _weatherDesc,
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '${_lat.toStringAsFixed(4)}, ${_lng.toStringAsFixed(4)}',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  // ルート画面
  Widget _buildRouteScreen() {
    return SafeArea(
      child: Column(
        children: [
          if (!_isFullScreenMap) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'AIルート提案',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // オフラインモードのときだけタイル管理ボタンを表示
                      if (_useOfflineMap) ...[
                        IconButton(
                          icon: const Icon(Icons.cloud_download,
                              color: Colors.green),
                          tooltip: 'ルート沿いをオフライン化',
                          onPressed: _prefetchTilesForActiveRoute,
                        ),
                        IconButton(
                          icon: const Icon(Icons.sd_storage,
                              color: Colors.cyan),
                          tooltip: 'キャッシュ管理',
                          onPressed: _showCacheDialog,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  // マップ切替トグル: Google ⇄ オフライン(OSM)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Google'),
                        icon: Icon(Icons.cloud),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('オフライン'),
                        icon: Icon(Icons.cloud_off),
                      ),
                    ],
                    selected: {_useOfflineMap},
                    onSelectionChanged: (sel) {
                      setState(() => _useOfflineMap = sel.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _destController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '目的地を入力（例：金剛山 または 34.5044,135.6148）',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey[900],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search, color: Colors.green),
                        onPressed: _getRoutePlan,
                      ),
                    ),
                  ),
                  if (_isLoadingRoute)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.green,
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'AIがルートを分析中...',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  else if (_totalDistance > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _infoCard(
                            Icons.straighten,
                            '距離',
                            '${_totalDistance.toStringAsFixed(1)} km',
                            Colors.green,
                          ),
                          _infoCard(
                            Icons.timer,
                            '所要時間',
                            '$_totalDuration 分',
                            Colors.orange,
                          ),
                          _infoCard(
                            Icons.trending_up,
                            '獲得標高',
                            '${_totalElevation.toStringAsFixed(0)} m',
                            Colors.red,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],

          // 切替トグルに応じて Google マップ / flutter_map を表示
          Expanded(
            child: Stack(
              children: [
                _useOfflineMap ? _buildOfflineMap() : _buildGoogleMap(),
                Positioned(
                  bottom: 208,
                  right: 12,
                  child: FloatingActionButton(
                    mini: true,
                    heroTag: 'gpx',
                    backgroundColor:
                        _isGpxLoaded ? Colors.orange : Colors.grey,
                    onPressed: _loadGpxFile,
                    child: const Icon(Icons.route, color: Colors.white),
                  ),
                ),
                // ヘディングアップ切替
                Positioned(
                  right: 12,
                  bottom: 80,
                  child: FloatingActionButton(
                    mini: true,
                    heroTag: 'headingUp',
                    backgroundColor:
                        _headingUpMode ? Colors.deepPurple : Colors.grey[700],
                    onPressed: _toggleHeadingUp,
                    child: const Icon(Icons.explore, color: Colors.white),
                  ),
                ),
                // 音声ナビ ON/OFF
                Positioned(
                  right: 12,
                  bottom: 144,
                  child: FloatingActionButton(
                    mini: true,
                    heroTag: 'voiceNav',
                    backgroundColor:
                        _voiceNavEnabled ? Colors.blueAccent : Colors.grey[700],
                    onPressed: () {
                      setState(() => _voiceNavEnabled = !_voiceNavEnabled);
                      if (!_voiceNavEnabled) {
                        _tts.stop();
                      }
                    },
                    child: Icon(
                      _voiceNavEnabled ? Icons.volume_up : Icons.volume_off,
                      color: Colors.white,
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: FloatingActionButton(
                    mini: true,
                    heroTag: 'fullscreen',
                    backgroundColor: Colors.black54,
                    onPressed: () {
                      setState(() => _isFullScreenMap = !_isFullScreenMap);
                    },
                    child: Icon(
                      _isFullScreenMap
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      color: Colors.white,
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton(
                    mini: true,
                    heroTag: 'follow',
                    backgroundColor:
                        _followMode ? Colors.green : Colors.grey[700],
                    onPressed: () {
                      setState(() => _followMode = !_followMode);
                      if (_followMode && _gpsValid) {
                        if (_useOfflineMap && _mapReady) {
                          _mapController.move(
                              LatLng(_lat, _lng), _mapController.camera.zoom);
                        } else if (!_useOfflineMap &&
                            _googleMapController != null) {
                          _isSystemMoving = true;
                          _googleMapController!.animateCamera(
                            gmaps.CameraUpdate.newLatLng(
                                gmaps.LatLng(_lat, _lng)),
                          );
                          Future.delayed(const Duration(milliseconds: 600), () {
                            _isSystemMoving = false;
                          });
                        }
                      }
                    },
                    child: const Icon(Icons.my_location, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),

          // 標高プロファイル（ルートが取得済みのときだけ）
          if (!_isFullScreenMap) _buildElevationProfile(),

          // AI分析テキスト
          if (!_isFullScreenMap && _aiAnalysis.isNotEmpty)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AI分析:',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _aiAnalysis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // オフライン (flutter_map + OSM + FMTC) マップ
  // ----------------------------------------------------------
  Widget _buildOfflineMap() {
    final initialCenter = _gpsValid
        ? LatLng(_lat, _lng)
        : const LatLng(34.7025, 135.4959); // デフォルト中心（大阪駅）

    final markers = <Marker>[
      if (_gpsValid)
        Marker(
          point: LatLng(_lat, _lng),
          width: 36,
          height: 36,
          child: const Icon(Icons.my_location, color: Colors.blue, size: 32),
        ),
      if (_destLatLng != null)
        Marker(
          point: _destLatLng!,
          width: 36,
          height: 36,
          child: const Icon(Icons.location_on, color: Colors.red, size: 36),
        ),
    ];

    final polylines = <Polyline>[
      if (_aiRoutePoints.isNotEmpty)
        Polyline(
            points: _aiRoutePoints, color: Colors.blue, strokeWidth: 4),
      if (_gpxRoutePoints.isNotEmpty)
        Polyline(
            points: _gpxRoutePoints, color: Colors.orange, strokeWidth: 4),
    ];

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 13,
        onMapReady: () {
          _mapReady = true;
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _followMode) {
            setState(() => _followMode = false);
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: kTileUrlTemplate,
          userAgentPackageName: kUserAgentPackage,
          tileProvider:
              const FMTCStore(kTileStoreName).getTileProvider(),
          maxNativeZoom: 19,
        ),
        PolylineLayer(polylines: polylines),
        MarkerLayer(markers: markers),
      ],
    );
  }

  // ----------------------------------------------------------
  // オンライン (google_maps_flutter) マップ
  // ----------------------------------------------------------
  Widget _buildGoogleMap() {
    final initialCenter = _gpsValid
        ? gmaps.LatLng(_lat, _lng)
        : const gmaps.LatLng(34.7025, 135.4959); // デフォルト中心（大阪駅）

    final googleMarkers = <gmaps.Marker>{
      if (_gpsValid)
        gmaps.Marker(
          markerId: const gmaps.MarkerId('current'),
          position: gmaps.LatLng(_lat, _lng),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueBlue),
          infoWindow: const gmaps.InfoWindow(title: '現在地'),
        ),
      if (_destLatLng != null)
        gmaps.Marker(
          markerId: const gmaps.MarkerId('dest'),
          position:
              gmaps.LatLng(_destLatLng!.latitude, _destLatLng!.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueRed),
          infoWindow: gmaps.InfoWindow(title: _destController.text),
        ),
    };

    final googlePolylines = <gmaps.Polyline>{
      if (_aiRoutePoints.isNotEmpty)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('ai'),
          points: _aiRoutePoints
              .map((p) => gmaps.LatLng(p.latitude, p.longitude))
              .toList(),
          color: Colors.blue,
          width: 4,
        ),
      if (_gpxRoutePoints.isNotEmpty)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('gpx'),
          points: _gpxRoutePoints
              .map((p) => gmaps.LatLng(p.latitude, p.longitude))
              .toList(),
          color: Colors.orange,
          width: 4,
        ),
    };

    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(
        target: initialCenter,
        zoom: 13,
      ),
      onMapCreated: (controller) {
        _googleMapController = controller;
      },
      onCameraMove: (pos) {
        // ヘディングアップ時に zoom 維持で newCameraPosition を組み立てるため
        _googleZoom = pos.zoom;
      },
      onCameraMoveStarted: () {
        // ユーザー操作で動いたときのみ追従を解除
        if (_followMode && !_isSystemMoving) {
          setState(() => _followMode = false);
        }
      },
      // バッテリー節約: 自前で青マーカーを描画しているので Google 内部の
      // 位置情報購読は無効化（GPS 系統が二重購読になるのを防ぐ）
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      markers: googleMarkers,
      polylines: googlePolylines,
      mapType: gmaps.MapType.normal,
    );
  }

  // ログ画面
  Widget _buildLogScreen() {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Text(
                  '走行ログ',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.green),
                  onPressed: _loadLogFiles,
                ),
              ],
            ),
          ),
          Expanded(
            child: _logFiles.isEmpty
                ? const Center(
                    child: Text(
                      'ログがありません',
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : ListView.separated(
                    itemCount: _logFiles.length,
                    separatorBuilder: (_, __) =>
                        Divider(color: Colors.grey[800], height: 1),
                    itemBuilder: (context, index) {
                      final entity = _logFiles[index];
                      final name =
                          entity.path.split(Platform.pathSeparator).last;
                      final modified = entity.statSync().modified;
                      final dateStr =
                          DateFormat('yyyy/MM/dd HH:mm').format(modified);
                      return ListTile(
                        leading:
                            const Icon(Icons.route, color: Colors.orange),
                        title: Text(
                          name,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                        subtitle: Text(
                          dateStr,
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12),
                        ),
                        onTap: () =>
                            _showRustAnalysisDialog(File(entity.path)),
                        onLongPress: () => _showLogActionMenu(entity),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteLog(FileSystemEntity entity) async {
    final name = entity.path.split(Platform.pathSeparator).last;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'ログを削除',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '$name を削除しますか？',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await File(entity.path).delete();
        await _loadLogFiles();
      } catch (e) {
        debugPrint('削除エラー: $e');
      }
    }
  }

  Future<void> _showLogActionMenu(FileSystemEntity entity) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('操作を選択', style: TextStyle(color: Colors.white)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'report'),
            child: const Row(
              children: [
                Icon(Icons.cloud_upload, color: Colors.cyan),
                SizedBox(width: 12),
                Text('ライドレポート作成',
                    style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Row(
              children: [
                Icon(Icons.delete, color: Colors.red),
                SizedBox(width: 12),
                Text('削除', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Row(
              children: [
                Icon(Icons.close, color: Colors.grey),
                SizedBox(width: 12),
                Text('キャンセル', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );

    if (choice == 'report') {
      await _createRideReport(entity);
    } else if (choice == 'delete') {
      await _confirmDeleteLog(entity);
    }
  }

  Future<void> _createRideReport(FileSystemEntity entity) async {
    final fileName = entity.path.split(Platform.pathSeparator).last;
    final defaultCourseName = fileName.endsWith('.gpx')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;

    final controller = TextEditingController(text: defaultCourseName);
    final courseName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('コース名を入力',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'コース名',
            hintStyle: const TextStyle(color: Colors.grey),
            filled: true,
            fillColor: Colors.grey[850],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('送信', style: TextStyle(color: Colors.cyan)),
          ),
        ],
      ),
    );

    if (courseName == null || courseName.isEmpty) return;

    final rideDate = DateFormat('yyyy-MM-dd')
        .format(entity.statSync().modified);

    if (!mounted) return;
    // アップロード中インジケータ
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Colors.cyan),
      ),
    );

    try {
      final uri = Uri.parse(
          '$_baseUrl/r/$reportSecret/api/ride_report');
      final request = http.MultipartRequest('POST', uri)
        ..fields['course_name'] = courseName
        ..fields['ride_date'] = rideDate
        ..files.add(await http.MultipartFile.fromPath(
          'gpx',
          entity.path,
          filename: fileName,
        ));

      final streamed = await request.send()
          .timeout(const Duration(seconds: 60));
      final res = await http.Response.fromStream(streamed);

      if (!mounted) return;
      Navigator.pop(context); // インジケータを閉じる

      if (res.statusCode == 200) {
        String status = '';
        try {
          final data = jsonDecode(res.body);
          status = (data['status'] ?? '').toString();
        } catch (_) {}
        if (status == 'queued') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ライドレポートの生成を開始しました。完了後Discordに通知されます'),
              backgroundColor: Colors.green,
            ),
          );
          return;
        }
      }

      String msg;
      switch (res.statusCode) {
        case 404:
          msg = 'シークレット不一致';
          break;
        case 400:
          msg = 'GPXが空';
          break;
        case 413:
          msg = 'ファイルが大きすぎます(20MB超)';
          break;
        case 503:
          msg = 'サーバ未設定';
          break;
        default:
          msg = '失敗 (${res.statusCode})';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ライドレポート作成エラー: $msg'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // インジケータを閉じる
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('送信エラー: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _infoCard(IconData icon, String label, String value, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------
  // 標高プロファイル ウィジェット
  // ----------------------------------------------------------
  Widget _buildElevationProfile() {
    final active = _activeRouteWithElev();
    if (active == null) return const SizedBox.shrink();
    final elev = active.elev;
    final cum = active.cumKm;
    if (elev.length < 2 || cum.last <= 0) return const SizedBox.shrink();

    final minE = elev.reduce(min);
    final maxE = elev.reduce(max);
    final gain = _calcElevationGain(elev);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terrain, color: Colors.green, size: 16),
              const SizedBox(width: 4),
              Text(
                '標高 ${minE.toStringAsFixed(0)}〜${maxE.toStringAsFixed(0)}m',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '↑ ${gain.toStringAsFixed(0)}m',
                style: const TextStyle(color: Colors.orange, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 70,
            width: double.infinity,
            child: CustomPaint(
              painter: ElevationProfilePainter(
                elevations: elev,
                cumDistKm: cum,
                currentDistKm: _currentRouteCumKm,
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _calcElevationGain(List<double> elev) {
    double gain = 0;
    for (int i = 1; i < elev.length; i++) {
      final d = elev[i] - elev[i - 1];
      if (d > 0) gain += d;
    }
    return gain;
  }
}

// ----------------------------------------------------------
// 標高プロファイル CustomPainter
// ----------------------------------------------------------
class ElevationProfilePainter extends CustomPainter {
  final List<double> elevations;
  final List<double> cumDistKm;
  final double? currentDistKm;

  ElevationProfilePainter({
    required this.elevations,
    required this.cumDistKm,
    this.currentDistKm,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (elevations.length < 2) return;
    if (cumDistKm.length != elevations.length) return;
    final totalKm = cumDistKm.last;
    if (totalKm <= 0) return;

    double minE = elevations.first, maxE = elevations.first;
    for (final e in elevations) {
      if (e < minE) minE = e;
      if (e > maxE) maxE = e;
    }
    final range = (maxE - minE).clamp(1.0, double.infinity);

    // ベースライン余白
    const topPad = 4.0;
    const bottomPad = 2.0;
    final usableH = size.height - topPad - bottomPad;

    final fill = Path()..moveTo(0, size.height - bottomPad);
    final line = Path();
    for (int i = 0; i < elevations.length; i++) {
      final x = (cumDistKm[i] / totalKm) * size.width;
      final y = size.height -
          bottomPad -
          ((elevations[i] - minE) / range) * usableH;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
      fill.lineTo(x, y);
    }
    fill.lineTo(size.width, size.height - bottomPad);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()..color = Colors.green.withOpacity(0.25),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    // 現在地ピン
    if (currentDistKm != null && currentDistKm! >= 0) {
      final t = (currentDistKm! / totalKm).clamp(0.0, 1.0);
      final x = t * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.cyan
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(
        Offset(x, size.height / 2),
        4,
        Paint()..color = Colors.cyan,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ElevationProfilePainter old) =>
      old.elevations != elevations ||
      old.cumDistKm != cumDistKm ||
      old.currentDistKm != currentDistKm;
}
