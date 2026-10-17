import SwiftUI
import UniformTypeIdentifiers
import VideobedKit

/// One editor control for a plugin parameter, chosen by its type.
struct ParamControl: View {
    let spec: ParamSpec
    let value: ParamValue
    let onChange: (ParamValue) -> Void

    /// Stepped sliders allocate one entry per stop; larger ranges slide continuously.
    private static let maxSliderStops = 1000.0

    @Environment(StudioModel.self) private var model
    @State private var importing = false

    var body: some View {
        control.help(spec.help ?? "")
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case .int: intControl
        case .float: floatControl
        case .bool:
            Toggle(spec.label, isOn: Binding(get: { value.boolValue ?? false }, set: { onChange(.bool($0)) }))
        case .enumeration:
            Picker(spec.label, selection: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) })) {
                ForEach(spec.options ?? [], id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
            }
        case .string:
            TextField(spec.label, text: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) }))
        case .file: fileControl
        }
    }

    private var intValue: Binding<Int> {
        Binding(get: { Int(value.doubleValue ?? 0) }, set: { onChange(spec.clamp(.int($0))) })
    }

    private var doubleValue: Binding<Double> {
        Binding(get: { value.doubleValue ?? 0 }, set: { onChange(spec.clamp(.float($0))) })
    }

    @ViewBuilder private var intControl: some View {
        if let lo = spec.min, let hi = spec.max, lo < hi {
            LabeledContent(spec.label) {
                HStack {
                    let value = Binding(get: { Double(intValue.wrappedValue) }, set: { intValue.wrappedValue = Int($0.rounded()) })
                    if hi - lo <= Self.maxSliderStops {
                        Slider(value: value, in: lo...hi, step: 1)
                    } else {
                        // A stepped slider materializes every stop (2^31 for a seed).
                        Slider(value: value, in: lo...hi)
                    }
                    TextField(spec.label, value: intValue, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                }
            }
        } else {
            LabeledContent(spec.label) {
                HStack {
                    TextField(spec.label, value: intValue, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                    Stepper(spec.label, value: intValue).labelsHidden()
                }
            }
        }
    }

    @ViewBuilder private var floatControl: some View {
        LabeledContent(spec.label) {
            HStack {
                if let lo = spec.min, let hi = spec.max, lo < hi {
                    let step = spec.step ?? (hi - lo) / 100
                    if step > 0, (hi - lo) / step <= Self.maxSliderStops {
                        Slider(value: doubleValue, in: lo...hi, step: step)
                    } else {
                        Slider(value: doubleValue, in: lo...hi)
                    }
                }
                TextField(spec.label, value: doubleValue, format: .number.precision(.fractionLength(0...4)))
                    .labelsHidden()
                    .frame(width: 80)
            }
        }
    }

    private var fileControl: some View {
        LabeledContent(spec.label) {
            HStack {
                let path = value.stringValue ?? ""
                Text(path.isEmpty ? "None" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer()
                Button("Choose…") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: contentTypes) { result in
            if case .success(let url) = result { onChange(.string(model.workspace.storedFileValue(url))) }
        }
    }

    private var contentTypes: [UTType] {
        let types = (spec.extensions ?? []).compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }
}
