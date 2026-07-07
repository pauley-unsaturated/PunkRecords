import Foundation
import PunkRecordsMCPKit

// Thin executable shim — all real logic lives in PunkRecordsMCPKit.Runner so
// it can be exercised by tests (SPM executable targets can't be imported by
// test targets directly).
let result = await Runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
switch result {
case .success:
    exit(0)
case .failure:
    exit(1)
}
