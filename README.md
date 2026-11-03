# Volume Mixer

Per-app volume and mute from the menu bar. Requires macOS 15+.

## Build

```
cd ~/Downloads/VolumeMixer   # wherever you unzipped it
chmod +x build.sh && ./build.sh
```

Needs Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not required.

## First run

macOS asks for **System Audio Recording** permission. Allow it.
If you deny it, any app you adjust will go silent. Fix it in
System Settings → Privacy & Security → Screen & System Audio Recording,
or click **Reset all**.

## How it works

- Apps at 100% and unmuted are left completely alone.
- Lowering or muting an app creates a private audio tap. The tap mutes the app's normal output and plays it back at your chosen level.
- Quitting (or a crash) removes every tap automatically, so audio returns to normal.
- Settings are remembered per app.

## Uninstall

Quit it from the menu, then delete `~/Applications/VolumeMixer.app`.

## Audio health log

Click the cog in the panel to open Settings. It charts the added delay and any
dropouts over the last hour, 24 hours or 7 days, with notes on how much the
data can actually tell you. The raw log is a plain text file (one JSON event
per line) at `~/Library/Application Support/VolumeMixer/events.jsonl`. It stays
on your Mac and keeps the latest 5,000 events.

## Headphone EQ

Settings → Headphone EQ. Pick an output device, search for your headphones,
and click a result. Profiles come from AutoEq (github.com/jaakkopasanen/AutoEq),
which publishes corrections measured by oratory1990, crinacle, Rtings and others.
The EQ follows the device: it turns on when you switch to that output and off
when you switch away. While it's on, all audio on that device goes through
Volume Mixer.

## Open at login

On by default after the first launch. Toggle it in Settings → General.

## Signing

The first build creates a personal code-signing certificate ("VolumeMixer
Local Signing") in your login keychain, so every build has the same
signature and macOS keeps its permissions. It's self-signed and only on this
Mac. To remove it: Keychain Access → login → My Certificates → delete it.

## Credits

- **[AutoEq](https://github.com/jaakkopasanen/AutoEq)** by Jaakko Pasanen (MIT
  license): the headphone EQ profiles. Volume Mixer downloads them at runtime;
  none are bundled. The measurements behind each profile are by the source
  shown next to it (oratory1990, crinacle, Rtings and others).
- **[Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)** by Robert
  Bristow-Johnson: the peak and shelf filter formulas.
- **[volumeHUD](https://github.com/dannystewart/volumeHUD)** by Danny Stewart:
  the idea of intercepting volume keys to suppress the system volume popup.
  No code was copied.

## License

MIT. See [LICENSE](LICENSE).
