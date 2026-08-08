import Foundation

public enum CodexAppServerProtocolGeneratorToolDriver {
  public static func run(arguments: [String]) {
    if Invocation.isHelpRequest(arguments) {
      print(Invocation.help)
      return
    }

    do {
      let invocation = try Invocation(arguments: arguments)

      switch invocation.outputKind {
      case .protocolModels:
        let plan = try GenerationPlanner(
          schemaRoot: invocation.schemaRoot,
          outputRoot: invocation.outputRoot
        ).buildPlan()
        switch invocation.command {
        case .plan:
          print(plan.textSummary())
        case .validate:
          try plan.validateForGeneration()
          print(plan.textSummary())
        case .generate:
          try plan.validateForGeneration()
          try SwiftEmitter(plan: plan).emit()
          if !invocation.isQuiet {
            print(plan.textSummary())
          }
        }
      case .clientBindings:
        let plan = try ClientBindingPlanner(
          schemaRoot: invocation.schemaRoot,
          outputRoot: invocation.outputRoot
        ).buildPlan()
        switch invocation.command {
        case .plan:
          print(plan.textSummary())
        case .validate:
          try plan.validateForGeneration()
          print(plan.textSummary())
        case .generate:
          try plan.validateForGeneration()
          try ClientBindingEmitter(plan: plan).emit()
          if !invocation.isQuiet {
            print(plan.textSummary())
          }
        }
      }
    } catch {
      fputs("error: \(error)\n", stderr)
      exit(1)
    }
  }
}
