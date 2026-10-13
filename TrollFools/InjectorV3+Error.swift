//
//  InjectorV3+Error.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import Foundation

extension InjectorV3 {
    enum Error: LocalizedError {
        case generic(String)

        var errorDescription: String? {
            switch self {
            case let .generic(reason): reason
            }
        }
    }

    /// Throwing replacement for `precondition`. Preconditions also trap in release builds,
    /// which crashed the app when automatic reinjection inspected a bundle that
    /// LaunchServices was still replacing. A thrown error is retried instead.
    func ensure(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) throws {
        guard condition() else {
            throw Error.generic(message())
        }
    }
}
