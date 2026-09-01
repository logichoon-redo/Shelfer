//
//  MotionLog.swift
//  PDRCore
//

import Foundation

/// CSV recording of an IMU session.
///
/// The point of this file is that the corridor experiments have to be run
/// **once** and then replayed a hundred times. Tuning a step detector by
/// walking the corridor again after every parameter change is how a two-day
/// investigation becomes a two-week one.
///
/// Column order (empty means the sensor gave nothing for that sample):
///
///     time, ax, ay, az, gx, gy, gz, rx, ry, rz, qw, qx, qy, qz, mx, my, mz, macc
///
/// * `a*`  user acceleration, device frame, m/s²
/// * `g*`  gravity, device frame, m/s²
/// * `r*`  rotation rate, device frame, rad/s
/// * `q*`  attitude quaternion, device to reference
/// * `m*`  calibrated magnetic field, device frame, µT
/// * `macc` platform magnetic-field accuracy, negative meaning uncalibrated
public enum MotionLog {
    public static let header =
        "time,ax,ay,az,gx,gy,gz,rx,ry,rz,qw,qx,qy,qz,mx,my,mz,macc"

    public static func csv(from samples: [MotionSample]) -> String {
        var lines: [String] = [header]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples { lines.append(row(for: sample)) }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func row(for sample: MotionSample) -> String {
        var fields: [String] = [
            format(sample.timestamp),
            format(sample.userAcceleration.x),
            format(sample.userAcceleration.y),
            format(sample.userAcceleration.z),
            format(sample.gravity.x),
            format(sample.gravity.y),
            format(sample.gravity.z),
            format(sample.rotationRate.x),
            format(sample.rotationRate.y),
            format(sample.rotationRate.z),
        ]
        if let attitude = sample.attitude {
            fields.append(contentsOf: [
                format(attitude.w), format(attitude.x), format(attitude.y), format(attitude.z),
            ])
        } else {
            fields.append(contentsOf: ["", "", "", ""])
        }
        if let field = sample.magneticField {
            fields.append(contentsOf: [format(field.x), format(field.y), format(field.z)])
        } else {
            fields.append(contentsOf: ["", "", ""])
        }
        fields.append(sample.magneticFieldAccuracy.map(String.init) ?? "")
        return fields.joined(separator: ",")
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missingHeader
        case badRow(line: Int, reason: String)

        public var description: String {
            switch self {
            case .missingHeader:
                return "log is empty or has no header row"
            case let .badRow(line, reason):
                return "line \(line): \(reason)"
            }
        }
    }

    public static func parse(csv: String) throws -> [MotionSample] {
        var lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ParseError.missingHeader }
        if lines[0].hasPrefix("time") { lines.removeFirst() }

        var samples: [MotionSample] = []
        samples.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 10 else {
                throw ParseError.badRow(line: offset + 2, reason: "expected at least 10 columns, got \(fields.count)")
            }
            guard let time = Double(fields[0]) else {
                throw ParseError.badRow(line: offset + 2, reason: "unparsable timestamp \"\(fields[0])\"")
            }

            func value(_ index: Int) throws -> Double {
                guard index < fields.count, let parsed = Double(fields[index]) else {
                    throw ParseError.badRow(line: offset + 2, reason: "unparsable number in column \(index + 1)")
                }
                return parsed
            }

            func optionalVector(_ start: Int) -> Vector3? {
                guard start + 2 < fields.count else { return nil }
                guard let x = Double(fields[start]),
                      let y = Double(fields[start + 1]),
                      let z = Double(fields[start + 2]) else { return nil }
                return Vector3(x, y, z)
            }

            var attitude: Quaternion?
            if fields.count > 13,
               let w = Double(fields[10]), let x = Double(fields[11]),
               let y = Double(fields[12]), let z = Double(fields[13]) {
                attitude = Quaternion(w: w, x: x, y: y, z: z).normalized()
            }

            let accuracy = fields.count > 17 ? Int(fields[17]) : nil

            samples.append(
                MotionSample(
                    timestamp: time,
                    userAcceleration: Vector3(try value(1), try value(2), try value(3)),
                    gravity: Vector3(try value(4), try value(5), try value(6)),
                    rotationRate: Vector3(try value(7), try value(8), try value(9)),
                    attitude: attitude,
                    magneticField: optionalVector(14),
                    magneticFieldAccuracy: accuracy
                )
            )
        }
        return samples
    }

    public static func write(_ samples: [MotionSample], to url: URL) throws {
        try csv(from: samples).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func read(from url: URL) throws -> [MotionSample] {
        try parse(csv: String(contentsOf: url, encoding: .utf8))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
