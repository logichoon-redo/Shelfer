# IndoorPositioning

Step-counting pedestrian dead reckoning (PDR) with floor-plan constraints, in
Swift, with no external dependencies.

Built to answer one question in a real building: **where is the user right now,
with no survey, no beacons, and no building approvals?**

---

## The one decision everything follows from

Do not integrate acceleration.

Double integration makes position error grow as `½·b·t²`, and the dominant `b`
is not accelerometer bias — it is attitude error. To get horizontal
acceleration you must subtract a 9.81 m/s² gravity vector, and being wrong
about which way is down by **1°** leaks `9.81·sin(1°) ≈ 0.17 m/s²` into the
horizontal axes. That is larger than the horizontal acceleration of walking
itself. Ten seconds later it is 8.6 m of error. Phone-grade MEMS cannot close
that gap; it is why strapdown inertial navigation runs on IMUs that cost more
than a car.

```swift
// Never. Error diverges as t².
velocity += (acceleration - gravity) * dt
position += velocity * dt

// Instead: count bounded events.
if let step = stepDetector.process(sample) {          // a footfall is discrete
    let length = stepLengthEstimator.length(for: step) // 0.35-1.0 m, always
    let heading = walkingHeading                       // from a different axis
    position += Vector2.unit(angle: heading) * length
}
```

Walking is periodic. Each footfall is a discrete event, and one step displaces
you by a bounded 0.6–0.8 m. Counting and summing those turns quadratic-in-time
error growth into linear-in-distance error growth.

`EngineTests.testDoubleIntegrationIsWhatWeAvoided` runs both on the same input
and asserts the gap.

## The half that is left: heading

Counting steps gives distance. It says nothing about direction, and direction is
where PDR actually dies.

| error source | uncalibrated | calibrated | how it grows |
|---|---|---|---|
| step length | 10–15 % | ~5 % | proportional to distance, gently |
| heading | degrees per minute of gyro drift; tens of degrees near steel | — | **unbounded, lateral, self-reinforcing** |

5° of heading error held over 50 m puts you 4.4 m sideways, and nothing in the
dead reckoning ever pulls it back. Knowing the starting point does not help:
accuracy is monotonically decreasing, so a reset mechanism is mandatory, not
optional.

## Why the floor plan is not a separate idea

In a corridor network, direction of travel is not a free variable. You cannot
walk at an arbitrary angle — you walk along one of a handful of corridor axes.
Constraining heading to those axes attacks exactly the error source that PDR
cannot handle on its own.

`ParticleFilter` applies two constraints per step:

* **Wall crossings kill particles.** A drifting heading eventually tries to walk
  through a wall, and that hypothesis dies.
* **Corridor axes reweight particles.** A von Mises term on the *axial*
  difference between a particle's heading and the nearest corridor — axial,
  because a corridor is a line and both directions along it are legal.

Each particle carries `(position, headingBias, stepScale)`, so the filter
estimates *how wrong the sensors are* rather than trusting them. Stride error is
left to accumulate gently; heading error is pruned continuously.

Start point (a door on the plan) + step PDR + corridor constraint = zero survey,
zero infrastructure, zero approvals.

## The remaining trap: carriage mode

Hand, pocket, bag, and on-a-call all produce different signals — different
amplitudes, so different step lengths from the same model, and worse, a
different relationship between where the phone points and where the body goes.
Hold a phone sideways and walk forward, and a naive heading is 90° wrong.

`WalkingDirectionEstimator` runs PCA on horizontal acceleration. Walking
accelerates and decelerates the body along the direction of travel every step
and only sways perpendicular to it, so the horizontal acceleration cloud is an
ellipse whose long axis is the walking axis — whatever the phone is doing.

PCA gives an **axis, not an arrow**. Forward and backward are identical to it.
Three things resolve the sign, in order: continuity with the previous estimate,
an external hint (the entry-point heading), and gait asymmetry (a heuristic).
When none of them settles it, the ambiguity is handed to the map:
`ParticleFilter.splitForDirectionAmbiguity()` walks both hypotheses and lets the
corridor geometry kill one. In a straight corridor it genuinely cannot be
resolved, and `PositionFix.isAmbiguous` says so rather than picking.

`CarriageModeClassifier` is a transparent rule set over documented features, not
a learned model — there is no labelled data yet, and a rule you can read beats a
black box you cannot. Its thresholds are starting points. `CarriageFeatures` is
public so you can log them against known modes and re-fit.

---

## Measure two things before building anything else

Both come straight from the error model, and both are answered by
`pdr-validate`.

### 1. Pure PDR drift over a straight 100 m

Walk a surveyed straight line with no map help. 5–10 m of final error is the
expected band. Whatever it is, it converts directly into marker infrastructure:

```
anchor spacing = tolerance / (error per metre walked)
```

That is the answer to "how many QR codes do we print".

```sh
swift run pdr-validate drift --log walk.csv --distance 100 --tolerance 5
swift run pdr-validate drift --log walk.csv --distance 100 --with-map
```

The report splits the error into along-track (the stride model — calibrate it)
and lateral (heading — the part that keeps growing), and prints the implied
constant heading error so you can sanity-check it against the gyro spec.

