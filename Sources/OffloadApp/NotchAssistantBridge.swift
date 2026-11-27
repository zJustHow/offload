import OffloadCore
import OffloadUI

/// How the assistant's questions and checklist appear in the notch. The UI target knows nothing about
/// the core, so the translation lives here.
extension NotchModel.Approval {
    init(_ request: ApprovalRequest) {
        if request.spec.name == "exit_plan_mode" {
            self.init(kind: .plan, title: "Here's my plan", detail: request.call.arguments.string("plan") ?? request.description)
        } else if request.reason == RiskClassifier.reason {
            self.init(kind: .irreversible, detail: request.description)
        } else {
            self.init(kind: .needsApproval, detail: request.description, reason: request.reason)
        }
    }
}

extension NotchModel.ChecklistItem {
    init(_ item: TodoItem) {
        switch item.status {
        case .pending: self.init(item.content, .pending)
        case .inProgress: self.init(item.content, .active)
        case .completed: self.init(item.content, .done)
        }
    }
}
