import SwiftUI

enum KeypadField: Int, CaseIterable {
    case runway = 0
    case windDirection = 1
    case windSpeed = 2
    case gust = 3

    var title: String {
        switch self {
        case .runway: return "RWY"
        case .windDirection: return "DIR"
        case .windSpeed: return "SPEED"
        case .gust: return "GUST"
        }
    }

    var maxDigits: Int { 2 }
}

/// Crosswind calculator — the 8A/8B design. A big glanceable readout stays pinned on top;
/// the bottom entry zone is a state machine that **toggles** between a plain-tap numeric
/// keypad (8A, `activeField != nil`) and the result diagram (8B, `activeField == nil`).
/// Tapping any of the four data fields (RWY / DIR / SPEED / GUST) flips back to the keypad
/// with that field active; DONE commits and flips to the diagram. Wind direction snaps to
/// tens of degrees (METAR convention — 120°, never 123°). Values persist across sessions
/// via @AppStorage in the hosting CrosswindTabView. First field active on open so digits
/// can be thumbed immediately from cold.
struct CrosswindKeypadView: View {
    @Binding var runway: Int
    @Binding var windDirection: Int
    @Binding var windSpeed: Int
    @Binding var gustSpeed: Int

    @State private var activeField: KeypadField? = .runway
    @State private var inputBuffer: String = ""
    @State private var errorMessage: String? = nil
    @State private var shakeOffset: CGFloat = 0

    // Drag-to-enter-two-digits: dragging from one key to another types both at once
    // (tapping still enters one). A tap is just a zero-distance drag on the same key.
    @State private var dragStartDigit: String? = nil
    @State private var dragCurrentDigit: String? = nil
    @State private var digitFrames: [String: CGRect] = [:]
    @State private var swallowZeroUntil: Date? = nil
    private let keypadSpace = "keypadGrid"

    // MARK: - Derived wind math (all off the tens-rounded direction so the readout,
    // the diagram, and the recap all agree on one displayed bearing).

    /// Wind direction snapped to the nearest ten (METAR convention). 360 for north.
    private var dir: Int {
        let d = (((windDirection % 360) + 5) / 10 * 10) % 360
        return d == 0 ? 360 : d
    }
    private var runwayHeading: Int { runway * 10 }
    private var angleRad: Double { Double(dir - runwayHeading) * .pi / 180 }

    private var crosswind: Int { abs(Int(round(Double(windSpeed) * sin(angleRad)))) }
    private var gustCrosswind: Int {
        guard gustSpeed > windSpeed else { return crosswind }
        return abs(Int(round(Double(gustSpeed) * sin(angleRad))))
    }
    private var headwind: Int { Int(round(Double(windSpeed) * cos(angleRad))) }
    private var isTailwind: Bool { headwind < 0 }

    private var side: String {
        let diff = ((dir - runwayHeading) % 360 + 360) % 360
        if diff > 0 && diff < 180 { return "R" }
        if diff > 180 { return "L" }
        return ""
    }
    private var sideRight: Bool { side != "L" }
    private var reciprocal: Int { runway > 18 ? runway - 18 : runway + 18 }
    private var hasGust: Bool { gustSpeed > windSpeed }
    private var windRecap: String {
        "RWY \(String(format: "%02d", runway)) · \(String(format: "%03d", dir))@\(windSpeed)\(hasGust ? "G\(gustSpeed)" : "")"
    }

