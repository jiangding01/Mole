import Foundation
import Observation

/// 扫描结果跨页共享的应用级会话资产（设计 §5.0）。
///
/// 规则：
/// 1. 智能扫描完成 → 各模块 tab 直接消费同 domain 的 plan，不重复扫描。
/// 2. 未扫描过 → 模块 tab 显示 idle，各自可单独扫描；结果同样写回本会话。
/// 3. plan 30 分钟过期或该 domain 已 apply → 仅该 domain 回到 idle。
/// 4. 数据一份、两处视图：智能扫描结论卡与模块 review 同源。
@Observable
public final class ScanSession {
    /// 破坏性操作域（与 robot 协议 domain 对齐，§4.1）。
    public enum Domain: String, CaseIterable, Sendable {
        case clean
        case uninstallLeftovers = "uninstall_leftovers"
        case installer
        case purge
    }

    public struct DomainPlan: Sendable {
        public var planId: String
        public var items: [RobotItem]
        public var insights: [RobotInsight]
        public var createdAt: Date

        /// 与核心侧 plan 文件的 30 分钟有效期对齐（§4.3 done.plan_id）。
        public func isExpired(now: Date = Date(), ttl: TimeInterval = 30 * 60) -> Bool {
            now.timeIntervalSince(createdAt) > ttl
        }
    }

    public private(set) var plans: [Domain: DomainPlan] = [:]

    public init() {}

    /// 有效（未过期）plan；过期即视为无，UI 落回 idle。
    public func activePlan(for domain: Domain, now: Date = Date()) -> DomainPlan? {
        guard let plan = plans[domain], !plan.isExpired(now: now) else { return nil }
        return plan
    }

    public func store(_ plan: DomainPlan, for domain: Domain) {
        plans[domain] = plan
    }

    /// apply 完成后该 domain 的 plan 作废（规则 3）。
    public func invalidate(_ domain: Domain) {
        plans[domain] = nil
    }
}
