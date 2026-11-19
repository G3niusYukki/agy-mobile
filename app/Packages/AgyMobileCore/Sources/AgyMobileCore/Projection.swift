import Foundation

/// 把 Antigravity 网关的 JSON 事件投影成手机端消息。纯函数，便于单测。
public enum AgyProjection {
    public static func text(fromContent content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else {
            return (content as? String) ?? ""
        }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    public static func delta(from event: [String: Any]) -> (text: String?, tool: String?) {
        guard let update = event["assistantMessageEvent"] as? [String: Any],
              let type = update["type"] as? String else { return (nil, nil) }
        switch type {
        case "text_delta":
            return (update["delta"] as? String, nil)
        case "toolcall_start":
            let name = update["toolName"] as? String ?? "工具"
            return (nil, name)
        default:
            return (nil, nil)
        }
    }

    public static func approval(from event: [String: Any]) -> ApprovalRequest? {
        guard event["type"] as? String == "extension_ui_request",
              let id = event["id"] as? String,
              let method = event["method"] as? String,
              ["confirm", "select", "input", "editor"].contains(method) else { return nil }
        return ApprovalRequest(
            id: id,
            method: method,
            title: event["title"] as? String ?? "需要你的确认",
            detail: event["message"] as? String
        )
    }

    public static func modelOptions(from data: Any?) -> [ModelOption] {
        guard let root = data as? [String: Any] else { return [] }
        let candidates = (root["models"] as? [[String: Any]]) ?? (root["availableModels"] as? [[String: Any]]) ?? []
        return candidates.compactMap { item in
            guard let provider = item["provider"] as? String,
                  let modelId = item["modelId"] as? String ?? item["id"] as? String else { return nil }
            let name = (item["displayName"] as? String) ?? (item["name"] as? String)
            return ModelOption(provider: provider, modelId: modelId, displayName: name)
        }
    }
}