    var body: some View {
        // Background ignores safe area (full-bleed navy + isobars); content stays inside
        // the safe area. A ZStack keeps the two independent — a plain `.background()` here
        // pulls the flexible content up under the status bar.
        ZStack(alignment: .top) {
            IsobarBackground()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: activeField)
        // This screen is deliberately fixed / no-scroll (glanceable in turbulence), so cap
        // Dynamic Type here rather than let large sizes push the keypad off the bottom.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header

            CrosswindReadout(
                crosswind: crosswind,
                gustCrosswind: hasGust ? gustCrosswind : nil,
                headwind: headwind,
                side: side,
                runway: runway,
                windDirDisplay: dir,
                windSpeed: windSpeed,
                gustSpeed: hasGust ? gustSpeed : nil,
                onFlipRunway: flipRunway
            )
            .padding(.top, 14)

            advisoryStrip
                .padding(.top, 12)

            Spacer(minLength: 12)

            entryBlock
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            TrackedLabel(text: "Crosswind Calc", color: Brand.accentOrange, size: 10, tracking: 3.2)
            Text("Runway \(String(format: "%02d", runway))")
                .font(.avenir(24, .heavy))
                .foregroundColor(Brand.cloud)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    // MARK: - Advisory strip (caution wash, or red on a tailwind — grows to fit)

    @ViewBuilder
    private var advisoryStrip: some View {
        if isTailwind {
            advisoryCard(border: Brand.dangerRed.opacity(0.35), radius: 15,
                         fill: [Brand.dangerRed.opacity(0.10), Brand.dangerRed.opacity(0.02)],
                         triangle: Brand.dangerRed) {
                Text("Downwind landing — reconsider runway")
                    .font(.avenir(15, .bold)).foregroundColor(Brand.valueRed)
                Text("Tailwind exceeds typical 10 kt limit")
                    .font(.avenir(13, .demibold)).foregroundColor(Brand.slate)
            }
        } else {
            let gustAdd = hasGust ? max((gustSpeed - windSpeed + 1) / 2, 1) : 0
            let xw = hasGust ? gustCrosswind : crosswind
            let lines = cautionLines(gustAdd: gustAdd, xw: xw)
            if !lines.isEmpty {
                advisoryCard(border: Brand.advisoryBorder, radius: Brand.stripRadius,
                             fill: [Brand.advisoryTop, Brand.advisoryBottom],
                             triangle: Brand.cautionOrange) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.avenir(idx == 0 ? 15 : 14, idx == 0 ? .bold : .demibold))
                            .foregroundColor(idx == 0 ? Brand.cloud : Brand.slate)
                    }
                }
            }
        }
    }

    private func cautionLines(gustAdd: Int, xw: Int) -> [String] {
        var l: [String] = []
        if gustAdd > 0 { l.append("Increase Vref by \(gustAdd) kt") }
        if xw > 10 { l.append("Consider reducing flaps") }
        return l
    }

    private func advisoryCard<Content: View>(border: Color, radius: CGFloat, fill: [Color],
                                             triangle: Color,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            WeatherFrontTriangle(color: triangle, size: 13)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) { content() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(border, lineWidth: 1))
        .padding(.horizontal, 18)
    }

    // MARK: - Entry block (pinned to bottom): 4 fields + keypad/diagram toggle

    private var entryBlock: some View {
        VStack(spacing: 10) {
            fieldRow.padding(.horizontal, 18)
            bottomZone
        }
        .padding(.bottom, 24)   // clear the floating tab bar
    }

    private var fieldRow: some View {
        HStack(spacing: 8) {
            dataField(.runway)
            dataField(.windDirection)
            dataField(.windSpeed)
            dataField(.gust)
        }
    }

    private func fieldDisplay(_ field: KeypadField) -> String {
        switch field {
        case .runway:        return String(format: "%02d", runway)
        case .windDirection: return String(format: "%03d°", dir)
        case .windSpeed:     return "\(windSpeed)"
        case .gust:          return hasGust ? "\(gustSpeed)" : "—"
        }
    }

    private func dataField(_ field: KeypadField) -> some View {
        let isActive = activeField == field
        let valueColor: Color = field == .gust ? Brand.cautionOrange
            : (field == .windDirection ? Brand.fog : Brand.cloud)

        return Button(action: {
            activeField = field
            inputBuffer = ""
            errorMessage = nil
        }) {
            VStack(spacing: 3) {
                Text(field.title)
                    .font(.avenir(9, .heavy))
                    .tracking(1.3)
                    .foregroundColor(isActive ? Brand.accentOrange : Brand.slate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 1) {
                    Text(isActive && !inputBuffer.isEmpty ? inputBuffer : fieldDisplay(field))
                        .font(.brandMono(19, weight: .bold))
                        .foregroundColor(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if isActive { BlinkingCaret() }
                }
                .offset(x: isActive ? shakeOffset : 0)

                if isActive, let error = errorMessage {
                    Text(error)
                        .font(.brandMono(9, weight: .bold))
                        .foregroundColor(Brand.valueRed)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isActive ? Brand.accentOrange.opacity(0.10) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isActive ? Brand.accentOrange : Brand.cardBorder,
                        lineWidth: isActive ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Fixed height for the swap zone so the readout and data fields never move when the
    /// keypad and the result diagram trade places. Sized to fit the diagram + caption and
    /// kept tight so the whole screen fits (no scroll) even in the tallest tailwind state.
    private let zoneHeight: CGFloat = 246

    @ViewBuilder
    private var bottomZone: some View {
        Group {
            if activeField != nil {
                keypad.padding(.horizontal, 18)
            } else {
                VStack(spacing: 2) {
                    CrosswindDiagramView(
                        runwayIdent: String(format: "%02d", runway),
                        reciprocalIdent: String(format: "%02d", reciprocal),
                        windDirDeg: dir,
                        runwayHeadingDeg: runwayHeading,
                        crosswind: crosswind,
                        headwind: headwind,
                        sideRight: sideRight
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { flipRunway() }
                    if !isTailwind {
                        Text(windRecap)
                            .font(.brandMono(12, weight: .medium))
                            .foregroundColor(Brand.monoDim2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: zoneHeight, alignment: .top)
    }

    /// Reverse to the reciprocal runway (07 ⇄ 25). RWY rarely changes mid-approach, so a
    /// tap on the readout or diagram is enough — no draggable control.
    private func flipRunway() {
        runway = (runway + 18) > 36 ? runway + 18 - 36 : runway + 18
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Keypad (3×4 — tap for one digit, drag between keys for two)

    private let digitLayout: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    private var keypad: some View {
        VStack(spacing: 8) {
            ForEach(0..<digitLayout.count, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(digitLayout[row], id: \.self) { digit in
                        dragDigitCell(digit)
                    }
                }
            }
            HStack(spacing: 8) {
                backspaceKey
                dragDigitCell("0")
                doneKey
            }
        }
        .coordinateSpace(name: keypadSpace)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(keypadSpace))
                .onChanged { value in
                    let hit = digitAtPoint(value.location)
                    if dragStartDigit == nil {
                        if let d = digitAtPoint(value.startLocation), isDigitEnabled(d) {
                            dragStartDigit = d
                            dragCurrentDigit = d
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    } else if let h = hit, h != dragCurrentDigit {
                        dragCurrentDigit = h
                        if h != dragStartDigit { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    }
                }
                .onEnded { _ in
                    defer { resetDragState() }
                    guard let start = dragStartDigit else { return }
                    if let end = dragCurrentDigit, end != start {
                        // Drag across two keys → type both digits, then commit.
                        inputBuffer = start
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            inputBuffer += end
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if let field = activeField, inputBuffer.count == field.maxDigits {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    commitCurrentField(advance: true)
                                }
                            }
                        }
                    } else {
                        digitPressed(start)   // zero-distance drag == a tap
                    }
                }
        )
    }

    private func dragDigitCell(_ digit: String) -> some View {
        let enabled = isDigitEnabled(digit)
        let highlight = (dragStartDigit == digit)
            || (dragCurrentDigit == digit && dragStartDigit != nil && dragCurrentDigit != dragStartDigit)
        return Text(digit)
            .font(.brandMono(25, weight: .semibold))
            .foregroundColor(!enabled ? Brand.cloud.opacity(0.28)
                             : (highlight ? Brand.accentOrange : Brand.cloud))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(highlight ? Brand.accentOrange.opacity(0.18) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(highlight ? Brand.accentOrange.opacity(0.6) : Brand.cardBorder, lineWidth: 1))
                        .onAppear { digitFrames[digit] = geo.frame(in: .named(keypadSpace)) }
                        .onChange(of: geo.frame(in: .named(keypadSpace))) { digitFrames[digit] = $0 }
                }
            )
    }

    private func digitAtPoint(_ point: CGPoint) -> String? {
        digitFrames.first(where: { $0.value.contains(point) })?.key
    }

    private func resetDragState() {
        dragStartDigit = nil
        dragCurrentDigit = nil
    }

    private var backspaceKey: some View {
        Button(action: backspacePressed) {
            Image(systemName: "delete.left")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(inputBuffer.isEmpty ? Brand.slate.opacity(0.5) : Brand.slate)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(inputBuffer.isEmpty)
    }

    private var doneKey: some View {
        Button(action: donePressed) {
            Text("DONE")
                .font(.avenir(16, .heavy))
                .tracking(0.6)
                .foregroundColor(Brand.navy)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.accentOrange))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input logic

    private func digitPressed(_ digit: String) {
        guard let field = activeField, let n = Int(digit) else { return }
        errorMessage = nil

        // Swallow a stray "0" released right after an auto-advance/commit.
        if digit == "0", let until = swallowZeroUntil, Date() < until {
            swallowZeroUntil = nil
            return
        }
        swallowZeroUntil = nil

        // Designator leading-zero shortcut: a first digit ≥ 4 can only be 04–09.
        if (field == .runway || field == .windDirection) && inputBuffer.isEmpty && n >= 4 {
            inputBuffer = "0" + digit
            commitCurrentField(advance: true)
            return
        }
        guard inputBuffer.count < field.maxDigits, isDigitEnabled(digit) else { return }

        inputBuffer += digit
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if inputBuffer.count == field.maxDigits {
            commitCurrentField(advance: true)
        }
    }

    private func backspacePressed() {
        guard !inputBuffer.isEmpty else { return }
        inputBuffer.removeLast()
        errorMessage = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// DONE — commit whatever's typed, then flip the bottom zone to the result diagram.
    private func donePressed() {
        if !inputBuffer.isEmpty {
            commitCurrentField(advance: false)
            if errorMessage != nil { return }   // stay so the pilot can fix it
        }
        inputBuffer = ""
        errorMessage = nil
        activeField = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func isDigitEnabled(_ digit: String) -> Bool {
        guard let field = activeField, let d = Int(digit) else { return false }
        switch field {
        case .runway, .windDirection:
            if inputBuffer.isEmpty { return d >= 1 }
            if inputBuffer.count == 1 {
                guard let first = Int(inputBuffer) else { return true }
                if first == 3 { return d <= 6 }   // 30–36 only
                return true
            }
            return false
        case .windSpeed, .gust:
            return inputBuffer.count < 2
        }
    }

    /// Validate the typed buffer, write it to the binding, then either advance to the next
    /// field (keeping the keypad up) or — after the last field — flip to the diagram.
    private func commitCurrentField(advance: Bool) {
        guard let field = activeField, let val = Int(inputBuffer) else { return }

        switch field {
        case .runway:
            guard (1...36).contains(val) else { return showError("01–36") }
            runway = val
        case .windDirection:
            guard (1...36).contains(val) else { return showError("01–36") }
            windDirection = val * 10
        case .windSpeed:
            guard (0...99).contains(val) else { return showError("0–99") }
            windSpeed = val
            if gustSpeed < val { gustSpeed = val }
        case .gust:
            guard val >= windSpeed else { return showError("≥ \(windSpeed)") }
            gustSpeed = val
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        inputBuffer = ""
        errorMessage = nil
        swallowZeroUntil = Date().addingTimeInterval(0.3)

        guard advance else { return }
        if let next = KeypadField(rawValue: field.rawValue + 1) {
            activeField = next
        } else {
            activeField = nil   // committed the last field → show the diagram
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        inputBuffer = ""
        withAnimation(.default) { shakeOffset = 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = -8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 0 }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// A slow-blinking accent caret for the active data field.
private struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        Text("|")
            .font(.brandMono(19, weight: .regular))
            .foregroundColor(Brand.accentOrange)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
