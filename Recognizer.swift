import Foundation
import UIKit

enum ScanMode {
    case food      // 拍冰箱或食物
    case receipt   // 拍购物小票
}

struct ScannedItem: Identifiable {
    let id = UUID()
    var on: Bool = true
    var emoji: String
    var name: String
    var qty: Double
    var unit: String
    var zone: String
    var expiry: Date?
    var printed: Bool
    var price: Double? = nil   // 小票上的金额
    var raw: String = ""       // 小票上的原文
}

struct ScanResult {
    var items: [ScannedItem] = []
    var store: String = ""
    var date: String = ""
    var total: Double? = nil
    var currency: String = "$"
}

enum RecognizerError: LocalizedError {
    case noKey
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey: return "还没有填写识别密钥，请先到「设置」里填写。"
        case .api(let message): return "识别服务返回错误：\(message)"
        case .badResponse: return "没能读懂识别结果，请再试一次。"
        }
    }
}

enum Recognizer {
    private struct APIResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }

    /// 数字有时会被写成字符串（比如 "3.99"），两种都接受
    private struct Flex: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) {
                value = d
            } else if let s = try? c.decode(String.self) {
                let cleaned = s.filter { "0123456789.-".contains($0) }
                value = Double(cleaned)
            } else {
                value = nil
            }
        }
    }

    private struct RawResult: Decodable {
        let items: [RawItem]
        let store: String?
        let date: String?
        let total: Flex?
        let currency: String?
    }

    private struct RawItem: Decodable {
        let name: String?
        let emoji: String?
        let qty: Flex?
        let unit: String?
        let zone: String?
        let expiry: String?
        let printed: Bool?
        let price: Flex?
        let raw: String?
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func foodPrompt(_ today: String) -> String {
        return """
        你是冰箱食材识别助手。看这张照片（可能是冰箱内部，或刚买回来的食物），列出所有能认出的食材或食品。
        今天是 \(today)。
        对每一样给出：
        - name：中文常用名，简短（如 鸡蛋、纯牛奶、西兰花）
        - emoji：一个最贴切的 emoji
        - qty：估计的数量（数字）
        - unit：中文单位（个、盒、瓶、袋、根、颗、包、份 等）
        - zone：只能是 冷藏、冷冻 或 常温，按照片里的位置或这种食物通常的存放方式判断
        - expiry：到期日期，格式 YYYY-MM-DD。包装上能看清印着的保质期或到期日就用印的；否则按这类食物在该存放方式下的常见保质期从今天推算
        - printed：expiry 是从包装上读到的为 true，否则为 false
        只输出 JSON，不要任何其他文字，格式：
        {"items":[{"name":"","emoji":"","qty":1,"unit":"","zone":"冷藏","expiry":"YYYY-MM-DD","printed":false}]}
        认不出食物时输出 {"items":[]}
        """
    }

    private static func receiptPrompt(_ today: String) -> String {
        return """
        你是购物小票识别助手。这张照片是一张超市购物小票（可能是英文的，商品名常是缩写，例如 Whole Foods 的 "OG BNLS CHKN BRST" 是有机去骨鸡胸肉）。
        今天是 \(today)。
        先读出小票的基本信息：
        - store：商店名称，照小票上的写
        - date：购买日期，格式 YYYY-MM-DD，看不清就用今天
        - total：小票上的应付总金额（数字，不带货币符号）
        - currency：货币符号，例如 $ 或 ¥
        再列出小票上所有的食品和饮料。不是吃的东西（购物袋、日用品、清洁用品、税、押金、折扣行、合计行）一律跳过。同一种商品出现多行就合并数量和金额。
        对每一样给出：
        - name：中文常用名，简短（如 鸡胸肉、牛油果、燕麦奶）
        - emoji：一个最贴切的 emoji
        - qty：购买数量（数字）。按重量卖的写重量
        - unit：中文单位（个、盒、瓶、袋、包、磅、克 等）
        - zone：只能是 冷藏、冷冻 或 常温，按这种食物通常的存放方式判断
        - expiry：到期日期，格式 YYYY-MM-DD，按这类食物的常见保质期从购买日期推算
        - printed：固定为 false
        - price：这一样的总金额（数字，不带货币符号），看不清就写 null
        - raw：小票上这一行的原文
        只输出 JSON，不要任何其他文字，格式：
        {"store":"","date":"YYYY-MM-DD","total":0,"currency":"$","items":[{"name":"","emoji":"","qty":1,"unit":"","zone":"冷藏","expiry":"YYYY-MM-DD","printed":false,"price":0,"raw":""}]}
        照片不是小票或看不清时输出 {"store":"","date":"","total":null,"currency":"$","items":[]}
        """
    }

    static func recognize(image: UIImage, mode: ScanMode, apiKey: String, model: String) async throws -> ScanResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { throw RecognizerError.noKey }

        // 小票字小又长，保留更高的清晰度
        let maxSide: CGFloat = mode == .receipt ? 2000 : 1280
        guard let jpeg = shrink(image, maxSide: maxSide).jpegData(compressionQuality: 0.8) else {
            throw RecognizerError.badResponse
        }

        let today = dayFormatter.string(from: Date())
        let prompt = mode == .receipt ? receiptPrompt(today) : foodPrompt(today)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": mode == .receipt ? 4000 : 2000,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw RecognizerError.api(err.error.message)
            }
            throw RecognizerError.api("状态码 \(status)")
        }

        guard let api = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            throw RecognizerError.badResponse
        }
        let text = api.content.compactMap { $0.text }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw RecognizerError.badResponse
        }
        let json = String(text[start...end])
        guard let raw = try? JSONDecoder().decode(RawResult.self, from: Data(json.utf8)) else {
            throw RecognizerError.badResponse
        }

        var result = ScanResult()
        result.store = (raw.store ?? "").trimmingCharacters(in: .whitespaces)
        result.date = String((raw.date ?? "").prefix(10))
        result.total = raw.total?.value
        let symbol = (raw.currency ?? "").trimmingCharacters(in: .whitespaces)
        result.currency = symbol.isEmpty ? "$" : symbol

        for r in raw.items {
            let name = (r.name ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            let zone = allZones.contains(r.zone ?? "") ? (r.zone ?? "冷藏") : "冷藏"
            let expiry = r.expiry.flatMap { dayFormatter.date(from: String($0.prefix(10))) }
            let rawQty = r.qty?.value ?? 1
            var item = ScannedItem(
                emoji: (r.emoji ?? "").isEmpty ? "🥫" : (r.emoji ?? "🥫"),
                name: name,
                qty: rawQty > 0 ? rawQty : 1,
                unit: (r.unit ?? "").isEmpty ? "个" : (r.unit ?? "个"),
                zone: zone,
                expiry: expiry,
                printed: (r.printed ?? false) && expiry != nil
            )
            item.price = r.price?.value
            item.raw = (r.raw ?? "").trimmingCharacters(in: .whitespaces)
            result.items.append(item)
        }
        return result
    }

    /// 把照片缩小一些，上传更快也更省钱
    private static func shrink(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        if longest <= maxSide { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
