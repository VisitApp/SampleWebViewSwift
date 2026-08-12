//
//  GeolocationBridge.swift
//  samplewebview
//
//  Replaces `navigator.geolocation` inside the web content with a shim that
//  routes through CoreLocation. WKWebView does not surface the app-level
//  location prompt on its own, so without this the web page's
//  "Use current location" action silently fails when permission has never
//  been granted.
//

import CoreLocation
import Foundation
import WebKit

@MainActor
final class GeolocationBridge: NSObject {

    static let messageHandlerName = "__nativeGeolocation"

    /// Called when location is unusable because the user actively denied it.
    /// The system will not prompt again, so the app should point at Settings.
    var onPermissionDenied: (() -> Void)?

    private let locationProvider = LocationProvider()
    private weak var webView: WKWebView?

    /// Maps the JS-side watch id to the native observer backing it.
    private var watches: [Int: (observer: UUID, highAccuracy: Bool)] = [:]

    func install(on webView: WKWebView) {
        self.webView = webView

        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageHandlerName)
        controller.addUserScript(
            WKUserScript(
                source: Self.shimSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    // MARK: - Actions

    private func currentPosition(options: Options) async -> [String: Any] {
        do {
            let location = try await locationProvider.requestLocation(
                highAccuracy: options.enableHighAccuracy,
                maximumAge: options.maximumAge,
                timeout: options.timeout
            )
            return ["position": Self.positionPayload(for: location)]
        } catch {
            return ["error": errorPayload(for: error)]
        }
    }

    private func startWatch(id: Int, options: Options) {
        stopWatch(id: id)

        let observer = locationProvider.addObserver(highAccuracy: options.enableHighAccuracy) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let location):
                self.dispatch(watchID: id, payload: ["position": Self.positionPayload(for: location)])
            case .failure(let error):
                self.dispatch(watchID: id, payload: ["error": self.errorPayload(for: error)])
            }
        }

        watches[id] = (observer, options.enableHighAccuracy)
    }

    private func stopWatch(id: Int) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        locationProvider.removeObserver(watch.observer, highAccuracy: watch.highAccuracy)
    }

    private func dispatch(watchID: Int, payload: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }

        let script = "window.__nativeGeolocationDispatch && window.__nativeGeolocationDispatch(\(watchID), \(json));"
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }

    // MARK: - Payloads

    private func errorPayload(for error: Error) -> [String: Any] {
        let geolocationError = (error as? GeolocationError) ?? .positionUnavailable(error.localizedDescription)

        if geolocationError.code == GeolocationError.permissionDenied.code, locationProvider.isDenied {
            onPermissionDenied?()
        }

        return ["code": geolocationError.code, "message": geolocationError.message]
    }

    private static func positionPayload(for location: CLLocation) -> [String: Any] {
        var coordinates: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": max(location.horizontalAccuracy, 0),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]

        // The W3C spec expects null, not a sentinel, for unavailable values.
        if location.verticalAccuracy >= 0 {
            coordinates["altitude"] = location.altitude
            coordinates["altitudeAccuracy"] = location.verticalAccuracy
        }
        if location.course >= 0 {
            coordinates["heading"] = location.course
        }
        if location.speed >= 0 {
            coordinates["speed"] = location.speed
        }

        return coordinates
    }

    // MARK: - Options

    struct Options {
        var enableHighAccuracy = false
        var timeout: TimeInterval?
        var maximumAge: TimeInterval = 0

        init(_ raw: Any?) {
            guard let raw = raw as? [String: Any] else { return }

            if let highAccuracy = raw["enableHighAccuracy"] as? Bool {
                enableHighAccuracy = highAccuracy
            }
            // JS supplies milliseconds; Infinity arrives as nil or a non-finite value.
            if let milliseconds = raw["timeout"] as? Double, milliseconds.isFinite {
                timeout = max(milliseconds, 0) / 1000
            }
            if let milliseconds = raw["maximumAge"] as? Double, milliseconds.isFinite {
                maximumAge = max(milliseconds, 0) / 1000
            }
        }
    }
}

// MARK: - WKScriptMessageHandlerWithReply

extension GeolocationBridge: WKScriptMessageHandlerWithReply {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else {
            return (nil, "Unsupported geolocation message.")
        }

