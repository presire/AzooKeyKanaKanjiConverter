#if Zenzai || ZenzaiCPU
import llama
#endif

import Foundation
import SwiftUtils

struct ZenzPureGreedyDecoder {
    static func decode(context: ZenzContext, leftSideContext: String, maxCount: Int = .max) -> String {
        // [hazkey-community patch] opt-in Zenzai CPU latency deadline (HAZKEY_ZENZAI_DEADLINE_MS)
        ZenzInferencePerf.shared.beginDeadlineWindow()
        var promptTokens = context.encodeRaw(leftSideContext, addBOS: false)
        let initialCount = promptTokens.count
        let vocabSize = Int(context.vocabSize)
        while promptTokens.count - initialCount < maxCount {
            if ZenzInferencePerf.shared.deadlineExpired() {
                debug("HAZKEY_ZENZAI_DEADLINE_MS exceeded in pure greedy decode")
                break
            }
            let startOffset = promptTokens.count - 1
            guard let logits = context.evaluationLogits(tokens: promptTokens, startOffset: startOffset) else {
                debug("logits unavailable")
                return ""
            }
            let startIndex = (promptTokens.count - 1 - startOffset) * vocabSize
            let endIndex = (promptTokens.count - startOffset) * vocabSize
            var maxToken: llama_token = context.eosToken
            var maxValue: Float = -Float.infinity
            for index in startIndex..<endIndex {
                let token = llama_token(index - startIndex)
                if maxValue < logits[index] {
                    maxToken = token
                    maxValue = logits[index]
                }
            }
            if maxToken == context.eosToken {
                break
            } else {
                promptTokens.append(maxToken)
            }
        }
        return context.decodeTokens(Array(promptTokens.dropFirst(initialCount)))
    }
}
