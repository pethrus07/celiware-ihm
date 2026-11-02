# Ware IoT

English · [Português](README.pt-BR.md)

An Android app that turns a phone into a machine's HMI. The user registers the device, names
the memory addresses that matter and builds operator screens with buttons, lamps, displays
and charts, without writing code.

## Status

In production: 1.4.0 on Google Play since 2026-10-21 (Brazil, free). Version 1.5.0 is ready on
`main` and has not been sent to the store yet. Updated 2026-11-01.
Built for a client in industrial automation, who publishes the app and sells the connection
hardware. Product site (Portuguese): https://wareiot.com.br.

## The problem

A panel HMI is expensive and fixed to the machine. Maintenance and supervision people want to
see and command the machine up close, from their phone, without vendor software or code.
Ware IoT talks to the PLC directly over the local network or a cable.

## What it does

- **Seven protocols**, all implemented inside the app:
  Modbus TCP; Modbus RTU and ASCII (through a TCP gateway or a USB-OTG cable); Siemens S7;
  OPC UA (own client, no-security mode); MQTT; raw TCP, UDP or serial with a message parser
  (Arduino); HTTP/HTTPS for REST APIs.
- **Ready-made memory maps** for some PLC and drive brands.
- **Named variables**: the screen points to "Speed", not "HR 2". Calculated variables too.
- **Screen editor** on a grid (normal, fine and extra fine) with 13 element types, a background
  image (synoptic) and screen templates.
- **A plant with several projects** (one per machine), stored on the device; one project or the
  whole plant can be sent as a file to another phone.
- **Alarms** following ISA-18.2 (priority by color, shape and number), with voice alerts.
- **Recipes, periodic logging to SQLite with CSV export, rules between machines** (they only
  propose; never a safety function) and **IP cameras** (RTSP) linked to a machine.
- **Built-in demo machine**: the app works fully with nothing on the network.
- Light and dark theme, tablet layout, a tutorial on every screen.

## Stack

Flutter and Dart (Android; Flutter's `minSdk`, `targetSdk` pinned to 36). The protocol stacks
are written in-house, with no Modbus, S7 or OPC UA library. Camera video uses ExoPlayer
(Media3) directly from Kotlin. Static site in `site/`. Python simulators in `sim/`.

Dependencies from `pubspec.yaml`:

| Package | Used for |
|---|---|
| `path_provider` | the app's private folder, where the plant lives |
| `file_picker` | export and import projects, pick an image or PDF |
| `shared_preferences` | small per-device flags (tutorial seen) |
| `logging` | protocol stack and runtime logs |
| `sqflite` | periodic variable logging |
| `mqtt_client` | MQTT 3.1.1 client |
| `flutter_tts` | spoken alarm alerts |
| `flutter_secure_storage` | camera and HTTP passwords in the Android Keystore |
| `printing` | render a PDF page as an image (image element and screen background) |
| `share_plus` | send a project, the plant, backups, CSV logs and camera snapshots |
| `in_app_update` | new version prompt through Play |
| `clock`, `flutter_localizations` | testable clock and Flutter's own strings in Portuguese |

IBM Plex fonts (OFL license) are bundled.

## Run locally

```bash
flutter pub get
flutter run
```

The app opens with the demo project (a simulated label cutter). On Windows, `flutter pub get`
needs Developer Mode turned on.

To test the network without hardware there are simulators in `sim/` (Modbus TCP, Arduino,
HTTP); the steps are in `docs/SIMULACAO.md`.

## Tests

```bash
flutter test      # protocols, real localhost sockets, codecs, runtime, screens
flutter analyze   # must answer "No issues found"
```

There is no CI.

## Folders

```
lib/
  main.dart     entry point and lifecycle
  app/          plant and project controller, app version
  core/         protocol stacks (modbus, s7, opcua, mqtt, http, rawlink, serial), theme
  models/       device, variable, screen, project, plant
  services/     runtime engine, demo, storage, logging, voice
  screens/      app pages and tutorial texts
  widgets/      HMI elements and shared components
android/        Android project (camera player and Wi-Fi binding included)
sim/            Python simulators
site/           product site (static HTML and CSS)
test/           automated tests
tool/           icon, Word document, store images and video generators
docs/           architecture, simulation, publishing, roadmap, history
```

## Architecture

Diagrams (use cases, process, C4) are in [docs/arquitetura/](docs/arquitetura/). The full
technical description is in [docs/ARQUITETURA.md](docs/ARQUITETURA.md). What comes next:
[docs/ROADMAP.md](docs/ROADMAP.md).

## Decisions and known limits

- The app is never a machine safety function. Rules between machines only propose an action.
- Without communication, the last value stays on screen, dimmed. It never turns into zero.
- Scope: only what lives inside the app. No login, server, cloud or licensing.
- None of the newer protocols (S7, OPC UA, MQTT, serial, HTTP, cameras) had been tested on real
  equipment by 2026-11-01; only against simulators and test servers.
- OPC UA in no-security mode only; no Subscription.
- Alarms only while the app is open.
- `targetSdk` pinned to 36: raising it breaks local network connections.
- Internal documentation is in Portuguese.

## License

All rights reserved. Published as portfolio; not licensed for reuse. See [LICENSE](LICENSE).
