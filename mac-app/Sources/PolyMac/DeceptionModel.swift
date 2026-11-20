import CoreML
import Foundation

/// Wraps the Core ML classifier produced by `ml/train.py` (`data/models/PolyMacModel.mlmodel`).
/// Its inputs are named after the feature columns (without the `f_` prefix), so the app feeds it
/// exactly the measurements it exported for training.
@MainActor
final class DeceptionModel {
    let featureNames: [String]
    let summary: String
    /// Cross-validated AUC of the model and of the rule-based score on the same data.
    let modelAUC: Double?
    let ruleAUC: Double?
    private let model: MLModel

    init(url: URL) throws {
        let compiled = try MLModel.compileModel(at: url)
        model = try MLModel(contentsOf: compiled)
        featureNames = model.modelDescription.inputDescriptionsByName.keys.sorted()

        let infoURL = url.deletingLastPathComponent().appending(path: "model_info.json")
        let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: infoURL))) as? [String: Any] ?? [:]
        modelAUC = info["cv_auc"] as? Double
        ruleAUC = info["rule_auc"] as? Double
        var parts: [String] = []
        if let type = info["model_type"] as? String { parts.append(type.replacingOccurrences(of: "_", with: " ")) }
        if let n = info["n_questions"] as? Int, let s = info["n_subjects"] as? Int { parts.append("\(n) answers from \(s) subjects") }
        if let auc = modelAUC { parts.append(String(format: "AUC %.2f", auc)) }
        summary = parts.isEmpty ? "Trained model loaded" : parts.joined(separator: " · ")
    }

    /// Probability (0–1) that the answer was a lie, or nil if a feature the model needs is missing.
    func probability(_ features: FeatureVector) -> Double? {
        var inputs: [String: MLFeatureValue] = [:]
        for name in featureNames {
            guard let value = features[name] else { return nil }
            inputs[name] = MLFeatureValue(double: value)
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
              let output = try? model.prediction(from: provider) else { return nil }
        for name in output.featureNames {
            guard let probabilities = output.featureValue(for: name)?.dictionaryValue, !probabilities.isEmpty else { continue }
            for (key, value) in probabilities where "\(key)" == "1" {
                return value.doubleValue
            }
        }
        return nil
    }
}
