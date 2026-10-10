# AR Menu

A Flutter app for Android and iOS that does two things:

1. **AR food menu.** Browse dishes and place them as 3D models on a real table. You can place several dishes side by side, then drag and rotate them.
2. **3D object scanner.** Photograph any real object from all sides. The photos are turned into a textured 3D model in the cloud, which you can then view in AR. You can also add a scanned object to the menu with a name, description and price.

## How it works

```
Scan screen ──photos──▶ ReconstructionService ──GLB──▶ ItemStore ──▶ AR viewer
(camera, guided         (KIRI Engine photogrammetry,   (local JSON +  (ARCore / ARKit via
 auto-capture)           swappable interface)           files on disk) ar_flutter_plugin_2)
```

| Path | What it does |
| --- | --- |
| `lib/screens/home_screen.dart` | Two tabs: **Menu** and **My scans** |
| `lib/screens/scan_screen.dart` | Guided capture: manual shutter or auto-capture every 1.2 s, with tips for each lap around the object. Needs at least 20 photos; about 45 are recommended. |
| `lib/screens/ar_viewer_screen.dart` | Full in-app AR: horizontal plane detection, tap to place, pan/rotate, an item picker, and clear |
| `lib/screens/item_detail_screen.dart` | Item details, edit (name, price, menu toggle, size in AR), delete |
| `lib/data/item_store.dart` | Local storage. Seeds the menu from `assets/menu.json`, polls running scans, downloads and caches models |
| `lib/services/kiri_reconstruction_service.dart` | KIRI Engine API client: upload photos → poll status → download zip → extract `.glb` |
| `lib/services/glb_bounds.dart` | Reads a GLB's real-world size, so every model appears at the size you choose (e.g. "12 cm") on both platforms |

Everything is stored on the device, in the app documents folder:
- `items.json`: the item list
- `models/<id>.glb`: 3D models
- `thumbs/<id>.jpg`: thumbnails

## Setup

Requirements:
- Flutter 3.32 or later (Dart 3.8)
- An ARCore-capable Android phone (Android 9 / API 28 or later), or an ARKit iPhone (iOS 15 or later)
- AR does not run in emulators or simulators.

```bash
flutter pub get
flutter run --dart-define=KIRI_API_KEY=your_kiri_key
```

- Without `KIRI_API_KEY`, the menu and AR viewer still work, but the scan screen explains how to enable scanning.
- Get a key at <https://www.kiriengine.app/api>. New accounts get free test credits, and each scan uses credits.

### Customising the menu
Edit `assets/menu.json`. The seed only loads on first launch, so reinstall the app (or clear its data) to see changes.

Each entry needs:
- `id`, `name`, `description`, `price`
- `modelUrl`: a public `.glb`
- `displaySize`: the longest side in AR, in meters

The two sample dishes use Khronos glTF sample models as placeholders. Replace them with your own dish models, or scan real dishes in the app and tap **Add to menu**.

## Tips for good scans
- Use even, diffuse light, and a plain, non-reflective surface under the object.
- Do three laps: one at table height, one at 45° looking down, and one close to the top.
- Move slowly and keep the object inside the frame brackets.
- Shiny, transparent and very thin objects reconstruct poorly. This is a limit of photogrammetry.

## Known limitations / next steps
- **The API key ships in the app.** That is fine for development. For production, proxy the three KIRI calls through your own backend and point `ReconstructionService` at it.
- **`ar_flutter_plugin_2` is young (0.0.3).** Its Android and iOS sides treat model scale differently, which `arScaleFor` / `arUriFor` in `ar_viewer_screen.dart` account for. Test on real devices of both platforms before shipping.
- **Processing time.** Cloud reconstruction can take several minutes. The app polls every 20 s while open, and you can pull to refresh.
- **Possible upgrade: on-device capture.** On LiDAR iPhones, Apple's Object Capture (RealityKit) could replace the cloud step through a platform channel. It outputs USDZ, so it would need a USDZ-capable renderer or a conversion step.

## Tests

```bash
flutter test     # GLB sizing, KIRI client (mocked HTTP), store lifecycle
flutter analyze
```
