//
//  CoreLocationBridge.swift
//  PDRMotion
//

import Foundation
import PDRCore

#if canImport(CoreLocation)
import CoreLocation

public extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public extension GeoAnchor {
    static func here(_ coordinate: CLLocationCoordinate2D, walkingBearing: Double) -> GeoAnchor {
        here(GeoCoordinate(coordinate), walkingBearing: walkingBearing)
    }
}

#if canImport(Combine)

public extension PDRSession {
    /// Starts from a CoreLocation fix, with the +X axis along the direction the
    /// user is about to walk.
    ///
    /// - Parameter walkingBearingDegrees: true bearing, degrees clockwise from
    ///   north — the sense `CLHeading.trueHeading` and `CLLocation.course` both
    ///   use. Pass the phone's heading only if the phone is pointing the way the
    ///   user walks; otherwise the walking-direction estimator sorts it out
    ///   within a couple of steps.
    func start(
        at coordinate: CLLocationCoordinate2D,
        walkingBearingDegrees: Double
    ) {
        start(
            at: GeoCoordinate(coordinate),
            walkingBearing: walkingBearingDegrees * .pi / 180
        )
    }

    /// The current estimate, ready to hand to a `Map` annotation.
    var clCoordinate: CLLocationCoordinate2D? { coordinate?.clCoordinate }

    /// The unconstrained dead-reckoning estimate.
    var deadReckoningCLCoordinate: CLLocationCoordinate2D? {
        deadReckoningCoordinate?.clCoordinate
    }

    /// The estimate's trail, ready for a `MapPolyline`.
    var clCoordinateTrack: [CLLocationCoordinate2D] {
        coordinateTrack.map(\.clCoordinate)
    }
}

#endif
#endif
