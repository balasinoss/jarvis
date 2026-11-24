import SwiftUI

/// Colors and reusable "glass" styling.
struct Theme {
  let accent: Settings.Accent

  var colors: [Color] {
    switch accent {
    case .aurora: return [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.72, green: 0.36, blue: 1.0), Color(red: 0.25, green: 0.85, blue: 1.0)]
    case .ocean: return [Color(red: 0.10, green: 0.55, blue: 1.0), Color(red: 0.20, green: 0.85, blue: 0.95), Color(red: 0.30, green: 0.40, blue: 1.0)]
    case .sunset: return [Color(red: 1.0, green: 0.45, blue: 0.30), Color(red: 1.0, green: 0.30, blue: 0.55), Color(red: 1.0, green: 0.72, blue: 0.30)]
    case .mint: return [Color(red: 0.15, green: 0.85, blue: 0.65), Color(red: 0.25, green: 0.65, blue: 1.0), Color(red: 0.60, green: 0.95, blue: 0.55)]
    }
  }

  var primary: Color { colors[0] }
  var secondary: Color { colors[1] }

  var gradient: LinearGradient {
    LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}

/// Deep background with two soft colored glows behind the glass.
struct JarvisBackground: View {
  let theme: Theme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.03, green: 0.04, blue: 0.09), Color(red: 0.06, green: 0.05, blue: 0.14), .black],
        startPoint: .top, endPoint: .bottom)
      Circle()
        .fill(theme.colors[0].opacity(0.45))
        .frame(width: 360, height: 360)
        .blur(radius: 120)
        .offset(x: -120, y: -260)
      Circle()
        .fill(theme.colors[1].opacity(0.35))
        .frame(width: 320, height: 320)
        .blur(radius: 120)
        .offset(x: 150, y: 220)
    }
    .ignoresSafeArea()
  }
}

/// Frosted glass panel with a thin bright edge.
struct GlassCard: ViewModifier {
  var cornerRadius: CGFloat = 22
  var tint: Color? = nil

  func body(content: Content) -> some View {
    content
      .padding(14)
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay {
            if let tint {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.12))
            }
          }
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [.white.opacity(0.35), .white.opacity(0.05), .white.opacity(0.15)],
              startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
  }
}

extension View {
  func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
    modifier(GlassCard(cornerRadius: cornerRadius, tint: tint))
  }
}

/// Small round glass button (toolbar icons).
struct GlassIconButton: View {
  let systemName: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
    .buttonStyle(.plain)
  }
}
