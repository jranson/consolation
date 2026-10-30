//
//  ValueStepper.swift
//  Consolation
//

import SwiftUI

/// A labeled numeric setting: a Stepper where the platform has one, a picker of steps on tvOS (no Stepper there).
struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let format: (Int) -> String

    var body: some View {
        #if os(tvOS)
        Picker(title, selection: $value) {
            ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { item in
                Text(format(item)).tag(item)
            }
        }
        #else
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title, value: format(value))
        }
        #endif
    }
}
