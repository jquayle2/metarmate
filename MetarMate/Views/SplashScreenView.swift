import SwiftUI

struct SplashScreenView: View {
    @State private var isActive = false
    @State private var opacity = 0.0
    @State private var scale = 0.85

    var body: some View {
        if isActive {
            ContentView()
        } else {
            ZStack {
                Color(red: 0.05, green: 0.10, blue: 0.22)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Spacer()

                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)

                    VStack(spacing: 8) {
                        Text("MetarMate")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("The Weather App That Thinks Like a Pilot")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    Spacer()

                    Text("Powered by NOAA Aviation Weather")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.bottom, 30)
                }
                .scaleEffect(scale)
                .opacity(opacity)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) {
                    opacity = 1.0
                    scale = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        isActive = true
                    }
                }
            }
        }
    }
}