### 2. Hand versus pocket

The same corridor, walked twice.

```sh
swift run pdr-validate carriage --hand hand.csv --pocket pocket.csv --distance 100
```

If the two differ materially, a carriage-mode classifier is in the MVP, not the
backlog. The thresholds encoding that judgement are in
`DriftExperiment.CarriageComparison.requiresClassifierInMVP`.

### Recording the walks

`MotionRecorder` captures the stream to a `MotionLog` CSV. Record once, replay a
hundred times — re-walking the corridor after every parameter change is how a
two-day investigation becomes a two-week one.

```swift
let recorder = MotionRecorder(source: CoreMotionSource(sampleRate: 50))
recorder.start()                       // walk the surveyed line
recorder.stop()
let url = try recorder.writeLog()      // hand to a share sheet, or Files.app
```

`Info.plist` needs `NSMotionUsageDescription`; add `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` if you want to pull the CSV off the device
with the Files app. Set `recorder.passthrough` to drive a live `PDREngine` from
the same samples while recording.

```sh
swift run pdr-validate template --out reference.csv   # shows the format
```

Running either command without `--log` falls back to synthetic data. **That
exercises the code, not the physics.** `SyntheticWalk` models gait as a few
sinusoids; real accelerometer signals are not sinusoids. Any accuracy number
from synthetic input is a property of that file, and it says so when you run it.

---

## Running it

Nothing here needs a phone until step 3.

```sh
cd IndoorPositioning
swift test                                    # the whole pipeline, offline
swift run pdr-validate                        # usage
swift run pdr-validate drift --distance 100   # synthetic; checks the machinery
```

Then record a real walk (see below), and re-run `drift` and `carriage` against
it. That is the point at which the numbers start meaning something.

## Using it

Add the package, then:

```swift
import PDRCore
import PDRMotion

let map = try JSONDecoder().decode(IndoorMap.self, from: planData)
let session = PDRSession(map: map, source: CoreMotionSource(sampleRate: 50))

session.start(at: map.entryPoints[0])   // a door gives you a heading for free

// SwiftUI
PDRMapView(
    map: map,
    track: session.track,
    deadReckoningTrack: session.deadReckoningTrack,
    fix: session.fix
)
```

Then, when the user scans a marker:

```swift
session.observeAnchor(id: "3F-lobby-qr")
```

`Info.plist` needs `NSMotionUsageDescription`. Nothing else — no location
permission, no Bluetooth, no network.

### Drawing the plan

`IndoorMap` is `Codable`, so a plan is a JSON file:

* `walls` — segments people cannot cross. The hard constraint.
* `corridors` — centre-line polylines with a width. The heading constraint.
* `entryPoints` — doors, with the heading a user necessarily has on entering.
* `anchors` — markers of known position. The reset mechanism.
* `headingOffset` — bearing of the plan's +X axis relative to the sensor
  reference frame. A survey constant of the building; measure it once.

### Reading a fix

`PositionFix` carries both the constrained estimate and the raw dead-reckoning
position. Draw both while tuning: the gap between them is the map constraint
doing its job, and it is the first thing to look at when a walk goes wrong.
`horizontalAccuracy` describes the whole particle cloud, not just the winning
cluster, and `isAmbiguous` is true when a second well-separated hypothesis is
still alive.

---

## Layout

```
Sources/PDRCore/
  Math/         Vector3, Quaternion, filters, seeded RNG
  Sensors/      MotionSample and the frame conventions everything else obeys
  Steps/        StepDetector (peaks, never integrals), StepLengthEstimator
  Heading/      HeadingEstimator, MagnetometerGate, WalkingDirectionEstimator
  Carriage/     CarriageModeClassifier
  Map/          IndoorMap, MapIndex (grid-accelerated wall and corridor queries)
  Filter/       ParticleFilter
  Engine/       PDREngine, PositionFix
  Validation/   MotionLog, SyntheticWalk, DriftExperiment
Sources/PDRMotion/    CoreMotion adapter, replay source, MotionRecorder,
                      PDRSession, PDRMapView
Sources/pdr-validate/ the two experiments as a CLI
```

`PDRCore` is pure Swift with no platform dependencies, so the whole pipeline and
its test suite run anywhere Swift does — which is what makes replaying a
recorded corridor walk in CI possible.

## Known limitations

These are design boundaries, not bugs:

* **A straight corridor cannot resolve forward from backward.** If PCA's sign is
  unresolved on entry, both hypotheses survive until a corner. Reported.
* **The magnetometer is a slow, gated anchor, never a heading source.** Indoors
  it is wrong far more often than it is noisy, and `MagnetometerGate` closes on
  implausible field strength, fast changes, or a dip angle that has moved.
* **Carriage-mode thresholds are unvalidated.** They separate the synthetic
  signatures cleanly, which proves nothing about real users. Experiment 2 is
  what decides them.
* **Bag carriage puts the phone behind you**, so the entry-point sign hint
  points the wrong way. Needs a corner, or a mode-aware hint.
* **Altitude is not modelled.** Single floor only; stairs and lifts need floor
  detection this package does not have.
