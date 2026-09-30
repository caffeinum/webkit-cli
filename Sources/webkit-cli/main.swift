import Foundation

let parsed: (Command, Options)
do {
  parsed = try parseArguments(Array(CommandLine.arguments.dropFirst()))
} catch {
  die(error)
}

let (command, options) = parsed
do {
  if try runWithoutApp(command) { exit(0) }
} catch {
  die(error)
}

startApp(command, options)
