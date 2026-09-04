import Foundation
import Speech
import FoundationModels

@main
struct P {
  static func main() async {
    print("### FoundationModels")
    print("availability: \(SystemLanguageModel.default.availability)")

    print("\n### DictationTranscriber.supportedLocales")
    let d = await DictationTranscriber.supportedLocales
    let ids = d.map{$0.identifier}.sorted()
    print("toplam: \(ids.count)")
    print(ids.joined(separator: " "))
    print("TR: \(ids.filter{$0.hasPrefix("tr")})")

    print("\n### DictationTranscriber.installedLocales")
    let di = await DictationTranscriber.installedLocales
    print(di.map{$0.identifier}.sorted().joined(separator: " "))

    print("\n### AssetInventory")
    print("reserved: \(await AssetInventory.reservedLocales.map{$0.identifier})")
    print("max reserved: \(AssetInventory.maximumReservedLocales)")
  }
}
