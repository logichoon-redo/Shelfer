//
//  main.swift
//  pdr-validate
//
//  Runs the two measurements that decide whether step-counting PDR is viable
//  in a given building, and how much marker infrastructure it needs.
//

import Foundation
import PDRCore

// MARK: - Argument parsing
//
// Hand-rolled rather than swift-argument-parser: this package has no external
// dependencies, which is what lets it be dropped into an app target without
// touching its package graph.

struct Arguments {
    var command: String
    var values: [String: String]
    var flags: Set<String>

    func string(_ key: String) -> String? { values[key] }

    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }

    func requireDouble(_ key: String) -> Double {
        guard let value = double(key) else {
            fail("missing or unparsable --\(key)")
        }
        return value
    }

    static func parse(_ arguments: [String]) -> Arguments {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var command = "help"
        var index = 0

        if index < arguments.count, !arguments[index].hasPrefix("--") {
            command = arguments[index]
            index += 1
        }

        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let key = String(token.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
        return Arguments(command: command, values: values, flags: flags)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func loadSamples(_ path: String) -> [MotionSample] {
    let url = URL(fileURLWithPath: path)
    do {
        return try MotionLog.read(from: url)
    } catch {
        fail("could not read \(path): \(error)")
    }
}

// MARK: - Shared map

/// A straight corridor of the requested length, walls either side.
///
/// Enough to exercise the constraint on a straight-line drift walk. Replace it
/// with the real plan before drawing conclusions about a real building.
func straightCorridor(length: Double, width: Double = 2.4) -> IndoorMap {
    let half = width / 2
    return IndoorMap(
        name: "straight corridor",
        walls: [
            Segment(-2, half, length + 2, half),
            Segment(-2, -half, length + 2, -half),
        ],
        corridors: [
            Corridor(
                id: "main",
                polyline: [Point2D(x: -2, y: 0), Point2D(x: length + 2, y: 0)],
                width: width
            )
        ],
        entryPoints: [
            MapEntryPoint(id: "start", position: .zero, heading: 0)
        ]
    )
}

func syntheticSamples(
    mode: CarriageMode,
    distance: Double,
    driftDegreesPerMinute: Double
) -> (samples: [MotionSample], truthDistance: Double, end: Point2D) {
    var configuration = SyntheticWalk.Configuration()
    configuration.path = [Point2D(x: 0, y: 0), Point2D(x: distance, y: 0)]
    configuration.mode = mode
    configuration.attitudeDriftRate = Angle.degrees(driftDegreesPerMinute) / 60
    let walk = SyntheticWalk.generate(configuration)
    let end = walk.truthPositions.last ?? Point2D(x: distance, y: 0)
    return (walk.samples, walk.truthDistance, end)
}

// MARK: - Commands

func runDrift(_ arguments: Arguments) {
    let tolerance = arguments.double("tolerance") ?? 5.0
    let useMap = arguments.flags.contains("with-map")

    let samples: [MotionSample]
    let truthDistance: Double
    let end: Point2D

    if let logPath = arguments.string("log") {
        samples = loadSamples(logPath)
        truthDistance = arguments.requireDouble("distance")
        end = Point2D(x: arguments.double("end-x") ?? truthDistance,
                      y: arguments.double("end-y") ?? 0)
    } else {
        let distance = arguments.double("distance") ?? 100
        let drift = arguments.double("drift-deg-per-min") ?? 2.0
        let mode = CarriageMode(rawValue: arguments.string("mode") ?? "handheldSteady")
            ?? .handheldSteady
        print("""
        No --log given, so this is running on synthetic data.
        Synthetic input exercises the pipeline, not the physics: it cannot tell
        you how this behaves in your building. Record a real walk and pass
        --log to get numbers worth acting on.

        """)
        let generated = syntheticSamples(
            mode: mode, distance: distance, driftDegreesPerMinute: drift
        )
        samples = generated.samples
        truthDistance = generated.truthDistance
        end = generated.end
    }

    guard !samples.isEmpty else { fail("no samples to run") }

    let result = DriftExperiment.run(
        DriftExperiment.Setup(
            label: "pure PDR, \(Int(truthDistance.rounded())) m straight",
            samples: samples,
            truthStart: .zero,
            truthEnd: end,
            truthStartHeading: 0,
            truthPathLength: truthDistance,
            map: useMap ? straightCorridor(length: truthDistance) : nil
        )
    )

    print(result.summary(tolerance: tolerance))
    print("""

    How to read this
      along-track error is the stride model; fix it by calibrating.
      lateral error is heading; it is the one that keeps growing, and the one
      the corridor constraint exists to attack.
      the anchor spacing line is the answer to "how many markers do we print".
    """)
}

func runCarriage(_ arguments: Arguments) {
    let distance = arguments.double("distance") ?? 100

    let handSamples: [MotionSample]
    let pocketSamples: [MotionSample]
    var handDistance = distance
    var pocketDistance = distance
    var handEnd = Point2D(x: distance, y: 0)
    var pocketEnd = Point2D(x: distance, y: 0)

    if let handPath = arguments.string("hand"), let pocketPath = arguments.string("pocket") {
        handSamples = loadSamples(handPath)
        pocketSamples = loadSamples(pocketPath)
        handDistance = arguments.requireDouble("distance")
        pocketDistance = handDistance
        handEnd = Point2D(x: arguments.double("end-x") ?? handDistance,
                          y: arguments.double("end-y") ?? 0)
        pocketEnd = handEnd
    } else {
        print("""
        No --hand/--pocket logs given, so this is running on synthetic data and
        is only checking that the comparison machinery works. The real answer
        needs the same corridor walked twice.

        """)
        let hand = syntheticSamples(mode: .handheldSteady, distance: distance, driftDegreesPerMinute: 2)
        let pocket = syntheticSamples(mode: .pocket, distance: distance, driftDegreesPerMinute: 2)
        handSamples = hand.samples
        pocketSamples = pocket.samples
        handDistance = hand.truthDistance
        pocketDistance = pocket.truthDistance
        handEnd = hand.end
        pocketEnd = pocket.end
    }

    let comparison = DriftExperiment.compareCarriage(
        hand: DriftExperiment.Setup(
            label: "hand",
            samples: handSamples,
            truthStart: .zero,
            truthEnd: handEnd,
            truthStartHeading: 0,
            truthPathLength: handDistance
        ),
        pocket: DriftExperiment.Setup(
            label: "pocket",
            samples: pocketSamples,
            truthStart: .zero,
            truthEnd: pocketEnd,
            truthStartHeading: 0,
            truthPathLength: pocketDistance
        )
    )

    print(comparison.hand.summary())
    print("")
    print(comparison.pocket.summary())
    print("")
    print(comparison.summary)
}

func runRecordTemplate(_ arguments: Arguments) {
    let distance = arguments.double("distance") ?? 100
    let mode = CarriageMode(rawValue: arguments.string("mode") ?? "handheldSteady") ?? .handheldSteady
    let output = arguments.string("out") ?? "walk.csv"

    let generated = syntheticSamples(mode: mode, distance: distance, driftDegreesPerMinute: 2)
    do {
        try MotionLog.write(generated.samples, to: URL(fileURLWithPath: output))
        print("wrote \(generated.samples.count) synthetic samples to \(output)")
        print("replace this file with a real recording in the same format before trusting any result")
    } catch {
        fail("could not write \(output): \(error)")
    }
}

let usage = """
pdr-validate — measure what step-counting PDR actually does in your building

COMMANDS
  drift      Experiment 1: how far pure PDR drifts over a straight walk, and
             therefore how far apart the reset markers have to be.
  carriage   Experiment 2: hand versus pocket, and whether a carriage-mode
             classifier belongs in the MVP.
  template   Write a synthetic log in the recording format, as a reference for
             the on-device recorder.

OPTIONS
  --log PATH               recorded walk, MotionLog CSV
  --distance METRES        surveyed path length (required with --log)
  --end-x, --end-y         surveyed end point, map frame (default: straight)
  --with-map               also run the corridor-constrained filter
  --tolerance METRES       accuracy to hold when sizing anchor spacing (5)
  --mode NAME              synthetic carriage mode
  --hand PATH --pocket PATH   two recordings for the carriage comparison
  --drift-deg-per-min N    synthetic heading drift (2)
  --out PATH               output path for `template`

MEASURE, DO NOT GUESS
  Walk a surveyed straight line of about 100 m, recording as you go, once with
  the phone in your hand and once in a pocket. Those two recordings answer both
  questions, and the second one decides how much of the MVP the carriage-mode
  problem takes.
"""

let arguments = Arguments.parse(Array(CommandLine.arguments.dropFirst()))
switch arguments.command {
case "drift":
    runDrift(arguments)
case "carriage":
    runCarriage(arguments)
case "template":
    runRecordTemplate(arguments)
default:
    print(usage)
}
