import SwiftUI
import UniformTypeIdentifiers
import GlitchboxKit

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
        case .int: numericControl(isInt: true)
        case .float: numericControl(isInt: false)
        case .bool:
            Toggle(spec.label, isOn: Binding(get: { value.boolValue ?? false }, set: { onChange(.bool($0)) }))
        case .enumeration:
            Picker(spec.label, selection: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) })) {
                ForEach(spec.options ?? [], id: \.self) { Text(optionTitle($0)).tag($0) }
            }
        case .string:
            TextField(spec.label, text: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) }))
        case .file: fileControl
        }
    }

    private func optionTitle(_ option: String) -> String {
        if spec.labels != nil { return spec.label(forOption: option) }
        return option.contains("/") ? (option as NSString).lastPathComponent : option
    }

    private var number: Double { value.doubleValue ?? 0 }

    private func set(_ d: Double, isInt: Bool) {
        onChange(spec.clamp(isInt ? .int(Int(d.rounded())) : .float(d)))
    }

    @ViewBuilder private func numericControl(isInt: Bool) -> some View {
        LabeledContent(spec.label) {
            HStack {
                if let lo = spec.min, let hi = spec.max, lo < hi {
                    slider(lo: lo, hi: hi, isInt: isInt)
                }
                if isInt {
                    TextField(spec.label, value: Binding(get: { Int(number) }, set: { set(Double($0), isInt: true) }),
                              format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                    if spec.min == nil || spec.max == nil {
                        Stepper(spec.label, value: Binding(get: { Int(number) }, set: { set(Double($0), isInt: true) }))
                            .labelsHidden()
                    }
                } else {
                    TextField(spec.label, value: Binding(get: { number }, set: { set($0, isInt: false) }),
                              format: .number.precision(.significantDigits(1...6)))
                        .labelsHidden()
                        .frame(width: 80)
                }
            }
        }
    }

    @ViewBuilder private func slider(lo: Double, hi: Double, isInt: Bool) -> some View {
        if spec.scale == .log {
            Slider(value: Binding(get: { LogScale.position(of: number, lo: lo, hi: hi) },
                                  set: { set(LogScale.value(at: $0, lo: lo, hi: hi), isInt: isInt) }),
                   in: 0...1)
        } else {
            let binding = Binding(get: { number }, set: { set($0, isInt: isInt) })
            let step = isInt ? 1 : (spec.step ?? (hi - lo) / 100)
            if step > 0, (hi - lo) / step <= Self.maxSliderStops {
                Slider(value: binding, in: lo...hi, step: step)
            } else {
                // A stepped slider materializes every stop (2^31 for a seed).
                Slider(value: binding, in: lo...hi)
            }
        }
    }

    private var fileControl: some View {
        LabeledContent(spec.label) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    let path = value.stringValue ?? ""
                    Text(path.isEmpty ? "None" : path)
                        .foregroundStyle(path.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer()
                    if spec.isOptional, !path.isEmpty {
                        Button("Clear") { onChange(.string("")) }
                    }
                    Button("Choose…") { importing = true }
                }
                if spec.isOptional, (value.stringValue ?? "").isEmpty, let help = spec.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
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
