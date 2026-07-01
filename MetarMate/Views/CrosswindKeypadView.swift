import SwiftUI

enum KeypadField: Int, CaseIterable {
    case runway = 0
    case windDirection = 1
    case windSpeed = 2
    case gust = 3

    var title: String {
        switch self {
        case .runway: return "RWY"
        case .windDirection: return "WIND"
        case .windSpeed: return "SPEED"
        case .gust: return "GUST"
        }
    }

    var color: Color {
        switch self {
        case .runway: return Color(red: 0.94, green: 0.75, blue: 0.25)
        case .windDirection: return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .windSpeed: return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .gust: return Color(red: 1.0, green: 0.58, blue: 0.0)
        }
    }

    var maxDigits: Int {
        switch self {
        case .runway: return 2
        case .windDirection: return 2
        case .windSpeed: return 2
        case .gust: return 2
        }
    }
}

/// Manual crosswind calculator with the XW Calc swipe-to-enter-two-digits keypad. Hosted by
/// CrosswindTabView (the standalone XWind tab), which injects @AppStorage last-used values as
/// bindings. Dumb-and-honest: designator×10 vs the wind AS-TYPED, no true→magnetic conversion
/// (auto crosswind from a METAR lives only in Pilot Notes / RunwayService, which converts).
/// `title` is the second header line ("MANUAL"); a nil `onDone` hides the Done button.
struct CrosswindKeypadView: View {
    @Binding var runway: Int
    @Binding var windDirection: Int
    @Binding var windSpeed: Int
    @Binding var gustSpeed: Int

    let title: String
    var onDone: (() -> Void)? = nil

    @State private var activeField: KeypadField?
    @State private var inputBuffer: String = ""
    @State private var errorMessage: String? = nil
    @State private var shakeOffset: CGFloat = 0
    @State private var dragStartDigit: String? = nil
    @State private var dragCurrentDigit: String? = nil
    @State private var digitFrames: [String: CGRect] = [:]
    @State private var swallowZeroUntil: Date? = nil

    init(runway: Binding<Int>,
         windDirection: Binding<Int>,
         windSpeed: Binding<Int>,
         gustSpeed: Binding<Int>,
         title: String,
         initialActiveField: KeypadField? = .runway,
         onDone: (() -> Void)? = nil) {
        _runway = runway
        _windDirection = windDirection
        _windSpeed = windSpeed
        _gustSpeed = gustSpeed
        self.title = title
        self.onDone = onDone
        _activeField = State(initialValue: initialActiveField)
    }

    private var windDeg: Int { windDirection % 360 }

    /// The runway heading the trig runs off: the designator number ×10. The pilot types the wind
    /// in the same frame they read the runway number (magnetic), so the typed wind is used as-is
    /// against designator×10 — no conversion. (Runway numbers ARE the magnetic heading / 10.)
    private var runwayHeading: Int { runway * 10 }

    private var crosswind: Int {
        let angle = Double(windDeg - runwayHeading) * .pi / 180
        return abs(Int(round(Double(windSpeed) * sin(angle))))
    }

    private var gustCrosswind: Int {
        guard gustSpeed > windSpeed else { return crosswind }
        let angle = Double(windDeg - runwayHeading) * .pi / 180
        return abs(Int(round(Double(gustSpeed) * sin(angle))))
    }

    private var headwind: Int {
        let angle = Double(windDeg - runwayHeading) * .pi / 180
        return Int(round(Double(windSpeed) * cos(angle)))
    }

    private var side: String {
        let diff = ((windDeg - runwayHeading) % 360 + 360) % 360
        if diff > 0 && diff < 180 { return "R" }
        if diff > 180 { return "L" }
        return ""
    }

