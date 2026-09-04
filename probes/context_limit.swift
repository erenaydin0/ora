import Foundation
import FoundationModels
@main struct M { static func main() async {
  let unit = "Ahmet bugün proje planını gözden geçirdi ve ekip ile bütçe konusunu tartıştı. "
  for n in [200, 400, 800, 1600] {
    let text = String(repeating: unit, count: n)
    let s = LanguageModelSession(instructions: "Türkçe yanıt ver.")
    do {
      let c = clock(); _ = try await s.respond(to: "Tek cümlede özetle:\n\(text)")
      print("✓ \(n) blok ≈ \(text.count) karakter — OK (\(c()))")
    } catch {
      print("✗ \(n) blok ≈ \(text.count) karakter — \(error)")
      break
    }
  }
}
static func clock() -> () -> String { let c = ContinuousClock(); let s = c.now; return { "\(c.now - s)" } } }
