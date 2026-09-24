import Foundation

let helpText = """
  webkit-cli — drive the system WebKit headless, with persistent logged-in accounts.

  Log in once in a real window, then run headless forever after. No window ever appears
  except during `auth`.

  USAGE
    webkit-cli accounts                         list accounts (JSON)
    webkit-cli auth <account> <url>             open a visible window; sign in; close the window to save
    webkit-cli open <account> <url>             load and print {"url","title","status"}
    webkit-cli text <account> <url>             print the page's innerText
    webkit-cli eval <account> <url> '<js>'      run JS as an async function body, print the JSON result
    webkit-cli shot <account> <url> <out.png>   save a 1280x800 screenshot (file mode 0600)
    webkit-cli forget <account>                 delete the account and all its website data
    webkit-cli doctor                           check that headless pages really render (visible + rAF)

  <account> is a name you pick (letters, digits, . _ - @). Use `-` for a throwaway in-memory
  session that saves nothing. A <url> without a scheme gets https://. For `auth`, the shortcuts
  `google` / `google.com` and `github` / `github.com` open that provider's sign-in page — sign in
  there once and later "Sign in with Google/GitHub" buttons work headless in that account.

  FLAGS
    --wait <sec>      settle time after the page finishes loading (default 3)
    --timeout <sec>   give up after this long, exit 3 (default 60; `auth` never times out)
    -h, --help        this text

  EXAMPLES
    webkit-cli auth work google                  # sign in to Google in a window, then close it
    webkit-cli open work https://console.cloud.google.com
    webkit-cli text - example.com
    webkit-cli eval work https://github.com/settings/tokens 'return document.title'
    webkit-cli eval - example.com --wait 0 '
      document.querySelector("a").click();
      await new Promise(r => setTimeout(r, 2000));
      return location.href'
    webkit-cli shot work https://railway.com/dashboard /tmp/railway.png

  `eval` code is the body of an async function: use `return` to produce output, `await` freely.
  Fill React inputs with the native setter, then dispatch input/change:
    const i = document.querySelector("input[name=name]");
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, "my-key");
    i.dispatchEvent(new Event("input", {bubbles: true}));
    i.form.requestSubmit();

  Account data: ~/Library/WebKit/webkit-cli/WebsiteDataStore/<uuid> (keyed by the binary name —
  do not rename the binary). Names → uuids and saved session cookies: ~/.config/webkit-cli (0700).
  Cookies are credentials: never print them, never share that directory.

  Exit codes: 0 ok, 1 error, 2 usage, 3 timeout.
  """

enum Command {
  case help
  case accounts
  case auth(account: String, url: URL)
  case open(account: String, url: URL)
  case text(account: String, url: URL)
  case eval(account: String, url: URL, js: String)
  case shot(account: String, url: URL, out: URL)
  case forget(account: String)
  case doctor
}

struct Options {
  var wait: Double = 3
  var timeout: Double = 60
}

func parseArguments(_ args: [String]) throws -> (Command, Options) {
  var opts = Options()
  var positional: [String] = []
  var i = 0
  while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
      return (.help, opts)
    case "--wait", "--timeout":
      guard i + 1 < args.count, let v = Double(args[i + 1]), v >= 0, v.isFinite else {
        throw CLIError("\(a) needs a number of seconds", code: ExitCode.usage)
      }
      if a == "--wait" { opts.wait = v } else { opts.timeout = v }
      i += 2
      continue
    default:
      if a.hasPrefix("--") { throw CLIError("unknown flag \(a) (see --help)", code: ExitCode.usage) }
      positional.append(a)
    }
    i += 1
  }

  guard let verb = positional.first else { return (.help, opts) }
  let rest = Array(positional.dropFirst())
  func need(_ n: Int, _ usage: String) throws {
    guard rest.count == n else { throw CLIError("usage: webkit-cli \(usage)", code: ExitCode.usage) }
  }

  switch verb {
  case "help":
    return (.help, opts)
  case "accounts":
    try need(0, "accounts")
    return (.accounts, opts)
  case "auth":
    try need(2, "auth <account> <url|google|github>")
    guard rest[0] != "-" else { throw CLIError("auth needs a named account — `-` saves nothing", code: ExitCode.usage) }
    return (.auth(account: rest[0], url: try authURL(rest[1])), opts)
  case "open":
    try need(2, "open <account> <url>")
    return (.open(account: rest[0], url: try parseURL(rest[1])), opts)
  case "text":
    try need(2, "text <account> <url>")
    return (.text(account: rest[0], url: try parseURL(rest[1])), opts)
  case "eval":
    try need(3, "eval <account> <url> '<js>'")
    return (.eval(account: rest[0], url: try parseURL(rest[1]), js: rest[2]), opts)
  case "shot":
    try need(3, "shot <account> <url> <out.png>")
    let out = URL(fileURLWithPath: (rest[2] as NSString).expandingTildeInPath)
    return (.shot(account: rest[0], url: try parseURL(rest[1]), out: out), opts)
  case "forget":
    try need(1, "forget <account>")
    return (.forget(account: rest[0]), opts)
  case "doctor":
    try need(0, "doctor")
    return (.doctor, opts)
  default:
    throw CLIError("unknown command '\(verb)' (see --help)", code: ExitCode.usage)
  }
}

func parseURL(_ s: String) throws -> URL {
  let hasScheme = s.contains("://") || s.hasPrefix("about:")
  guard let url = URL(string: hasScheme ? s : "https://" + s), url.host != nil || url.scheme == "about" || url.scheme == "file" else {
    throw CLIError("not a URL: \(s)", code: ExitCode.usage)
  }
  return url
}

func authURL(_ s: String) throws -> URL {
  switch s.lowercased() {
  case "google", "google.com": return URL(string: "https://accounts.google.com/")!
  case "github", "github.com": return URL(string: "https://github.com/login")!
  default: return try parseURL(s)
  }
}