    /// Crosswind magnitude color on MetarMate's WIND axis only — never the
    /// flight-category/verdict green. Red ≥20 kt, amber ≥15 kt (the project gust
    /// thresholds), neutral below so a benign crosswind reads as informational.
    private static let amber = Color(red: 1.0, green: 0.6, blue: 0.0)
    private static let neutralWind = Color(white: 0.9)
    private var severityColor: Color {
        let xw = gustSpeed > windSpeed ? gustCrosswind : crosswind
        if xw >= 20 { return .red }
        if xw >= 15 { return Self.amber }
        return Self.neutralWind
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 10) {
                CrosswindReadout(
                    crosswind: crosswind,
                    gustCrosswind: gustSpeed > windSpeed ? gustCrosswind : nil,
                    headwind: headwind,
                    side: side,
                    color: severityColor,
                    runway: runway,
                    windDirection: windDirection,
                    windSpeed: windSpeed,
                    gustSpeed: gustSpeed > windSpeed ? gustSpeed : nil,
                    onFlipRunway: {
                        let opposite = (runway + 18) > 36 ? runway + 18 - 36 : runway + 18
                        runway = opposite
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)

                advisoryStrip

                valueBoxGrid
                    .padding(.horizontal, 16)
            }

            keypadSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IsobarBackground())
        .animation(.easeInOut(duration: 0.2), value: activeField)
    }

    // MARK: - Advisory strip (caution wash)

    @ViewBuilder
    private var advisoryStrip: some View {
        let xw = gustSpeed > windSpeed ? gustCrosswind : crosswind
        let gustAdd = (gustSpeed > windSpeed) ? max((gustSpeed - windSpeed + 1) / 2, 0) : 0
        let lines: [String] = {
            var l: [String] = []
            if gustAdd > 0 { l.append("Increase Vref by \(gustAdd) kt") }
            if xw > 10 { l.append("Consider reducing flaps") }
            return l
        }()
        if !lines.isEmpty {
            HStack(alignment: .center, spacing: 13) {
                WeatherFrontTriangle(color: Brand.cautionOrange, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.avenir(idx == 0 ? 14 : 13, idx == 0 ? .bold : .demibold))
                            .foregroundColor(idx == 0 ? Brand.cloud : Brand.fog)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Brand.stripRadius, style: .continuous)
                .fill(LinearGradient(colors: [Brand.advisoryTop, Brand.advisoryBottom],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: Brand.stripRadius, style: .continuous)
                .stroke(Brand.advisoryBorder, lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                TrackedLabel(text: "Crosswind Calc · \(title)", color: Brand.accentOrange,
                             size: 10, tracking: 3.0)
                Text("Runway \(String(format: "%02d", runway))")
                    .font(.avenir(26, .heavy))
                    .foregroundColor(Brand.cloud)
            }
            Spacer()
            if let onDone {
                Button(action: onDone) {
                    Text("Done")
                        .font(.avenir(17, .demibold))
                        .foregroundColor(Brand.accentOrange)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Value Box Grid (2x2)

    private var valueBoxGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                valueBox(field: .runway, displayValue: String(format: "%02d", runway))
                valueBox(field: .windDirection, displayValue: String(format: "%03d°", windDirection))
            }
            HStack(spacing: 10) {
                valueBox(field: .windSpeed, displayValue: "\(windSpeed) kt")
                valueBox(field: .gust, displayValue: gustSpeed > windSpeed ? "\(gustSpeed) kt" : "— kt")
            }
        }
    }

    private func valueBox(field: KeypadField, displayValue: String) -> some View {
        let isActive = activeField == field
        let labelColor = isActive ? Brand.accentOrange : Brand.slate
        let valueColor: Color = field == .gust ? Brand.cautionOrange : Brand.cloud

        return Button(action: {
            activeField = (activeField == field) ? nil : field
            inputBuffer = ""
            errorMessage = nil
        }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.title)
                    .font(.avenir(9.5, .heavy))
                    .tracking(1.8)
                    .foregroundColor(labelColor)

                if isActive {
                    Text(inputBuffer.isEmpty ? displayValue : inputBuffer)
                        .font(.brandMono(22, weight: .bold))
                        .foregroundColor(inputBuffer.isEmpty ? Brand.cloud.opacity(0.4) : valueColor)
                        .offset(x: shakeOffset)
                } else {
                    Text(displayValue)
                        .font(.brandMono(22, weight: .bold))
                        .foregroundColor(valueColor)
                }

                if isActive, let error = errorMessage {
                    Text(error)
                        .font(.brandMono(10, weight: .bold))
                        .foregroundColor(Brand.valueRed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 56)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: Brand.stripRadius, style: .continuous)
                    .fill(isActive ? Brand.accentOrange.opacity(0.08) : Brand.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.stripRadius, style: .continuous)
                            .stroke(isActive ? Brand.accentOrange : Brand.cardBorder,
                                    lineWidth: isActive ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keypad Section

    private let digitLayout: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"]
    ]

    private var keypadSection: some View {
        let coordSpace = "keypadGrid"

        return VStack(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(0..<digitLayout.count, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<digitLayout[row].count, id: \.self) { col in
                            let digit = digitLayout[row][col]
                            dragDigitCell(digit: digit, coordSpace: coordSpace)
                        }
                    }
                }

                HStack(spacing: 8) {
                    backspaceButton
                    dragDigitCell(digit: "0", coordSpace: coordSpace)
                    enterButton
                }
            }
            .coordinateSpace(name: coordSpace)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
                    .onChanged { value in
                        let hitDigit = digitAtPoint(value.location)

                        if dragStartDigit == nil {
                            if let digit = digitAtPoint(value.startLocation), isDigitEnabled(digit) {
                                dragStartDigit = digit
                                dragCurrentDigit = digit
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } else if let hit = hitDigit, hit != dragCurrentDigit {
                            dragCurrentDigit = hit
                            if hit != dragStartDigit {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                    .onEnded { _ in
                        guard let startDigit = dragStartDigit else {
                            resetDragState()
                            return
                        }

                        let endDigit = dragCurrentDigit

                        if let end = endDigit, end != startDigit {
                            inputBuffer = startDigit
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                inputBuffer += end
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if let field = activeField, inputBuffer.count == field.maxDigits {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        validateAndApply()
                                    }
                                }
                            }
                        } else {
                            digitPressed(startDigit)
                        }

                        resetDragState()
                    }
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
            // Clear the iOS 26 floating tab bar so the bottom key row never underlaps it.
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
    }

    private func dragDigitCell(digit: String, coordSpace: String) -> some View {
        let enabled = isDigitEnabled(digit)
        let isStart = dragStartDigit == digit
        let isCurrent = dragCurrentDigit == digit && dragStartDigit != nil && dragCurrentDigit != dragStartDigit

        let highlight = isStart || isCurrent
        return Text(digit)
            .font(.brandMono(21, weight: .semibold))
            .foregroundColor(!enabled ? Brand.cloud.opacity(0.25)
                             : (highlight ? Brand.accentOrange : Brand.cloud))
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
            .background(
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(highlight ? Brand.accentOrange.opacity(0.18) : Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(highlight ? Brand.accentOrange.opacity(0.6) : Brand.cardBorder, lineWidth: 1)
                        )
                        .onAppear {
                            DispatchQueue.main.async {
                                digitFrames[digit] = geo.frame(in: .named(coordSpace))
                            }
                        }
                        .onChange(of: geo.frame(in: .named(coordSpace))) {
                            digitFrames[digit] = geo.frame(in: .named(coordSpace))
                        }
                }
            )
    }

    private func digitAtPoint(_ point: CGPoint) -> String? {
        for (digit, frame) in digitFrames {
            if frame.contains(point) { return digit }
        }
        return nil
    }

    private func resetDragState() {
        dragStartDigit = nil
        dragCurrentDigit = nil
    }

    private var backspaceButton: some View {
        Button(action: { backspacePressed() }) {
            Image(systemName: "delete.left")
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(inputBuffer.isEmpty ? Brand.slate.opacity(0.5) : Brand.slate)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.02))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Brand.cardBorder, lineWidth: 1))
                )
        }
        .disabled(inputBuffer.isEmpty)
    }

    private var enterButton: some View {
        let field = activeField
        let isGustField = field == .gust
        let hasInput = !inputBuffer.isEmpty
        let noneAvailable = isGustField && !hasInput

        return Button(action: {
            if hasInput {
                validateAndApply()
            } else if isGustField {
                gustSpeed = windSpeed
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                activeField = nil
                inputBuffer = ""
            }
        }) {
            Text(hasInput ? "OK" : (isGustField ? "NONE" : "OK"))
                .font(.avenir(16, .heavy))
                .tracking(0.6)
                .foregroundColor(Brand.navy)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Brand.accentOrange)
                )
        }
        .opacity(noneAvailable ? 0.9 : 1)
    }

    // MARK: - Input Logic

    private func isDigitEnabled(_ digit: String) -> Bool {
        guard let field = activeField, let d = Int(digit) else { return false }

        switch field {
        case .runway, .windDirection:
            if inputBuffer.isEmpty {
                return d >= 1
            }
            if inputBuffer.count == 1 {
                guard let first = Int(inputBuffer) else { return true }
                if first <= 2 { return true }
                if first == 3 { return d <= 6 }
                return true
            }
            return false

        case .windSpeed, .gust:
            if inputBuffer.count >= 2 { return false }
            return true
        }
    }

    private func digitPressed(_ digit: String) {
        guard let field = activeField else { return }
        errorMessage = nil

        if digit == "0", let until = swallowZeroUntil, Date() < until {
            swallowZeroUntil = nil
            return
        }
        swallowZeroUntil = nil

        guard inputBuffer.count < field.maxDigits else { return }
        guard isDigitEnabled(digit) else { return }

        guard let d = Int(digit) else { return }

        if (field == .runway || field == .windDirection) && inputBuffer.isEmpty && d >= 4 {
            inputBuffer = "0" + digit
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                validateAndApply()
            }
            return
        }

        inputBuffer += digit
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if inputBuffer.count == field.maxDigits {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                validateAndApply()
            }
        }
    }

    private func backspacePressed() {
        guard !inputBuffer.isEmpty else { return }
        inputBuffer.removeLast()
        errorMessage = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func validateAndApply() {
        guard let field = activeField, let val = Int(inputBuffer) else {
            showError("Invalid")
            return
        }

        switch field {
        case .runway:
            if val < 1 || val > 36 {
                showError("01–36")
                return
            }
            runway = val

        case .windDirection:
            if val < 1 || val > 36 {
                showError("01–36")
                return
            }
            windDirection = val * 10

        case .windSpeed:
            if val > 99 {
                showError("0–99")
                return
            }
            windSpeed = val
            if gustSpeed < val { gustSpeed = val }

        case .gust:
            if val < windSpeed {
                showError("≥ \(windSpeed)")
                return
            }
            gustSpeed = val
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        inputBuffer = ""
        errorMessage = nil
        swallowZeroUntil = Date().addingTimeInterval(0.3)

        if let next = KeypadField(rawValue: field.rawValue + 1) {
            activeField = next
        } else {
            activeField = nil
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        inputBuffer = ""
        withAnimation(.default) { shakeOffset = 12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 6 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.default) { shakeOffset = 0 }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
