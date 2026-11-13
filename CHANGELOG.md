# Changelog

## 1.0.1

### Fixed
- **Files without a stated duration now open.** Files whose container records no length, such as Matroska recordings that were never finalized, were refused with "Unknown duration". Spectrum now decodes the stream once to measure it, then renders the spectrogram as usual.
- **Exported PNGs in Dark Mode.** The window background came out transparent, so the white labels vanished when the image was viewed on a light background. Exports now include the window's background color and look exactly like the window.
- **Channel and stream changes during a sheet.** Switching channel or stream (menu or metadata bar) is now disabled while a sheet such as the export panel is open, so an export can no longer capture a run that started underneath it.
- **Missing sample rate.** A file with no usable sample rate now reports "Unknown sample rate" instead of a misleading error.

### Improved
- **Smoother rendering.** The frequency and time rulers and the palette strip are no longer redrawn on every frame while a spectrogram fills (74 redraws per file reduced to 1), freeing main-thread time.
- **Bit rate, sampling frequency and bit depth fields** use the shared UtilityKit field chrome, matching the other apps.
- **Settings window** rebuilt on the shared SettingsKit row components, with the standard layout for the prefetch, frequency-axis and debug-logging options.
- The Window menu now includes the standard Minimize and Zoom commands.

### Internal
- Adopted the updated shared utilities (DebugLogKit, SettingsKit, MenuBarKit) and added UtilityKit; replaced the app's own path-bar chrome and open-panel helpers with the shared versions.
- Reduced opt-outs of Swift strict memory safety: the drag-and-drop target, window accessor, PNG export, palette strip, FFT sample read-in, codec-name parsing and the pipeline throttle (now compiler-checked `Sendable`) no longer use unsafe code. The remaining opt-outs are confined to the FFmpeg C boundary, the image builder's pixel buffer (kept for speed) and the shared vDSP setup.
- The FFT reads each window directly from the sample buffer instead of copying it first (bit-identical output, same speed).
- Removed dead code: unused preference setters and the pipeline's unused helpers.
- Duration formatting shares the ruler's time formatter.
