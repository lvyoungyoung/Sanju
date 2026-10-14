import Foundation

/// Presentation-only mapping. The service retains the original payload for retry/recovery decisions.
enum MultilingualAPIError {
    static func code(in payload: String) -> String? {
        let raw = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if message(for: raw) != nil { return raw }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["code", "message", "error"] {
            if let value = object[key] as? String, message(for: value) != nil { return value }
            if let nested = object[key] as? [String: Any] {
                for field in ["code", "message"] {
                    if let value = nested[field] as? String, message(for: value) != nil { return value }
                }
            }
        }
        return nil
    }

    static func message(for code: String) -> String? {
        switch code {
        case "generation_disabled":
            return L10n.string("language.error.unavailable", "此语言尚未开放，请稍后再试。")
        case "invalid_generation_spec", "invalid_selection", "invalid_language_preferences",
             "invalid_target_language", "invalid_level", "unsupported_explanation_language", "unsupported_example_language":
            return L10n.string("language.error.pair", "请选择支持的学习语言与讲解语言组合。")
        case "unsupported_catalog_version":
            return L10n.string("language.error.version", "此内容需要更新 App 后查看。")
        case "request_context_mismatch", "operation_context_mismatch":
            return L10n.string("supabase_error.request_context_mismatch", "请求信息与原记录不一致，暂时无法继续。请重新打开页面后再试。")
        case "generation_in_progress", "generation_pending":
            return L10n.string("supabase_error.generation_pending", "生成仍在处理中，请稍候，暂时无需再次提交。")
        case "generation_failed", "generation_result_unavailable":
            return L10n.string("supabase_error.generation_failed", "暂时无法取得生成结果，请稍后再试。")
        case "invalid_image":
            return L10n.string("generation_error.invalid_image", "图片处理失败，请换一张图片。")
        case "no_credits_left":
            return L10n.string("generation_error.no_credits", "生成次数不足，请先购买。")
        case "preference_revision_conflict":
            return L10n.string("supabase_error.preference_conflict", "设置已在其他设备更新，请刷新后重试。")
        case "invalid_preferences_patch", "invalid_voice", "invalid_request", "invalid_id", "invalid_content",
             "invalid_learning_material", "learning_material_required", "invalid_content_cursor", "invalid_import",
             "invalid_image_path", "duplicate_sentence_id", "duplicate_memory_id", "content_projection_mismatch",
             "immutable_content", "legacy_content_only", "invalid_favorite", "invalid_deletion":
            return L10n.string("language.error.content", "内容暂时无法读取，原有数据已保留。")
        case "invalid_jwt", "unauthorized", "authentication_required", "account_required", "invalid_guest_proof":
            return L10n.string("supabase_error.invalid_token", "登录凭据无效。")
        case "explanation_in_progress":
            return L10n.string("sentence_detail.loading_saved", "正在加载讲解…")
        case "explanation_rate_limited":
            return L10n.string("sentence_detail.rate_limited", "已多次请求讲解，请稍后再试。")
        case "explanation_failed", "sentence_not_found", "sentence_changed", "invalid_guest_source":
            return L10n.string("sentence_detail.analysis_failed", "讲解暂时无法加载，请稍后再试。")
        case "service_unavailable", "server_not_configured":
            return L10n.string("supabase_error.generation_busy", "当前生成服务较忙，请稍后再试。")
        default:
            return nil
        }
    }
}
