import Foundation

struct CLIError: Error {
  let message: String
  let code: Int32
  init(_ message: String, code: Int32 = 1) {
    self.message = message
    self.code = code
  }
}

enum ExitCode {
  static let failure: Int32 = 1
  static let usage: Int32 = 2
  static let timeout: Int32 = 3
}

func printErr(_ s: String) {
  FileHandle.standardError.write(Data((s + "\n").utf8))
}

func die(_ error: Error) -> Never {
  if let e = error as? CLIError {
    printErr("webkit-cli: \(e.message)")
    exit(e.code)
  }
  printErr("webkit-cli: \(error.localizedDescription)")
  exit(ExitCode.failure)
}
