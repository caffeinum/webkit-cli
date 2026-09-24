import AppKit

let parsed: (Command, Options)
do {
  parsed = try parseArguments(Array(CommandLine.arguments.dropFirst()))
} catch {
  die(error)
}

let (command, options) = parsed
if case .help = command {
  print(helpText)
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  if case .auth = command {
    app.setActivationPolicy(.regular)
  } else {
    app.setActivationPolicy(.accessory)
  }
  Task { @MainActor in
    do {
      try await run(command, options)
      exit(0)
    } catch {
      die(error)
    }
  }
  app.run()
}