        let options = Options(body["options"])

        switch action {
        case "getCurrentPosition":
            return (await currentPosition(options: options), nil)

        case "watchPosition":
            guard let watchID = (body["watchId"] as? NSNumber)?.intValue else {
                return (nil, "Missing watch id.")
            }
            startWatch(id: watchID, options: options)
            return (nil, nil)

        case "clearWatch":
            guard let watchID = (body["watchId"] as? NSNumber)?.intValue else {
                return (nil, "Missing watch id.")
            }
            stopWatch(id: watchID)
            return (nil, nil)

        default:
            return (nil, "Unknown geolocation action '\(action)'.")
        }
    }
}

// MARK: - Injected JavaScript

private extension GeolocationBridge {

    static let shimSource = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var bridge = handlers && handlers.__nativeGeolocation;
      if (!bridge) { return; }

      var PERMISSION_DENIED = 1;
      var POSITION_UNAVAILABLE = 2;
      var TIMEOUT = 3;

      var watchers = {};
      var nextWatchId = 1;

      function plainOptions(options) {
        if (!options) { return {}; }
        var timeout = options.timeout;
        var maximumAge = options.maximumAge;
        return {
          enableHighAccuracy: !!options.enableHighAccuracy,
          timeout: (typeof timeout === 'number' && isFinite(timeout)) ? timeout : null,
          maximumAge: (typeof maximumAge === 'number' && isFinite(maximumAge)) ? maximumAge : null
        };
      }

      function toPosition(raw) {
        return {
          coords: {
            latitude: raw.latitude,
            longitude: raw.longitude,
            accuracy: raw.accuracy,
            altitude: (raw.altitude === undefined) ? null : raw.altitude,
            altitudeAccuracy: (raw.altitudeAccuracy === undefined) ? null : raw.altitudeAccuracy,
            heading: (raw.heading === undefined) ? null : raw.heading,
            speed: (raw.speed === undefined) ? null : raw.speed
          },
          timestamp: raw.timestamp
        };
      }

      function toError(raw) {
        return {
          code: (raw && raw.code) || POSITION_UNAVAILABLE,
          message: (raw && raw.message) || 'Location is unavailable.',
          PERMISSION_DENIED: PERMISSION_DENIED,
          POSITION_UNAVAILABLE: POSITION_UNAVAILABLE,
          TIMEOUT: TIMEOUT
        };
      }

      function deliver(result, onSuccess, onError) {
        if (result && result.position) {
          if (onSuccess) { onSuccess(toPosition(result.position)); }
        } else if (onError) {
          onError(toError(result && result.error));
        }
      }

      function getCurrentPosition(onSuccess, onError, options) {
        bridge.postMessage({ action: 'getCurrentPosition', options: plainOptions(options) })
          .then(function (result) { deliver(result, onSuccess, onError); })
          .catch(function (reason) {
            if (onError) {
              onError(toError({ code: POSITION_UNAVAILABLE, message: String(reason) }));
            }
          });
      }

      function watchPosition(onSuccess, onError, options) {
        var watchId = nextWatchId++;
        watchers[watchId] = { onSuccess: onSuccess, onError: onError };
        bridge.postMessage({ action: 'watchPosition', watchId: watchId, options: plainOptions(options) })
          .catch(function (reason) {
            if (onError) {
              onError(toError({ code: POSITION_UNAVAILABLE, message: String(reason) }));
            }
          });
        return watchId;
      }

      function clearWatch(watchId) {
        if (!watchers[watchId]) { return; }
        delete watchers[watchId];
        bridge.postMessage({ action: 'clearWatch', watchId: watchId }).catch(function () {});
      }

      window.__nativeGeolocationDispatch = function (watchId, payload) {
        var watcher = watchers[watchId];
        if (!watcher) { return; }
        deliver(payload, watcher.onSuccess, watcher.onError);
      };

      var geolocation = {
        getCurrentPosition: getCurrentPosition,
        watchPosition: watchPosition,
        clearWatch: clearWatch
      };

      try {
        Object.defineProperty(navigator, 'geolocation', {
          value: geolocation,
          configurable: true,
          enumerable: true,
          writable: false
        });
      } catch (e) {
        navigator.geolocation = geolocation;
      }
    })();
    """#
}
