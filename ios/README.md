# Foredeck

Hands-free crew intercom for docking and anchoring, plus a shared anchor screen.

Everyone hears everyone, at the same time, with no button to hold. It works over
the boat's WiFi and also works with no router at all, phone to phone. Alongside
the voice channel, the whole crew sees the same anchor drop point, swing circle
and distances, and any of them can change them.

---

## Status, honestly

The parts that can be tested without hardware **are** tested — 60-odd unit tests
covering the packet format, the jitter buffer, the voice-activity detector, the
mu-law codec, the anchor-state merge and the pairing keys. Run them with
`swift test`.

Everything else — the AVAudioEngine graph, Multipeer discovery, the map, the
background behaviour — has **never been compiled or run**. It was written on
Linux, where no Swift toolchain or Xcode exists. Treat the first build as the
start of the work, not the end of it. In particular, expect to iterate on the
audio session and background behaviour, which cannot be got right by reasoning
alone.

## Building

```sh
brew install xcodegen          # once
cd ios
xcodegen generate
open Foredeck.xcodeproj
```

Set your own team and bundle identifier in Signing & Capabilities, then build to
**two physical iPhones**. The Simulator is not useful here: no real microphone,
no Multipeer radios.

Running the core tests, which needs no device:

```sh
swift test --package-path ios/ForedeckCore
```

## How it fits together

```
Foredeck (app target)        SwiftUI · AVAudioEngine · MapKit · CoreLocation
                             MultipeerTransport · SignalKClient
        depends on
ForedeckCore (pure Swift)    AudioPacket · JitterBuffer · VoiceActivityDetector
                             MuLaw · AnchorState · BoatKey · CrewTransport
```

`ForedeckCore` imports only Foundation and CryptoKit. That is what makes it
testable, and it is why the logic worth being sure about lives there rather than
tangled into the audio callbacks.

### The decisions that matter

**Echo cancellation is the load-bearing wall.** Two phones on speaker within
earshot, both with open microphones, is an acoustic feedback loop. `AudioEngine`
calls `setVoiceProcessingEnabled(true)` and sets the audio session to
`.voiceChat`, which switches iOS to its voice-processing IO unit: hardware echo
cancellation, noise suppression and automatic gain control. Without it the whole
concept does not work.

**Multipeer Connectivity, behind a protocol.** It needs no router, no server, no
IP configuration and no multicast entitlement, and it survives an access point
with client isolation switched on — the failure that would kill a plain UDP
design, and which is the default on a lot of cheap boat routers. It costs us a
hard ceiling of eight devices and an audio pipeline we have to build ourselves,
which is what `JitterBuffer` is. Everything above `CrewTransport` is written
against that protocol and nothing else, so swapping in WebRTC later is one new
conformance rather than a rewrite.

**Audio goes out unreliably, on purpose.** A late voice frame is worse than a
missing one, and Multipeer's streams are TCP-like — one lost frame would stall
everything queued behind it.

**Open mic is gated by voice activity.** A phone clipped to the pushpit in
twenty knots otherwise fills everyone's ears with wind for the whole manoeuvre.
The detector's noise floor rises slowly and falls fast, and sensitivity is in
settings because no single default suits both a gale and a quiet anchorage.
Push-to-talk is one tap away for when conditions beat the gate.

**Anchor state has no host.** Each field is a last-writer-wins register ordered
by a Lamport clock, so any crew member can edit from any phone and every phone
converges. A host-based design puts the anchor alarm on one particular phone,
and that is the phone that goes flat at 0300.

## Testing it for real

1. `swift test --package-path ios/ForedeckCore` — should be green before anything else.
2. Build to two phones. On the first, create the boat; on the second, scan the QR
   code or type the ten-character code.
3. **Bench test.** Both phones on WiFi, a few metres apart. Check discovery,
   two-way audio, and — the real check — that both people can talk at once
   without echo or howl. Then lock both screens and confirm audio keeps working.
4. **No-router test.** Turn WiFi off on both phones, leave Bluetooth on. They
   should still find each other. This is the case a LAN-only design cannot serve.
5. **Sea trial**, the only test that really counts. Helm and bow, engine running.
   Judge latency by whether a docking call lands before the moment passes. Tune
   mic sensitivity from what you hear, not from the numbers.
6. **Anchor test.** Drop the anchor point on one phone, confirm it appears on the
   others, arm the alarm, walk beyond the radius, and confirm *every* phone
   alarms — not just the one that noticed.

## Known limitations

- **Not compiled yet.** See above.
- **Background survival is the highest-risk item.** The `audio` background mode
  keeps the process alive with the screen locked, which in turn keeps Multipeer
  running. This is the intended mechanism and it needs verifying at step 3 before
  any sea trial.
- **Eight devices maximum**, a Multipeer limit.
- **Pairing security is proportionate, not strong.** The typed code carries about
  50 bits of entropy and peers are not certificate-pinned. This keeps the
  neighbouring boat out of your intercom. It is not a defence against someone
  already on your network who is actively attacking it — which, for a channel
  carrying "fender forward" and "two metres", is the right trade.
- **mu-law, not a perceptual codec.** 128 kbit/s per talker at 16 kHz. AAC-ELD or
  Opus would cut that substantially and is the natural next step; it slots in
  behind `WireCodec` and a new `CodecID`, and the packet header already carries
  the codec so a mixed-version crew degrades to dropping frames it cannot decode
  rather than playing noise. It was left out deliberately: several hundred lines
  of AudioToolbox interop that could not be compiled or tested here would have
  looked more finished than it was.
- **Wind beats software.** A phone at arm's length in twenty knots is a bad
  microphone and nothing in the app fixes that. AirPods or a wired headset make a
  far bigger difference than any setting here.

## Signal K

Optional and entirely degradable. If the boat's Signal K server is reachable, its
GPS is used for the anchor position — it is mounted somewhere sensible rather
than in someone's jacket pocket — and depth and apparent wind appear on the
anchor screen. No server, no problem: everything falls back to CoreLocation and
the instrument row hides itself.
