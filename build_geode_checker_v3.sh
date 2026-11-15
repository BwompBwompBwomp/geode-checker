#!/bin/bash
# Geode Checker v3 - build / uninstall in one script (macOS)
#
#   chmod +x build_geode_checker_v3.sh
#   ./build_geode_checker_v3.sh              build the app and open it
#   ./build_geode_checker_v3.sh --uninstall  remove the app + all its data (add -y to skip the prompt)

APP_NAME="Geode Checker.app"
BUNDLE_ID="com.local.geodechecker"
PROC_NAME="GeodeChecker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------
uninstall_app() {
  set +e
  local assume_yes="$1"

  local app_candidates=(
    "/Applications/$APP_NAME"
    "$HOME/Applications/$APP_NAME"
    "$SCRIPT_DIR/$APP_NAME"
    "$PWD/$APP_NAME"
    "$HOME/Desktop/$APP_NAME"
    "$HOME/Downloads/$APP_NAME"
    "$HOME/Documents/$APP_NAME"
  )
  while IFS= read -r p; do
    [ -n "$p" ] && app_candidates+=("$p")
  done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)

  local data_candidates=(
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/WebKit/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/Application Support/$BUNDLE_ID"
    "$HOME/Library/Containers/$BUNDLE_ID"
  )

  local found=()
  add_if_exists() {
    local item="$1"
    [ -e "$item" ] || return
    local f
    for f in "${found[@]}"; do [ "$f" = "$item" ] && return; done
    found+=("$item")
  }
  local p
  for p in "${app_candidates[@]}"; do
    # Safety: only ever remove something literally named "Geode Checker.app"
    [ "$(basename "$p")" = "$APP_NAME" ] && add_if_exists "$p"
  done
  for p in "${data_candidates[@]}"; do add_if_exists "$p"; done

  if [ ${#found[@]} -eq 0 ]; then
    echo "Nothing to remove - Geode Checker doesn't appear to be installed."
    return 0
  fi

  echo "This will remove:"
  local f
  for f in "${found[@]}"; do echo "  $f"; done
  echo "  (saved settings, scores, custom mods and their images)"
  echo

  if [ "$assume_yes" != "-y" ]; then
    read -r -p "Continue? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Cancelled."; return 0 ;;
    esac
  fi

  if pgrep -x "$PROC_NAME" >/dev/null 2>&1; then
    echo "Quitting Geode Checker…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
    sleep 1
    pkill -x "$PROC_NAME" >/dev/null 2>&1
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1

  for f in "${found[@]}"; do
    if rm -rf "$f" 2>/dev/null; then
      echo "Removed: $f"
    else
      echo "Couldn't remove (try with sudo): $f"
    fi
  done

  echo
  echo "Done. Geode Checker has been uninstalled."
  return 0
}

case "${1:-}" in
  --uninstall|-u|uninstall)
    uninstall_app "${2:-}"
    exit 0
    ;;
  -h|--help)
    echo "Usage:"
    echo "  $0                 build and open Geode Checker"
    echo "  $0 --uninstall     uninstall Geode Checker and its data (add -y to skip the prompt)"
    exit 0
    ;;
esac

# ------------------------------------------------------------------
# Build
# ------------------------------------------------------------------
set -e

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools first:  xcode-select --install"
  exit 1
fi

# Quit the old version if it's running so we can replace it
pkill -x "$PROC_NAME" >/dev/null 2>&1 || true

APP="$APP_NAME"
WORK="$(mktemp -d)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$WORK/GeodeChecker.swift" <<'SWIFT_EOF'
import SwiftUI
import WebKit
import UniformTypeIdentifiers

// ============================================================
// MARK: - Status checking
// ============================================================

enum CheckState: Equatable {
    case idle
    case checking
    case broken(version: String?, text: String)
    case ok
    case error(String)

    var tint: Color {
        switch self {
        case .idle: return .gray
        case .checking: return .blue
        case .broken: return .red
        case .ok: return .green
        case .error: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "questionmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .broken: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.seal.fill"
        case .error: return "wifi.exclamationmark"
        }
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .checking: return "Checking…"
        case .broken: return "Geode is broken"
        case .ok: return "Geode looks fine"
        case .error: return "Couldn't check"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "Press the button to check geode-sdk.org."
        case .checking: return "Loading geode-sdk.org and reading the page…"
        case .broken(let v, _):
            if let v = v { return "A new Geometry Dash update (version \(v)) was released and Geode is currently broken." }
            return "The site says Geode is currently broken after a Geometry Dash update."
        case .ok: return "No “Geode is currently broken” notice was found on the front page."
        case .error(let m): return m
        }
    }
}

final class Checker: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var state: CheckState = .idle
    @Published var lastChecked: Date?

    private let webView: WKWebView
    private var generation = 0
    private let url = URL(string: "https://geode-sdk.org")!

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
    }

    var isChecking: Bool { state == .checking }

    func check() {
        generation += 1
        state = .checking
        webView.load(URLRequest(url: url,
                                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                timeoutInterval: 20))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        poll(gen: generation, attempt: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.error(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.error(error.localizedDescription))
    }

    private func finish(_ s: CheckState) {
        DispatchQueue.main.async {
            self.state = s
            self.lastChecked = Date()
        }
    }

    private func poll(gen: Int, attempt: Int) {
        guard gen == generation else { return }
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
            guard let self = self, gen == self.generation else { return }
            let text = (result as? String) ?? ""
            if let found = Checker.match(text) {
                self.finish(.broken(version: found.version, text: found.text))
            } else if attempt >= 8 {
                self.finish(.ok)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.poll(gen: gen, attempt: attempt + 1)
                }
            }
        }
    }

    static func match(_ text: String) -> (version: String?, text: String)? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let p1 = #"A new update for Geometry Dash\s*\(?\s*version\s*v?([^)\s,]+)\s*\)?\s*was recently released"#
        if let re = try? NSRegularExpression(pattern: p1, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, options: [], range: full) {
            let version = ns.substring(with: m.range(at: 1))
            return (version, lineContaining(ns, range: m.range))
        }

        let p2 = #"Geode is currently broken"#
        if let re = try? NSRegularExpression(pattern: p2, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, options: [], range: full) {
            return (nil, lineContaining(ns, range: m.range))
        }
        return nil
    }

    private static func lineContaining(_ ns: NSString, range: NSRange) -> String {
        let lr = ns.lineRange(for: range)
        return ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ============================================================
// MARK: - Minigame: Flappy Cube
// ============================================================

final class FlappyGame: ObservableObject {
    enum Phase { case ready, playing, dead }
    struct Pipe { var x: Double; var gapY: Double; var scored: Bool }

    let W = 460.0
    let H = 380.0
    let groundH = 44.0
    let cubeX = 110.0
    let cubeSize = 28.0
    let pipeW = 56.0
    let gap = 138.0
    let spacing = 215.0
    let speed = 175.0

    @Published var phase: Phase = .ready
    @Published var score = 0
    @Published var best = UserDefaults.standard.integer(forKey: "flappyBest")
    @Published var quip = ""

    var y = 180.0
    var vy = 0.0
    var rot = 0.0
    var t = 0.0
    var groundOffset = 0.0
    var pipes: [Pipe] = []

    private let quips = [
        "Geode crashed. Just like this cube.",
        "Still faster than waiting for Geode.",
        "Skill issue. (Geode's, not yours.)",
        "That spike came out of nowhere.",
        "Try again - Geode isn't fixed yet anyway."
    ]

    func tap() {
        switch phase {
        case .ready:
            phase = .playing
            vy = -420
        case .playing:
            vy = -420
        case .dead:
            reset()
        }
    }

    func reset() {
        phase = .ready
        score = 0
        pipes = []
        y = 180
        vy = 0
        rot = 0
    }

    private func die() {
        phase = .dead
        quip = quips.randomElement() ?? ""
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "flappyBest")
        }
    }

    func step() {
        let dt = 1.0 / 60.0
        t += dt

        switch phase {
        case .ready:
            y = 180 + sin(t * 3) * 8
            groundOffset += 60 * dt
        case .playing:
            groundOffset += speed * dt
            vy += 1500 * dt
            y += vy * dt
            rot = max(-25, min(70, vy * 0.12))

            for i in pipes.indices { pipes[i].x -= speed * dt }
            pipes.removeAll { $0.x < -pipeW - 10 }

            if pipes.isEmpty || (pipes.last?.x ?? 0) <= W - spacing {
                let lo = 90.0
                let hi = H - groundH - 90.0
                pipes.append(Pipe(x: W + 20, gapY: Double.random(in: lo...hi), scored: false))
            }

            for i in pipes.indices {
                if !pipes[i].scored && pipes[i].x + pipeW < cubeX - cubeSize / 2 {
                    pipes[i].scored = true
                    score += 1
                }
            }

            let half = cubeSize / 2 - 3
            let top = y - half
            let bottom = y + half
            if bottom >= H - groundH || top <= 0 {
                die()
            } else {
                for p in pipes {
                    if cubeX + half > p.x && cubeX - half < p.x + pipeW {
                        if top < p.gapY - gap / 2 || bottom > p.gapY + gap / 2 {
                            die()
                            break
                        }
                    }
                }
            }
        case .dead:
            break
        }
        objectWillChange.send()
    }
}

struct FlappyView: View {
    @ObservedObject var game: FlappyGame
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Canvas { ctx, size in
                    drawScene(&ctx, size)
                }
                .frame(width: game.W, height: game.H)

                if game.phase == .ready {
                    VStack(spacing: 6) {
                        Text("Flappy Cube")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                        Text("Click or press Space to start")
                            .font(.system(size: 13))
                        Text("(while you wait for Geode…)")
                            .font(.system(size: 11))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .shadow(radius: 4)
                } else if game.phase == .dead {
                    VStack(spacing: 6) {
                        Text("Crashed!")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundColor(.red)
                        Text("Score \(game.score)")
                            .font(.system(size: 16, weight: .semibold))
                        Text(game.quip)
                            .font(.system(size: 12))
                            .opacity(0.85)
                        Text("Click or press Space to retry")
                            .font(.system(size: 11))
                            .opacity(0.7)
                            .padding(.top, 4)
                    }
                    .foregroundColor(.white)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
                } else {
                    VStack {
                        Text("\(game.score)")
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(radius: 4)
                            .padding(.top, 14)
                        Spacer()
                    }
                    .frame(width: game.W, height: game.H)
                }
            }
            .frame(width: game.W, height: game.H)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { game.tap() }

            HStack {
                Label("Score \(game.score)", systemImage: "flag.fill")
                Spacer()
                Label("Best \(game.best)", systemImage: "trophy.fill")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: game.W)

            Button("") { game.tap() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in game.step() }
    }

    private func drawScene(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let W = game.W
        let H = game.H
        let gh = game.groundH

        let sky = Gradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.45), Color(red: 0.35, green: 0.15, blue: 0.65)])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .linearGradient(sky, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))

        for p in game.pipes {
            let topH = p.gapY - game.gap / 2
            let botY = p.gapY + game.gap / 2
            let botH = H - gh - botY
            let topRect = CGRect(x: p.x, y: 0, width: game.pipeW, height: topH)
            let botRect = CGRect(x: p.x, y: botY, width: game.pipeW, height: botH)
            let topCap = CGRect(x: p.x - 4, y: topH - 14, width: game.pipeW + 8, height: 14)
            let botCap = CGRect(x: p.x - 4, y: botY, width: game.pipeW + 8, height: 14)
            for r in [topRect, botRect, topCap, botCap] {
                ctx.fill(Path(r), with: .color(Color(red: 0.04, green: 0.06, blue: 0.2)))
                ctx.stroke(Path(r), with: .color(Color.cyan), lineWidth: 2)
            }
        }

        let groundRect = CGRect(x: 0, y: H - gh, width: W, height: gh)
        ctx.fill(Path(groundRect), with: .color(Color(red: 0.04, green: 0.05, blue: 0.18)))
        ctx.fill(Path(CGRect(x: 0, y: H - gh, width: W, height: 3)), with: .color(Color.white.opacity(0.9)))
        let stripe = 46.0
        let off = game.groundOffset.truncatingRemainder(dividingBy: stripe)
        var x = -off
        while x < W {
            ctx.fill(Path(CGRect(x: x, y: H - gh + 3, width: 2, height: gh - 3)), with: .color(Color.white.opacity(0.12)))
            x += stripe
        }

        var c = ctx
        c.translateBy(x: game.cubeX, y: game.y)
        c.rotate(by: .degrees(game.rot))
        let s = game.cubeSize
        let body = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
        c.fill(Path(body), with: .color(Color(red: 0.4, green: 1.0, blue: 0.3)))
        c.stroke(Path(body), with: .color(Color.black), lineWidth: 2)
        c.fill(Path(CGRect(x: -8, y: -6, width: 5, height: 5)), with: .color(Color.black))
        c.fill(Path(CGRect(x: 3, y: -6, width: 5, height: 5)), with: .color(Color.black))
        c.fill(Path(CGRect(x: -8, y: 5, width: 16, height: 3)), with: .color(Color.black))
    }
}

// ============================================================
// MARK: - Minigame: Wave Dash
// ============================================================

final class WaveGame: ObservableObject {
    enum Phase { case ready, playing, dead }

    let W = 460.0
    let H = 340.0
    let waveX = 120.0
    let speed = 220.0

    @Published var phase: Phase = .ready
    @Published var score = 0
    @Published var best = UserDefaults.standard.integer(forKey: "waveBest")

    var holding = false
    var y = 170.0
    var scroll = 0.0
    var t = 0.0
    var pts: [(x: Double, c: Double)] = []
    var trail: [Double] = []

    init() {
        reset()
    }

    func reset() {
        phase = .ready
        score = 0
        holding = false
        y = H / 2
        scroll = 0
        trail = []
        pts = [(x: -300.0, c: H / 2), (x: -100.0, c: H / 2), (x: 200.0, c: H / 2), (x: 400.0, c: H / 2)]
        extend()
    }

    private func extend() {
        while (pts.last?.x ?? 0) < scroll + W + 300 {
            let last = pts[pts.count - 1]
            let nx = last.x + 80
            var nc = last.c
            if nx > 500 { nc += Double.random(in: -55...55) }
            nc = min(max(nc, 110), H - 110)
            pts.append((x: nx, c: nc))
        }
    }

    func gap(at wx: Double) -> Double {
        return max(100, 190 - max(0, wx - 400) * 0.03)
    }

    func walls(at wx: Double) -> (top: Double, bottom: Double) {
        var c = pts[0].c
        if wx >= pts[pts.count - 1].x { c = pts[pts.count - 1].c }
        for i in 0..<(pts.count - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            if wx >= a.x && wx < b.x {
                let f = (wx - a.x) / (b.x - a.x)
                c = a.c + (b.c - a.c) * f
                break
            }
        }
        let g = gap(at: wx)
        return (top: c - g / 2, bottom: c + g / 2)
    }

    func press() {
        holding = true
        if phase == .ready {
            phase = .playing
        } else if phase == .dead {
            reset()
        }
    }

    func release() {
        holding = false
    }

    private func die() {
        phase = .dead
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "waveBest")
        }
    }

    func step() {
        let dt = 1.0 / 60.0
        t += dt
        switch phase {
        case .ready:
            y = H / 2 + sin(t * 3) * 6
        case .playing:
            scroll += speed * dt
            y += (holding ? -speed : speed) * dt
            trail.insert(y, at: 0)
            if trail.count > 140 { trail.removeLast() }
            extend()
            while pts.count > 3 && pts[1].x < scroll - 200 { pts.removeFirst() }
            score = Int(scroll / 10)

            let wx = scroll + waveX
            var dead = y < 6 || y > H - 6
            for off in [0.0, 6.0] {
                let w = walls(at: wx + off)
                if y - 5 < w.top || y + 5 > w.bottom { dead = true }
            }
            if dead { die() }
        case .dead:
            break
        }
        objectWillChange.send()
    }
}

struct WaveView: View {
    @ObservedObject var game: WaveGame
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Canvas { ctx, size in
                    drawScene(&ctx, size)
                }
                .frame(width: game.W, height: game.H)

                if game.phase == .ready {
                    VStack(spacing: 6) {
                        Text("Wave Dash")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                        Text("Hold the mouse button to go up,\nrelease to go down. Stay in the tunnel!")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .shadow(radius: 4)
                } else if game.phase == .dead {
                    VStack(spacing: 6) {
                        Text("Crashed!")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundColor(.red)
                        Text("Score \(game.score)")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Click to retry")
                            .font(.system(size: 11))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
                } else {
                    VStack {
                        Text("\(game.score)")
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(radius: 4)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .frame(width: game.W, height: game.H)
                }
            }
            .frame(width: game.W, height: game.H)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !game.holding { game.press() }
                    }
                    .onEnded { _ in
                        game.release()
                    }
            )

            HStack {
                Label("Score \(game.score)", systemImage: "flag.fill")
                Spacer()
                Label("Best \(game.best)", systemImage: "trophy.fill")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: game.W)

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in game.step() }
    }

    private func drawScene(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let W = game.W
        let H = game.H

        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(Color(red: 0.05, green: 0.03, blue: 0.15)))

        var top = Path()
        var bottom = Path()
        top.move(to: CGPoint(x: 0, y: 0))
        bottom.move(to: CGPoint(x: 0, y: H))
        var sx = 0.0
        while sx <= W {
            let w = game.walls(at: game.scroll + sx)
            top.addLine(to: CGPoint(x: sx, y: w.top))
            bottom.addLine(to: CGPoint(x: sx, y: w.bottom))
            sx += 6
        }
        top.addLine(to: CGPoint(x: W, y: 0))
        top.closeSubpath()
        bottom.addLine(to: CGPoint(x: W, y: H))
        bottom.closeSubpath()
        for p in [top, bottom] {
            ctx.fill(p, with: .color(Color(red: 0.12, green: 0.05, blue: 0.30)))
            ctx.stroke(p, with: .color(Color.pink), lineWidth: 2)
        }

        // trail
        var trail = Path()
        for i in game.trail.indices {
            let x = game.waveX - Double(i) * game.speed / 60.0
            let pt = CGPoint(x: x, y: game.trail[i])
            if i == 0 { trail.move(to: pt) } else { trail.addLine(to: pt) }
        }
        ctx.stroke(trail, with: .color(Color.cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        // wave head
        var c = ctx
        c.translateBy(x: game.waveX, y: game.y)
        c.rotate(by: .degrees(game.holding ? -45 : 45))
        var tri = Path()
        tri.move(to: CGPoint(x: 11, y: 0))
        tri.addLine(to: CGPoint(x: -8, y: -8))
        tri.addLine(to: CGPoint(x: -8, y: 8))
        tri.closeSubpath()
        c.fill(tri, with: .color(Color.white))
        c.stroke(tri, with: .color(Color.cyan), lineWidth: 2)
    }
}

// ============================================================
// MARK: - Minigame: Memory Match
// ============================================================

final class MemoryGame: ObservableObject {
    struct Card: Identifiable {
        let id: Int
        let symbol: String
        var up = false
        var matched = false
    }

    static let symbols = ["cube.fill", "bolt.fill", "flame.fill", "star.fill", "heart.fill", "moon.fill", "sparkles", "shippingbox.fill"]

    @Published var cards: [Card] = []
    @Published var moves = 0
    @Published var won = false
    @Published var best = UserDefaults.standard.integer(forKey: "memoryBest")

    private var first: Int? = nil
    private var locked = false

    init() {
        newGame()
    }

    func newGame() {
        var s = MemoryGame.symbols + MemoryGame.symbols
        s.shuffle()
        var list: [Card] = []
        for (i, sym) in s.enumerated() {
            list.append(Card(id: i, symbol: sym))
        }
        cards = list
        moves = 0
        won = false
        first = nil
        locked = false
    }

    func flip(_ i: Int) {
        guard !locked, !cards[i].up, !cards[i].matched else { return }
        cards[i].up = true
        if let f = first {
            moves += 1
            first = nil
            if cards[f].symbol == cards[i].symbol {
                cards[f].matched = true
                cards[i].matched = true
                if cards.allSatisfy({ $0.matched }) {
                    won = true
                    if best == 0 || moves < best {
                        best = moves
                        UserDefaults.standard.set(best, forKey: "memoryBest")
                    }
                }
            } else {
                locked = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self = self else { return }
                    self.cards[f].up = false
                    self.cards[i].up = false
                    self.locked = false
                }
            }
        } else {
            first = i
        }
    }
}

struct MemoryView: View {
    @ObservedObject var game: MemoryGame

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Moves \(game.moves)", systemImage: "hand.tap.fill")
                Spacer()
                Label(game.best == 0 ? "Best –" : "Best \(game.best)", systemImage: "trophy.fill")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 10), count: 4), spacing: 10) {
                ForEach(game.cards) { card in
                    Button {
                        game.flip(card.id)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(card.up || card.matched ? Color.primary.opacity(0.10) : Color.purple.opacity(0.85))
                            if card.up || card.matched {
                                Image(systemName: card.symbol)
                                    .font(.system(size: 30))
                                    .foregroundColor(card.matched ? Color.green : Color.yellow)
                            } else {
                                Image(systemName: "questionmark")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.7))
                            }
                        }
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(card.matched ? Color.green : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.18), value: card.up)
                }
            }

            if game.won {
                Text("You matched them all in \(game.moves) moves!")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.green)
            }

            Button {
                game.newGame()
            } label: {
                Label("New Game", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer(minLength: 0)
        }
    }
}

// ============================================================
// MARK: - Minigame: Reaction Test
// ============================================================

final class ReactionGame: ObservableObject {
    enum Phase { case idle, waiting, go, result, early }

    @Published var phase: Phase = .idle
    @Published var ms = 0
    @Published var best = UserDefaults.standard.integer(forKey: "reactionBest")

    private var startTime = Date()
    private var work: DispatchWorkItem?

    func tap() {
        switch phase {
        case .idle, .result, .early:
            phase = .waiting
            let item = DispatchWorkItem { [weak self] in
                self?.startTime = Date()
                self?.phase = .go
            }
            work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1.5...4.0), execute: item)
        case .waiting:
            work?.cancel()
            phase = .early
        case .go:
            ms = Int(Date().timeIntervalSince(startTime) * 1000)
            phase = .result
            if best == 0 || ms < best {
                best = ms
                UserDefaults.standard.set(best, forKey: "reactionBest")
            }
        }
    }

    var rating: String {
        if ms < 180 { return "Inhuman. Are you a macro bot?" }
        if ms < 250 { return "Fast enough for a Demon." }
        if ms < 350 { return "Solid. Fine for most levels." }
        return "Take a breath and try again."
    }
}

struct ReactionView: View {
    @ObservedObject var game: ReactionGame

    private var fillColor: Color {
        switch game.phase {
        case .idle: return Color.blue
        case .waiting: return Color.red
        case .go: return Color.green
        case .result: return Color.indigo
        case .early: return Color.orange
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(fillColor.opacity(0.85))
                VStack(spacing: 8) {
                    switch game.phase {
                    case .idle:
                        Image(systemName: "bolt.fill").font(.system(size: 40))
                        Text("Reaction Test").font(.system(size: 24, weight: .heavy, design: .rounded))
                        Text("Click to start. When the box turns green, click as fast as you can.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                    case .waiting:
                        Image(systemName: "hourglass").font(.system(size: 40))
                        Text("Wait for green…").font(.system(size: 24, weight: .heavy, design: .rounded))
                    case .go:
                        Image(systemName: "cursorarrow.click.2").font(.system(size: 40))
                        Text("CLICK!").font(.system(size: 40, weight: .heavy, design: .rounded))
                    case .result:
                        Text("\(game.ms) ms").font(.system(size: 44, weight: .heavy, design: .rounded))
                        Text(game.rating).font(.system(size: 13))
                        Text("Click to try again").font(.system(size: 11)).opacity(0.7)
                    case .early:
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40))
                        Text("Too soon!").font(.system(size: 24, weight: .heavy, design: .rounded))
                        Text("Click to try again").font(.system(size: 11)).opacity(0.7)
                    }
                }
                .foregroundColor(.white)
                .padding(20)
            }
            .frame(width: 460, height: 300)
            .contentShape(Rectangle())
            .onTapGesture { game.tap() }

            HStack {
                Label(game.ms == 0 ? "Last –" : "Last \(game.ms) ms", systemImage: "timer")
                Spacer()
                Label(game.best == 0 ? "Best –" : "Best \(game.best) ms", systemImage: "trophy.fill")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 460)

            Spacer(minLength: 0)
        }
    }
}

// ============================================================
// MARK: - Minigame: Orb Clicker
// ============================================================

final class ClickerGame: ObservableObject {
    @Published var orbs: Double
    @Published var clickLvl: Int
    @Published var autoLvl: Int
    @Published var farmLvl: Int
    private var ticks = 0

    init() {
        let d = UserDefaults.standard
        orbs = d.double(forKey: "clkOrbs")
        clickLvl = d.integer(forKey: "clkClick")
        autoLvl = d.integer(forKey: "clkAuto")
        farmLvl = d.integer(forKey: "clkFarm")
    }

    var perClick: Double { 1 + Double(clickLvl) }
    var perSec: Double { Double(autoLvl) + Double(farmLvl) * 8 }

    func cost(_ kind: Int) -> Double {
        switch kind {
        case 0: return ceil(15 * pow(1.4, Double(clickLvl)))
        case 1: return ceil(60 * pow(1.45, Double(autoLvl)))
        default: return ceil(500 * pow(1.55, Double(farmLvl)))
        }
    }

    func click() {
        orbs += perClick
    }

    func buy(_ kind: Int) {
        let c = cost(kind)
        guard orbs >= c else { return }
        orbs -= c
        switch kind {
        case 0: clickLvl += 1
        case 1: autoLvl += 1
        default: farmLvl += 1
        }
        save()
    }

    func tick() {
        if perSec > 0 { orbs += perSec * 0.1 }
        ticks += 1
        if ticks % 50 == 0 { save() }
    }

    func save() {
        let d = UserDefaults.standard
        d.set(orbs, forKey: "clkOrbs")
        d.set(clickLvl, forKey: "clkClick")
        d.set(autoLvl, forKey: "clkAuto")
        d.set(farmLvl, forKey: "clkFarm")
    }

    func reset() {
        orbs = 0
        clickLvl = 0
        autoLvl = 0
        farmLvl = 0
        save()
    }
}

struct ClickerView: View {
    @ObservedObject var game: ClickerGame
    @State private var pop = false
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private let names = ["Stronger Clicks", "Auto Clicker", "Orb Farm"]
    private let details = ["+1 orb per click", "+1 orb per second", "+8 orbs per second"]
    private let symbols = ["hand.tap.fill", "cursorarrow.click.2", "leaf.fill"]

    private func level(_ k: Int) -> Int {
        switch k {
        case 0: return game.clickLvl
        case 1: return game.autoLvl
        default: return game.farmLvl
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("\(Int(game.orbs))")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("orbs • \(Int(game.perClick)) per click • \(Int(game.perSec)) per second")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                game.click()
                pop = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { pop = false }
            } label: {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.yellow, Color.orange], center: .center, startRadius: 5, endRadius: 80))
                        .frame(width: 130, height: 130)
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 4)
                        .frame(width: 130, height: 130)
                    Circle()
                        .stroke(Color.yellow.opacity(0.5), lineWidth: 2)
                        .frame(width: 154, height: 154)
                }
                .frame(width: 170, height: 170)
                .scaleEffect(pop ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.08), value: pop)
            }
            .buttonStyle(.plain)

            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { k in
                    HStack(spacing: 12) {
                        Image(systemName: symbols[k])
                            .font(.system(size: 18))
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.2)))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(names[k])  Lv \(level(k))")
                                .font(.system(size: 13, weight: .semibold))
                            Text(details[k])
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("\(Int(game.cost(k))) orbs") { game.buy(k) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(game.orbs < game.cost(k))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                }
            }

            Spacer(minLength: 0)

            Button("Reset progress") { game.reset() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onReceive(tick) { _ in game.tick() }
    }
}

// ============================================================
// MARK: - Games hub
// ============================================================

enum GameKind: String, CaseIterable, Identifiable {
    case flappy, wave, memory, reaction, clicker
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flappy: return "Flappy Cube"
        case .wave: return "Wave Dash"
        case .memory: return "Memory Match"
        case .reaction: return "Reaction Test"
        case .clicker: return "Orb Clicker"
        }
    }

    var blurb: String {
        switch self {
        case .flappy: return "Flap a cube through block pillars."
        case .wave: return "Hold to rise, release to fall. Don't touch walls."
        case .memory: return "Match the pairs in as few moves as you can."
        case .reaction: return "Click the instant the box turns green."
        case .clicker: return "Click the orb, buy upgrades, get rich."
        }
    }

    var symbol: String {
        switch self {
        case .flappy: return "gamecontroller.fill"
        case .wave: return "waveform.path"
        case .memory: return "square.grid.2x2.fill"
        case .reaction: return "bolt.fill"
        case .clicker: return "circle.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .flappy: return .green
        case .wave: return .pink
        case .memory: return .purple
        case .reaction: return .orange
        case .clicker: return .yellow
        }
    }
}

struct GamesView: View {
    @ObservedObject var flappy: FlappyGame
    @ObservedObject var wave: WaveGame
    @ObservedObject var memory: MemoryGame
    @ObservedObject var reaction: ReactionGame
    @ObservedObject var clicker: ClickerGame
    @State private var selected: GameKind? = nil

    var body: some View {
        if let g = selected {
            VStack(spacing: 10) {
                HStack {
                    Button {
                        selected = nil
                    } label: {
                        Label("Games", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(g.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("Games")
                        .font(.system(size: 12))
                        .opacity(0)
                }
                gameContent(g)
            }
        } else {
            menu
        }
    }

    @ViewBuilder
    private func gameContent(_ g: GameKind) -> some View {
        switch g {
        case .flappy: FlappyView(game: flappy)
        case .wave: WaveView(game: wave)
        case .memory: MemoryView(game: memory)
        case .reaction: ReactionView(game: reaction)
        case .clicker: ClickerView(game: clicker)
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a minigame")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text("Something to do while Geode gets fixed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(GameKind.allCases) { g in
                    Button {
                        selected = g
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: g.symbol)
                                .font(.system(size: 26))
                                .foregroundColor(g.color)
                            Text(g.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(g.blurb)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(g.color.opacity(0.45), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// ============================================================
// MARK: - Geode Simulator (fake mods + custom mods)
// ============================================================

struct FakeMod: Identifiable {
    let id: String
    let name: String
    let dev: String
    let desc: String
    let size: Double
    let symbol: String
    let color: Color
    var imageFile: String? = nil
    var isCustom = false
}

struct CustomRecord: Codable, Identifiable {
    var id: String
    var name: String
    var dev: String
    var desc: String
    var size: Double
    var symbol: String
    var colorIndex: Int
    var imageFile: String?
}

let modPalette: [Color] = [.purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .gray]

let presetSymbols: [String] = [
    "star.fill", "bolt.fill", "flame.fill", "heart.fill", "moon.fill", "sun.max.fill", "cloud.fill", "snowflake",
    "leaf.fill", "drop.fill", "hare.fill", "tortoise.fill", "pawprint.fill", "gamecontroller.fill", "music.note", "headphones",
    "camera.fill", "flag.fill", "crown.fill", "globe", "wand.and.stars", "paintbrush.fill", "hammer.fill", "key.fill",
    "gift.fill", "bell.fill", "atom", "cube.fill", "hexagon.fill", "triangle.fill", "puzzlepiece.fill", "target"
]

let allFakeMods: [FakeMod] = [
    FakeMod(id: "noclip", name: "Ultra Noclip Deluxe", dev: "ghostcube", desc: "Walk through spikes. The spikes have filed a complaint.", size: 1.2, symbol: "figure.walk", color: .purple),
    FakeMod(id: "spikes", name: "Spike Remover 3000", dev: "nospike", desc: "Removes all spikes. Replaces them with slightly smaller spikes.", size: 0.8, symbol: "scissors", color: .red),
    FakeMod(id: "rainbow", name: "Rainbow Icon+", dev: "rgbfan", desc: "Makes your cube RGB. +0 FPS, +100 style.", size: 2.4, symbol: "paintpalette.fill", color: .pink),
    FakeMod(id: "coins", name: "Free Platinum Coins", dev: "coinhoarder", desc: "Claims coins. Mostly just claims.", size: 0.5, symbol: "dollarsign.circle.fill", color: .yellow),
    FakeMod(id: "autobeat", name: "Auto-Beat (not cheating)", dev: "definitelylegit", desc: "Beats levels for you. It's not cheating. Promise.", size: 3.1, symbol: "play.circle.fill", color: .blue),
    FakeMod(id: "gnomes", name: "Gravity Gnomes", dev: "gnomelord", desc: "Adds 4 gnomes. They do nothing. They are loved.", size: 6.9, symbol: "leaf.fill", color: .green),
    FakeMod(id: "megacube", name: "Mega Cube", dev: "bigbrain", desc: "Makes your cube 3x bigger. Hitbox unchanged, ego increased.", size: 1.7, symbol: "cube.fill", color: .orange),
    FakeMod(id: "trails", name: "Cosmic Trails", dev: "stardust", desc: "Leaves sparkles behind everything you do.", size: 4.2, symbol: "sparkles", color: .cyan),
    FakeMod(id: "undo", name: "Ctrl+Z For Life", dev: "timelord", desc: "Undo your deaths. Side effects: none, probably.", size: 0.9, symbol: "arrow.uturn.backward.circle.fill", color: .mint),
    FakeMod(id: "bugfix", name: "Bug Fixer", dev: "debugduck", desc: "Fixes 1 bug. Adds 2.", size: 1.1, symbol: "ladybug.fill", color: .red),
    FakeMod(id: "wait", name: "Wait For Geode", dev: "patience", desc: "Makes Geode load faster. Visually only.", size: 0.3, symbol: "hourglass", color: .indigo),
    FakeMod(id: "frames", name: "Frame Skipper", dev: "skipper", desc: "Skips frames. Gains nothing.", size: 0.6, symbol: "forward.frame.fill", color: .teal),
    FakeMod(id: "ragequit", name: "Rage Quit Button", dev: "calmdown", desc: "One click to close the game dramatically.", size: 0.4, symbol: "xmark.octagon.fill", color: .red),
    FakeMod(id: "wishlist", name: "Level Wishlist", dev: "listmaker", desc: "Saves levels you'll totally play later.", size: 1.3, symbol: "bookmark.fill", color: .blue),
    FakeMod(id: "fakefps", name: "Fake FPS Counter", dev: "fpsfan", desc: "Shows 999 FPS. It is not 999 FPS.", size: 0.2, symbol: "speedometer", color: .green),
    FakeMod(id: "iconroulette", name: "Icon Roulette", dev: "randomizer", desc: "Picks a random icon every attempt.", size: 2.0, symbol: "dice.fill", color: .purple),
    FakeMod(id: "spikehugger", name: "Spike Hugger", dev: "spikelover", desc: "Makes spikes look friendlier. Still lethal.", size: 0.7, symbol: "heart.fill", color: .pink),
    FakeMod(id: "clickcount", name: "Click Counter Pro", dev: "tapper", desc: "Counts every click. Judges you quietly.", size: 0.5, symbol: "hand.tap.fill", color: .cyan),
    FakeMod(id: "orbmagnet", name: "Orb Magnet", dev: "magnetman", desc: "Pulls orbs toward you. Nobody knows how.", size: 1.5, symbol: "dot.radiowaves.left.and.right", color: .blue),
    FakeMod(id: "musicviz", name: "Music Sync Visualizer", dev: "bassdrop", desc: "Makes the menu bounce to the beat.", size: 3.8, symbol: "waveform", color: .mint),
    FakeMod(id: "darkplus", name: "Dark Mode Plus", dev: "nightowl", desc: "Makes the dark even darker.", size: 0.9, symbol: "moon.stars.fill", color: .indigo),
    FakeMod(id: "coindetect", name: "Coin Detector", dev: "goldfinder", desc: "Beeps near secret coins. Beeps near everything.", size: 1.0, symbol: "dot.radiowaves.right", color: .yellow),
    FakeMod(id: "practicepro", name: "Practice Mode Pro", dev: "checkpointer", desc: "Unlimited checkpoints and mild guilt.", size: 1.8, symbol: "flag.checkered", color: .green),
    FakeMod(id: "doodler", name: "Screenshot Doodler", dev: "artsy", desc: "Draw on your death screens.", size: 2.6, symbol: "pencil.tip", color: .orange),
    FakeMod(id: "easylie", name: "Easy Mode (lie)", dev: "optimist", desc: "Makes every level feel Easy. It isn't.", size: 0.3, symbol: "face.smiling.fill", color: .teal),
    FakeMod(id: "pinger", name: "Server Pinger", dev: "netnerd", desc: "Shows how slow the servers are today.", size: 0.6, symbol: "network", color: .gray)
]

enum IconStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.local.geodechecker").appendingPathComponent("icons")
    }

    private static var cache: [String: NSImage] = [:]

    static func image(named file: String) -> NSImage? {
        if let c = cache[file] { return c }
        let url = dir.appendingPathComponent(file)
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache[file] = img
        return img
    }

    // Crops/scales the picked image to a 128x128 PNG inside Application Support. Returns the file name.
    static func save(from url: URL) -> String? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let target: CGFloat = 128
        let out = NSImage(size: NSSize(width: target, height: target))
        out.lockFocus()
        let s = img.size
        if s.width > 0 && s.height > 0 {
            let scale = max(target / s.width, target / s.height)
            let w = s.width * scale
            let h = s.height * scale
            img.draw(in: NSRect(x: (target - w) / 2, y: (target - h) / 2, width: w, height: h),
                     from: .zero, operation: .copy, fraction: 1.0)
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".png"
            try png.write(to: dir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }
}

final class SimStore: ObservableObject {
    @Published var installed: [String]
    @Published var enabled: [String]
    @Published var custom: [CustomRecord]
    @Published var downloading: [String: Double] = [:]
    @Published var log: [String] = ["[Geode] Geode Simulator ready. (Not the real Geode!)"]
    @Published var restarting = false

    init() {
        installed = UserDefaults.standard.stringArray(forKey: "simInstalled") ?? []
        enabled = UserDefaults.standard.stringArray(forKey: "simEnabled") ?? []
        if let d = UserDefaults.standard.data(forKey: "simCustom"),
           let c = try? JSONDecoder().decode([CustomRecord].self, from: d) {
            custom = c
        } else {
            custom = []
        }
    }

    var allMods: [FakeMod] {
        var list: [FakeMod] = []
        for r in custom {
            list.append(FakeMod(id: r.id, name: r.name, dev: r.dev, desc: r.desc, size: r.size,
                                symbol: r.symbol, color: modPalette[r.colorIndex % modPalette.count],
                                imageFile: r.imageFile, isCustom: true))
        }
        list.append(contentsOf: allFakeMods)
        return list
    }

    private func save() {
        UserDefaults.standard.set(installed, forKey: "simInstalled")
        UserDefaults.standard.set(enabled, forKey: "simEnabled")
    }

    private func saveCustom() {
        if let d = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(d, forKey: "simCustom")
        }
    }

    private func add(_ line: String) {
        log.append(line)
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    private func name(_ id: String) -> String {
        allMods.first(where: { $0.id == id })?.name ?? id
    }

    func addCustom(name: String, dev: String, desc: String, symbol: String, colorIndex: Int, imageFile: String?) {
        let size = (Double.random(in: 0.3...9.9) * 10).rounded() / 10
        let rec = CustomRecord(id: "custom-" + UUID().uuidString, name: name, dev: dev, desc: desc,
                               size: size, symbol: symbol, colorIndex: colorIndex, imageFile: imageFile)
        custom.insert(rec, at: 0)
        saveCustom()
        add("[Geode] Created custom mod \(name)")
    }

    func deleteCustom(_ id: String) {
        if let r = custom.first(where: { $0.id == id }), let f = r.imageFile {
            try? FileManager.default.removeItem(at: IconStore.dir.appendingPathComponent(f))
        }
        let n = name(id)
        custom.removeAll { $0.id == id }
        installed.removeAll { $0 == id }
        enabled.removeAll { $0 == id }
        save()
        saveCustom()
        add("[Geode] Deleted custom mod \(n)")
    }

    func download(_ id: String) {
        guard downloading[id] == nil, !installed.contains(id) else { return }
        downloading[id] = 0
        add("[Geode] Downloading \(name(id))…")
    }

    func tick() {
        guard !downloading.isEmpty else { return }
        for (id, p) in downloading {
            let np = p + Double.random(in: 0.02...0.08)
            if np >= 1 {
                downloading[id] = nil
                installed.append(id)
                enabled.append(id)
                save()
                add("[Geode] Installed \(name(id)) (fake!)")
            } else {
                downloading[id] = np
            }
        }
    }

    func toggle(_ id: String) {
        if let i = enabled.firstIndex(of: id) {
            enabled.remove(at: i)
            add("[Geode] Disabled \(name(id))")
        } else {
            enabled.append(id)
            add("[Geode] Enabled \(name(id))")
        }
        save()
    }

    func uninstall(_ id: String) {
        installed.removeAll { $0 == id }
        enabled.removeAll { $0 == id }
        save()
        add("[Geode] Uninstalled \(name(id))")
    }

    func restart() {
        guard !restarting else { return }
        restarting = true
        add("[Geode] Restarting Geometry Dash…")
        let ids = installed.filter { enabled.contains($0) }
        var delay = 0.6
        for id in ids {
            let n = name(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.add("[Geode] Loaded \(n) v1.0.0")
            }
            delay += 0.45
        }
        if ids.count >= 4 {
            let count = ids.count
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.add("[Geode] WARNING: \(count) mods loaded. What could go wrong?")
            }
            delay += 0.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.add("[Geode] Done. Nothing real was loaded - this is a simulator.")
            self?.restarting = false
        }
    }
}

struct ModIcon: View {
    let symbol: String
    let color: Color
    let imageFile: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if let f = imageFile, let img = IconStore.image(named: f) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            } else {
                RoundedRectangle(cornerRadius: size * 0.23).fill(color.opacity(0.25))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45))
                    .foregroundColor(color)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ModRow: View {
    let mod: FakeMod
    @ObservedObject var store: SimStore
    let installedMode: Bool

    var body: some View {
        HStack(spacing: 12) {
            ModIcon(symbol: mod.symbol, color: mod.color, imageFile: mod.imageFile)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mod.name)
                        .font(.system(size: 13, weight: .semibold))
                    if mod.isCustom {
                        Text("CUSTOM")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
                Text("by \(mod.dev) • \(String(format: "%.1f", mod.size)) MB")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(mod.desc)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    @ViewBuilder
    private var trailing: some View {
        if installedMode {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { store.enabled.contains(mod.id) },
                    set: { _ in store.toggle(mod.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)

                Button {
                    store.uninstall(mod.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        } else if let p = store.downloading[mod.id] {
            VStack(spacing: 3) {
                ProgressView(value: p)
                    .frame(width: 70)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        } else if store.installed.contains(mod.id) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        } else {
            HStack(spacing: 8) {
                if mod.isCustom {
                    Button {
                        store.deleteCustom(mod.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this custom mod")
                }
                Button("Get") { store.download(mod.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

struct CustomModEditor: View {
    @ObservedObject var store: SimStore
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var dev = "me"
    @State private var desc = ""
    @State private var useImage = false
    @State private var symbol = presetSymbols[0]
    @State private var colorIdx = 0
    @State private var pickedURL: URL? = nil
    @State private var previewImage: NSImage? = nil
    @State private var errorText = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a custom mod")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            TextField("Mod name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Developer", text: $dev)
                .textFieldStyle(.roundedBorder)
            TextField("Short description", text: $desc)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $useImage) {
                Text("Preset icon").tag(false)
                Text("Image from file").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if useImage {
                HStack(spacing: 12) {
                    Button("Choose Image…") { chooseImage() }
                    Text(pickedURL?.lastPathComponent ?? "No file chosen")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), spacing: 6) {
                    ForEach(presetSymbols, id: \.self) { s in
                        Button {
                            symbol = s
                        } label: {
                            Image(systemName: s)
                                .font(.system(size: 16))
                                .frame(width: 38, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(symbol == s ? modPalette[colorIdx].opacity(0.35) : Color.primary.opacity(0.07))
                                )
                                .foregroundColor(symbol == s ? modPalette[colorIdx] : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    Text("Color")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(0..<modPalette.count, id: \.self) { i in
                        Button {
                            colorIdx = i
                        } label: {
                            Circle()
                                .fill(modPalette[i])
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.white, lineWidth: colorIdx == i ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 12) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if useImage, let img = previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ModIcon(symbol: symbol, color: modPalette[colorIdx], imageFile: nil)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(trimmedName.isEmpty ? "Your mod name" : trimmedName)
                        .font(.system(size: 13, weight: .semibold))
                    Text("by \(dev.isEmpty ? "me" : dev)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create Mod") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image for your mod icon"
        if panel.runModal() == .OK, let url = panel.url {
            pickedURL = url
            previewImage = NSImage(contentsOf: url)
            errorText = ""
        }
    }

    private func create() {
        var file: String? = nil
        if useImage {
            guard let url = pickedURL else {
                errorText = "Choose an image first."
                return
            }
            guard let f = IconStore.save(from: url) else {
                errorText = "Couldn't read that image file."
                return
            }
            file = f
        }
        store.addCustom(name: trimmedName,
                        dev: dev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "me" : dev,
                        desc: desc.isEmpty ? "A custom mod." : desc,
                        symbol: symbol,
                        colorIndex: colorIdx,
                        imageFile: file)
        isPresented = false
    }
}

struct GeodeSimView: View {
    @ObservedObject var store: SimStore
    @State private var page = 0
    @State private var showEditor = false
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var installedMods: [FakeMod] {
        store.allMods.filter { store.installed.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.mint)
                Text("Geode Simulator")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Picker("", selection: $page) {
                    Text("Browse").tag(0)
                    Text("Installed (\(store.installed.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if page == 0 {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Create Custom Mod", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        ForEach(store.allMods) { mod in
                            ModRow(mod: mod, store: store, installedMode: false)
                        }
                    } else if installedMods.isEmpty {
                        Text("No mods installed yet.\nHead to Browse and grab some (they're fake, don't worry).")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(installedMods) { mod in
                            ModRow(mod: mod, store: store, installedMode: true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.log.suffix(5).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.green.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .frame(height: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.75)))

            Button {
                store.restart()
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(store.restarting ? "Restarting…" : "Restart Game")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.restarting)
        }
        .onReceive(tick) { _ in store.tick() }
        .sheet(isPresented: $showEditor) {
            CustomModEditor(store: store, isPresented: $showEditor)
        }
    }
}

// ============================================================
// MARK: - Fake MegaHack menu (speedhack = real game-speed time scale)
// ============================================================

final class MiniRunner: ObservableObject {
    @Published var noclip = false
    @Published var hitboxes = false
    @Published var autoplay = true
    @Published var rainbow = false
    @Published var speedMult = 1.0
    @Published var attempts = 1
    @Published var completions = 0
    @Published var fake: Set<String> = []
    @Published var toast = "Menu loaded. Anything marked FAKE does nothing."

    let W = 460.0
    let H = 150.0
    let groundY = 118.0
    let cubeX = 90.0
    let cycle = 2000.0
    let baseSpeed = 260.0

    static let groups: [(c: Double, n: Int)] = [(420, 1), (760, 2), (1090, 1), (1380, 2), (1700, 1)]

    static func makeSpikes() -> [Double] {
        var out: [Double] = []
        for g in groups {
            for i in 0..<g.n {
                out.append(g.c + (Double(i) - Double(g.n - 1) / 2.0) * 30.0)
            }
        }
        return out
    }

    let spikes = MiniRunner.makeSpikes()

    var dist = 0.0
    var y = 0.0
    var vy = 0.0
    var rot = 0.0
    var prevW = 0.0
    var t = 0.0
    var flash = 0.0

    func jump() {
        if y <= 0 { vy = 520 }
    }

    func setFake(_ name: String, _ on: Bool) {
        if on { fake.insert(name) } else { fake.remove(name) }
        toast = "\(name): \(on ? "ON" : "OFF") (FAKE - does nothing)"
    }

    private func die() {
        attempts += 1
        dist = 0
        prevW = 0
        y = 0
        vy = 0
        flash = 1
    }

    // One real frame. The speedhack scales GAME TIME: scrolling, gravity and jumps all run
    // faster/slower together, so the jump arc keeps the same shape and the whole game speeds up or slows down.
    func step() {
        let frameDt = 1.0 / 60.0
        t += frameDt
        flash = max(0, flash - frameDt * 3)

        let k = max(1, Int(ceil(speedMult)))
        let sub = frameDt * speedMult / Double(k)
        for _ in 0..<k {
            simulate(sub)
        }
        objectWillChange.send()
    }

    private func simulate(_ dt: Double) {
        dist += baseSpeed * dt
        let w = dist.truncatingRemainder(dividingBy: cycle)
        if w < prevW { completions += 1 }
        prevW = w

        // auto-play bot: jump so the apex lands over the spike group
        if autoplay && y <= 0 {
            for g in MiniRunner.groups {
                var d = g.c - w
                if d < -60 { d += cycle }
                if d > 0 && d <= baseSpeed * 0.26 {
                    vy = 520
                    break
                }
            }
        }

        vy -= 2000 * dt
        y += vy * dt
        if y <= 0 {
            y = 0
            if vy < 0 { vy = 0 }
        }

        if y > 0 {
            rot += 173 * dt / 0.0166667 * 0.0166667
        } else {
            rot = (rot / 90).rounded() * 90
        }

        if !noclip {
            for s in spikes {
                var d = s - w
                if d < -60 { d += cycle }
                if abs(d) < 21 && y < 20 {
                    die()
                    break
                }
            }
        }
    }
}

struct MegaHackView: View {
    @ObservedObject var run: MiniRunner
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let fakeItems = [
        "Unlock All Icons", "Free Orbs", "Practice Music Hack", "Safe Mode",
        "No Respawn Flash", "Verify Bypass", "Ignore ESC", "Anti-Cheat Bypass",
        "Instant Complete", "Auto Safe Mode"
    ]

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawRunner(&ctx, size)
                }
                .frame(width: run.W, height: run.H)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Attempt \(run.attempts)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                    Text("Completions \(run.completions)")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundColor(.white)
                .padding(8)
            }
            .frame(width: run.W, height: run.H)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.purple.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { run.jump() }

            Button("") { run.jump() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)

            panel
        }
        .onReceive(tick) { _ in run.step() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.purple)
                Text("MegaHack v∞")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text("FAKE EDITION")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.35)))
                Spacer()
                Text("Space / click to jump")
                    .font(.system(size: 10))
                    .opacity(0.6)
            }
            .padding(10)
            .background(Color.purple.opacity(0.18))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("PLAYER (these work in the preview!)")
                    hackToggle("Noclip", $run.noclip)
                    hackToggle("Auto-Play Bot", $run.autoplay)
                    hackToggle("Show Hitboxes", $run.hitboxes)
                    hackToggle("Rainbow Icon", $run.rainbow)
                    HStack {
                        Text("Speedhack")
                            .font(.system(size: 12))
                        Slider(value: $run.speedMult, in: 0.2...3.0)
                            .tint(.purple)
                        Text(String(format: "%.2fx", run.speedMult))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 46, alignment: .trailing)
                    }

                    sectionTitle("GLOBAL (FAKE - do nothing)")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(fakeItems, id: \.self) { item in
                            Toggle(isOn: Binding(
                                get: { run.fake.contains(item) },
                                set: { run.setFake(item, $0) }
                            )) {
                                Text(item).font(.system(size: 11))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
            }

            Text(run.toast)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color.purple.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.4))
        }
        .background(Color(red: 0.09, green: 0.07, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.purple.opacity(0.5), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .tint(.purple)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Color.purple.opacity(0.9))
    }

    private func hackToggle(_ title: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            Text(title).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func drawRunner(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let W = run.W
        let H = run.H
        let gy = run.groundY
        let w = run.dist.truncatingRemainder(dividingBy: run.cycle)

        let bg = Gradient(colors: [Color(red: 0.22, green: 0.08, blue: 0.5), Color(red: 0.05, green: 0.2, blue: 0.6)])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .linearGradient(bg, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))

        ctx.fill(Path(CGRect(x: 0, y: gy, width: W, height: H - gy)), with: .color(Color(red: 0.04, green: 0.04, blue: 0.18)))
        ctx.fill(Path(CGRect(x: 0, y: gy, width: W, height: 2)), with: .color(Color.white.opacity(0.85)))

        ctx.fill(Path(CGRect(x: 0, y: H - 4, width: W, height: 4)), with: .color(Color.white.opacity(0.15)))
        ctx.fill(Path(CGRect(x: 0, y: H - 4, width: W * (w / run.cycle), height: 4)), with: .color(Color.green))

        for s in run.spikes {
            var d = s - w
            if d < -60 { d += run.cycle }
            let sx = run.cubeX + d
            if sx < -30 || sx > W + 30 { continue }
            var p = Path()
            p.move(to: CGPoint(x: sx - 15, y: gy))
            p.addLine(to: CGPoint(x: sx, y: gy - 30))
            p.addLine(to: CGPoint(x: sx + 15, y: gy))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color.black))
            ctx.stroke(p, with: .color(Color.white), lineWidth: 2)
            if run.hitboxes {
                ctx.stroke(Path(CGRect(x: sx - 7, y: gy - 20, width: 14, height: 20)), with: .color(Color.red), lineWidth: 1.5)
            }
        }

        let cubeCenterY = gy - run.y - 14
        var c = ctx
        c.translateBy(x: run.cubeX, y: cubeCenterY)
        c.rotate(by: .degrees(run.rot))
        let color: Color = run.rainbow
            ? Color(hue: (run.t * 0.5).truncatingRemainder(dividingBy: 1.0), saturation: 0.85, brightness: 1.0)
            : Color(red: 0.4, green: 1.0, blue: 0.3)
        let body = CGRect(x: -14, y: -14, width: 28, height: 28)
        c.fill(Path(body), with: .color(color))
        c.stroke(Path(body), with: .color(Color.black), lineWidth: 2)
        c.fill(Path(CGRect(x: -8, y: -6, width: 5, height: 5)), with: .color(Color.black))
        c.fill(Path(CGRect(x: 3, y: -6, width: 5, height: 5)), with: .color(Color.black))
        c.fill(Path(CGRect(x: -8, y: 5, width: 16, height: 3)), with: .color(Color.black))

        if run.hitboxes {
            ctx.stroke(Path(CGRect(x: run.cubeX - 14, y: gy - run.y - 28, width: 28, height: 28)),
                       with: .color(Color.red), lineWidth: 1.5)
        }

        if run.flash > 0 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(Color.red.opacity(run.flash * 0.45)))
        }
    }
}

// ============================================================
// MARK: - Quiz (randomly generated, hand-verified facts)
// ============================================================

enum QuizDifficulty: String, CaseIterable, Identifiable {
    case easy, normal, hard, demon
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .easy: return .green
        case .normal: return .blue
        case .hard: return .orange
        case .demon: return .red
        }
    }

    var symbol: String {
        switch self {
        case .easy: return "face.smiling.fill"
        case .normal: return "star.fill"
        case .hard: return "flame.fill"
        case .demon: return "exclamationmark.triangle.fill"
        }
    }

    var blurb: String {
        switch self {
        case .easy: return "The basics anyone who has played would know."
        case .normal: return "Regular player and Geode user knowledge."
        case .hard: return "Version history, levels, orbs and Geode internals."
        case .demon: return "Exact dates, level trivia and deep Geode docs."
        }
    }
}

struct QuizQ: Identifiable {
    let id = UUID()
    let text: String
    let options: [String]
    let correct: Int
    let why: String
}

struct Fact {
    let d: QuizDifficulty
    let q: String
    let a: String
    let wrong: [String]
    let why: String
}

func makeQ(_ q: String, _ a: String, _ wrong: [String], _ why: String) -> QuizQ {
    var opts = Array(wrong.filter { $0 != a }.shuffled().prefix(3))
    opts.append(a)
    opts.shuffle()
    return QuizQ(text: q, options: opts, correct: opts.firstIndex(of: a) ?? 0, why: why)
}

enum QuizBuilder {
    // Official levels in in-game order (1-21)
    static let levels = [
        "Stereo Madness", "Back on Track", "Polargeist", "Dry Out", "Base After Base", "Can't Let Go",
        "Jumper", "Time Machine", "Cycles", "xStep", "Clutterfunk", "Theory of Everything",
        "Electroman Adventures", "Clubstep", "Electrodynamix", "Hexagon Force", "Blast Processing",
        "Theory of Everything 2", "Geometrical Dominator", "Deadlocked", "Fingerdash"
    ]

    // Only songs whose composers were double-checked
    static let artistOf: [String: String] = [
        "Stereo Madness": "ForeverBound",
        "Back on Track": "DJVI",
        "Polargeist": "Step",
        "Dry Out": "DJVI",
        "Base After Base": "DJVI",
        "Can't Let Go": "DJVI",
        "Jumper": "Waterflame",
        "Time Machine": "Waterflame",
        "Clutterfunk": "Waterflame",
        "Electroman Adventures": "Waterflame",
        "Theory of Everything": "DJ-Nate",
        "Clubstep": "DJ-Nate",
        "Electrodynamix": "DJ-Nate",
        "Blast Processing": "Waterflame",
        "Theory of Everything 2": "DJ-Nate",
        "Geometrical Dominator": "Waterflame",
        "Deadlocked": "F-777"
    ]

    static let artistPool = ["ForeverBound", "DJVI", "Step", "Waterflame", "DJ-Nate", "F-777", "MDK", "Dex Arson", "Boom Kitty"]

    static let orbs: [(color: String, effect: String)] = [
        ("Yellow", "Gives a normal jump"),
        ("Pink", "Gives a small jump"),
        ("Red", "Gives a big jump"),
        ("Blue", "Reverses gravity"),
        ("Green", "Reverses gravity and gives a jump"),
        ("Black", "Pushes you downward (toward gravity)")
    ]

    static let bank: [Fact] = [
        // ---------------- EASY ----------------
        Fact(d: .easy, q: "Who created Geometry Dash?", a: "RobTop (Robert Topala)",
             wrong: ["Notch (Markus Persson)", "Toby Fox", "ConcernedApe (Eric Barone)"],
             why: "Geometry Dash was created by Swedish developer Robert “RobTop” Topala."),
        Fact(d: .easy, q: "What shape is the default player icon in Geometry Dash?", a: "A cube",
             wrong: ["A circle", "A triangle", "A star"],
             why: "You start out as a cube, which is also the first game mode."),
        Fact(d: .easy, q: "What is Geode?", a: "A mod loader and modding SDK for Geometry Dash",
             wrong: ["A Minecraft texture pack", "A Geometry Dash level editor", "A Geometry Dash soundtrack album"],
             why: "Geode describes itself as a Geometry Dash mod loader and modding SDK."),
        Fact(d: .easy, q: "What is the first official level of Geometry Dash?", a: "Stereo Madness",
             wrong: ["Clubstep", "Deadlocked", "Fingerdash"],
             why: "Stereo Madness is level 1 in the official level list."),
        Fact(d: .easy, q: "In what year was Geometry Dash first released?", a: "2013",
             wrong: ["2009", "2016", "2020"],
             why: "It launched on iOS and Android on 13 August 2013."),
        Fact(d: .easy, q: "What happens when you touch a spike in a level?", a: "You crash and the attempt restarts",
             wrong: ["You gain a secret coin", "You skip to the next level", "You turn into a ship"],
             why: "Hitting a hazard crashes your icon and starts a new attempt."),
        Fact(d: .easy, q: "Which of these is a real Geometry Dash game mode?", a: "UFO",
             wrong: ["Submarine", "Skateboard", "Tank"],
             why: "The game modes are Cube, Ship, Ball, UFO, Wave, Robot, Spider and Swing."),
        Fact(d: .easy, q: "What kind of game is Geometry Dash?", a: "A rhythm-based platformer",
             wrong: ["A farming simulator", "A turn-based RPG", "A battle royale shooter"],
             why: "Levels are synced to music and you have to time your jumps to the rhythm."),
        Fact(d: .easy, q: "Which difficulty is the hardest regular tier?", a: "Demon",
             wrong: ["Easy", "Normal", "Hard"],
             why: "The tiers go Easy, Normal, Hard, Harder, Insane, Demon."),
        Fact(d: .easy, q: "What is the official website of Geode?", a: "geode-sdk.org",
             wrong: ["geometrydash.com", "getgeode.net", "geode.dash"],
             why: "Geode's site is geode-sdk.org, the page this app checks."),
        Fact(d: .easy, q: "What does Practice Mode let you do?", a: "Place checkpoints while you play",
             wrong: ["Skip the whole level", "Change the music", "Make spikes invisible"],
             why: "Practice Mode lets you place checkpoints so you can retry hard parts."),
        Fact(d: .easy, q: "Which platforms did Geometry Dash first launch on in 2013?", a: "iOS and Android",
             wrong: ["PlayStation 4 and Xbox One", "Nintendo Switch", "Steam and Mac App Store"],
             why: "The Steam version came later, in December 2014."),
        Fact(d: .easy, q: "Which orb is the basic jump orb?", a: "Yellow orb",
             wrong: ["Black orb", "Blue orb", "Pink orb"],
             why: "A yellow orb gives a normal jump when you click on it."),
        Fact(d: .easy, q: "What can the level editor be used for?", a: "Building and sharing your own levels",
             wrong: ["Editing the game's source code", "Changing your phone's wallpaper", "Hacking other players' accounts"],
             why: "Geometry Dash includes a level editor so players can make and share levels."),

        // ---------------- NORMAL ----------------
        Fact(d: .normal, q: "Which engine is Geometry Dash built on?", a: "Cocos2d-x",
             wrong: ["Unity", "Unreal Engine", "Godot"],
             why: "Geometry Dash runs on Cocos2d, and Geode ships Cocos2d headers for modders."),
        Fact(d: .normal, q: "Which language are Geode mods usually written in?", a: "C++",
             wrong: ["Python", "Lua", "Java"],
             why: "Geode's Hello World example and SDK are C++."),
        Fact(d: .normal, q: "Which file describes a Geode mod's name, ID and version?", a: "mod.json",
             wrong: ["mod.xml", "manifest.toml", "package.json"],
             why: "Geode mods are configured through mod.json at the root of the project."),
        Fact(d: .normal, q: "Which spin-off featured content from update 2.0?", a: "Geometry Dash Meltdown",
             wrong: ["Geometry Dash World", "Geometry Dash SubZero", "Geometry Dash Inferno"],
             why: "Meltdown, World and SubZero featured content from 2.0, 2.1 and 2.2 respectively."),
        Fact(d: .normal, q: "Which game mode was added in update 2.2?", a: "Swing",
             wrong: ["Spider", "Robot", "Wave"],
             why: "Swing Copter mode arrived in 2.2."),
        Fact(d: .normal, q: "Which game mode was added in update 2.1?", a: "Spider",
             wrong: ["Swing", "Ship", "Cube"],
             why: "Spider mode was one of the headline additions of 2.1."),
        Fact(d: .normal, q: "What is the Geode Mod Index?", a: "A catalog where you can browse and download mods",
             wrong: ["A ranking of the hardest demons", "A list of banned players", "A tool that converts songs"],
             why: "Geode has a server and in-game browser for its Mod Index."),
        Fact(d: .normal, q: "Which Geode component is written mainly in Rust?", a: "The Geode CLI",
             wrong: ["The Geode loader itself", "The Geode example mod", "The Cocos2d headers"],
             why: "geode-sdk/cli is a Rust project, while the loader is C++."),
        Fact(d: .normal, q: "In which year did Geometry Dash come to Steam?", a: "2014",
             wrong: ["2013", "2016", "2018"],
             why: "The Steam release was on 22 December 2014."),
        Fact(d: .normal, q: "Which official level is the first Demon in the level list?", a: "Clubstep",
             wrong: ["Stereo Madness", "Polargeist", "Jumper"],
             why: "Clubstep (level 14) is the first of the three official Demon levels."),
        Fact(d: .normal, q: "What problem does Geode say it wants to solve?", a: "Mod incompatibility",
             wrong: ["Slow level downloads", "Missing music licenses", "High server costs"],
             why: "Geode aims to make sure mods work together without hooks mysteriously disappearing."),
        Fact(d: .normal, q: "Which update introduced platformer levels like The Tower?", a: "2.2",
             wrong: ["2.0", "2.1", "1.9"],
             why: "Platformer mode and levels such as The Tower came with update 2.2."),
        Fact(d: .normal, q: "Which of these is an official Demon level?", a: "Deadlocked",
             wrong: ["Polargeist", "Cycles", "xStep"],
             why: "The official Demons are Clubstep, Theory of Everything 2 and Deadlocked."),

        // ---------------- HARD ----------------
        Fact(d: .hard, q: "In which month and year was Geometry Dash 2.0 released?", a: "August 2015",
             wrong: ["December 2013", "January 2017", "December 2023"],
             why: "Update 2.0 came out on 26 August 2015."),
        Fact(d: .hard, q: "In which year was update 2.1 released?", a: "2017",
             wrong: ["2015", "2019", "2021"],
             why: "Update 2.1 was released in January 2017."),
        Fact(d: .hard, q: "Which GD class does Geode's Hello World example modify?", a: "MenuLayer",
             wrong: ["PlayLayer", "LevelEditorLayer", "GJGameLevel"],
             why: "It hooks MenuLayer::onMoreGames to show a custom popup."),
        Fact(d: .hard, q: "Which macro does Geode use to modify (hook) a GD class?", a: "$modify",
             wrong: ["$hook_class", "$override", "$patch"],
             why: "Geode mods use class $modify(SomeLayer) { ... }."),
        Fact(d: .hard, q: "Which GD update added the 4x speed portal?", a: "2.1",
             wrong: ["2.0", "1.9", "2.2"],
             why: "The 4x speed portal arrived in update 2.1."),
        Fact(d: .hard, q: "Which spin-off featured content from update 2.1?", a: "Geometry Dash World",
             wrong: ["Geometry Dash Meltdown", "Geometry Dash SubZero", "Geometry Dash Inferno"],
             why: "World (2016) previewed 2.1 content."),
        Fact(d: .hard, q: "Which spin-off featured content from update 2.2?", a: "Geometry Dash SubZero",
             wrong: ["Geometry Dash Meltdown", "Geometry Dash World", "Geometry Dash Inferno"],
             why: "SubZero (2017) previewed 2.2 content."),
        Fact(d: .hard, q: "What do platformer levels award in update 2.2?", a: "Moons",
             wrong: ["Diamonds", "Mana Orbs", "Keys"],
             why: "Platformer levels award moons instead of stars."),
        Fact(d: .hard, q: "Which of these is a valid platform key in a mod.json “gd” object?", a: "mac",
             wrong: ["linux", "switch", "playstation"],
             why: "The valid platform keys are win, mac, android and ios."),
        Fact(d: .hard, q: "Which Demon level was added in update 2.0?", a: "Deadlocked",
             wrong: ["Clubstep", "Theory of Everything 2", "Fingerdash"],
             why: "Deadlocked and Geometrical Dominator arrived with 2.0."),
        Fact(d: .hard, q: "Which level did the second major update (1.1, October 2013) add?", a: "Time Machine",
             wrong: ["Cycles", "Clubstep", "xStep"],
             why: "Time Machine, the 8th official level, came with update 1.1."),
        Fact(d: .hard, q: "Which field in a Geode dependency says whether it is required?", a: "importance",
             wrong: ["priority", "weight", "necessity"],
             why: "Dependencies have an importance, e.g. \"required\"."),
        Fact(d: .hard, q: "How do you read a setting's value in Geode C++ code?", a: "Mod::get()->getSettingValue<T>(\"key\")",
             wrong: ["Mod::get()->readConfig(\"key\")", "Settings::fetch(\"key\")", "Geode::setting(\"key\")->value"],
             why: "The Geode docs show getSettingValue<std::string>(\"key\") on Mod::get()."),
        Fact(d: .hard, q: "What file extension does a packaged Geode mod use?", a: ".geode",
             wrong: [".gdmod", ".dll", ".jar"],
             why: "Mods are distributed as .geode packages."),
        Fact(d: .hard, q: "Which is a REQUIRED property of every Geode mod.json?", a: "id",
             wrong: ["settings", "dependencies", "tags"],
             why: "Required keys include the Geode version, id, name, developer and version."),

        // ---------------- DEMON ----------------
        Fact(d: .demon, q: "On what date did Geometry Dash release on Steam?", a: "22 December 2014",
             wrong: ["13 August 2013", "26 August 2015", "19 December 2023"],
             why: "The Steam release was on 22 December 2014."),
        Fact(d: .demon, q: "On what date was update 2.0 released?", a: "26 August 2015",
             wrong: ["22 December 2014", "13 August 2013", "21 December 2017"],
             why: "Update 2.0 was the tenth major update, released 26 August 2015."),
        Fact(d: .demon, q: "On what date did Geometry Dash launch on iOS and Android?", a: "13 August 2013",
             wrong: ["12 June 2014", "22 December 2014", "26 August 2015"],
             why: "The original mobile release was 13 August 2013."),
        Fact(d: .demon, q: "On what date did Geometry Dash release on Windows Phone?", a: "12 June 2014",
             wrong: ["13 August 2013", "22 December 2014", "26 August 2015"],
             why: "Windows Phone got the game on 12 June 2014."),
        Fact(d: .demon, q: "Which Geode Mod method returns a directory that is NOT deleted when the mod is uninstalled?", a: "getPersistentDir()",
             wrong: ["getSaveDir()", "getConfigDir()", "getTempDir()"],
             why: "The persistent dir survives even when Geode or the mod is uninstalled."),
        Fact(d: .demon, q: "Which Geode repository holds Geometry Dash's addresses and function signatures?", a: "bindings",
             wrong: ["docs", "server", "example-mod"],
             why: "geode-sdk/bindings contains the addresses and function signatures for GD."),
        Fact(d: .demon, q: "In which language is the Geode Mod Index server written?", a: "Rust",
             wrong: ["Python", "Go", "JavaScript"],
             why: "geode-sdk/server is a Rust project."),
        Fact(d: .demon, q: "Which character is allowed in a Geode mod ID?", a: "A dash (-)",
             wrong: ["An uppercase letter", "A space", "A slash (/)"],
             why: "IDs may only contain lowercase a-z, periods, underscores and dashes."),
        Fact(d: .demon, q: "Which official level is the only main level to end with the robot game mode?", a: "Geometrical Dominator",
             wrong: ["Deadlocked", "Clubstep", "Electrodynamix"],
             why: "Geometrical Dominator is the only main level that ends in robot mode."),
        Fact(d: .demon, q: "“Geometrical Dominator” exceeds the 20-character level name limit by how many characters?", a: "1 character",
             wrong: ["3 characters", "5 characters", "It does not exceed it"],
             why: "The title is 21 characters long."),
        Fact(d: .demon, q: "Which two levels came in the March 2014 update?", a: "Electroman Adventures and Clubstep",
             wrong: ["Time Machine and Cycles", "Deadlocked and Geometrical Dominator", "Fingerdash and Dash"],
             why: "That seventh major update added Electroman Adventures and Clubstep."),
        Fact(d: .demon, q: "What ID does the Geode Node IDs mod use?", a: "geode.node-ids",
             wrong: ["geode.node-layout", "node.geode", "geode.ids"],
             why: "It is listed as a dependency with the id geode.node-ids."),
        Fact(d: .demon, q: "Which mod.json tag marks a mod that contains paid content?", a: "paid",
             wrong: ["premium", "pro", "gold"],
             why: "The docs list a paid tag for mods with paid content (and joke for joke mods)."),
        Fact(d: .demon, q: "Which major update was the tenth one for Geometry Dash?", a: "2.0",
             wrong: ["1.9", "2.1", "2.2"],
             why: "Update 2.0 was the tenth major update, following 1.9."),
        Fact(d: .demon, q: "What is Broma in the Geode ecosystem?", a: "The format used to describe Geometry Dash's class bindings",
             wrong: ["A level scripting language", "An audio file format", "A mod packaging tool"],
             why: "Broma files describe GD's bindings; the Geode VS Code extension even highlights them."),
        Fact(d: .demon, q: "Which main-level track was the first made specifically for Geometry Dash?", a: "Geometrical Dominator by Waterflame",
             wrong: ["Clubstep by DJ-Nate", "Deadlocked by F-777", "Time Machine by Waterflame"],
             why: "Geometrical Dominator's track was the first one made specifically for the game, with MDK's “Geometry Dash” second.")
    ]

    // ----- generators (correct by construction) -----

    static func genLevelByNumber(_ range: ClosedRange<Int>) -> QuizQ {
        let n = Int.random(in: range)
        let name = levels[n - 1]
        return makeQ("Which official level is number \(n) in the level list?", name, levels.filter { $0 != name },
                     "Level \(n) is \(name).")
    }

    static func genNumberByLevel(_ range: ClosedRange<Int>) -> QuizQ {
        let n = Int.random(in: range)
        let name = levels[n - 1]
        let others = (1...levels.count).filter { $0 != n }.map { String($0) }
        return makeQ("What number is “\(name)” in the official level list?", String(n), others,
                     "\(name) is level \(n).")
    }

    static func genArtist(_ names: [String]? = nil) -> QuizQ {
        let keys = names ?? Array(artistOf.keys)
        let level = keys.randomElement() ?? "Clubstep"
        let artist = artistOf[level] ?? "DJ-Nate"
        return makeQ("Who composed the song for the official level “\(level)”?", artist,
                     artistPool.filter { $0 != artist }, "\(level) uses a track by \(artist).")
    }

    static func genOrb(_ colors: [String]) -> QuizQ {
        let pick = orbs.filter { colors.contains($0.color) }.randomElement() ?? orbs[0]
        var wrong = orbs.filter { $0.color != pick.color }.map { $0.effect }
        if pick.color == "Blue" { wrong.removeAll { $0 == "Reverses gravity and gives a jump" } }
        if pick.color == "Green" { wrong.removeAll { $0 == "Reverses gravity" } }
        return makeQ("What does a \(pick.color.lowercased()) orb do?", pick.effect, wrong,
                     "\(pick.color) orb: \(pick.effect.lowercased()).")
    }

    static func difficultyName(stars: Int) -> String {
        switch stars {
        case 2: return "Easy"
        case 3: return "Normal"
        case 4, 5: return "Hard"
        case 6, 7: return "Harder"
        case 8, 9: return "Insane"
        default: return "Demon"
        }
    }

    static func genStars(_ range: ClosedRange<Int>) -> QuizQ {
        let n = Int.random(in: range)
        let a = difficultyName(stars: n)
        let all = ["Easy", "Normal", "Hard", "Harder", "Insane", "Demon"]
        return makeQ("What difficulty is a regular level worth \(n) stars?", a, all.filter { $0 != a },
                     "Easy 2, Normal 3, Hard 4-5, Harder 6-7, Insane 8-9, Demon 10.")
    }

    static func genSpeed(_ colors: [String]) -> QuizQ {
        let table: [(String, String)] = [("Blue", "1x"), ("Green", "2x"), ("Pink", "3x"), ("Red", "4x")]
        let pick = table.filter { colors.contains($0.0) }.randomElement() ?? table[0]
        if Bool.random() {
            return makeQ("What speed does the \(pick.0.lowercased()) speed portal give?", pick.1,
                         table.map { $0.1 }, "Blue 1x, green 2x, pink 3x, red 4x.")
        } else {
            return makeQ("Which color is the \(pick.1) speed portal?", pick.0,
                         table.map { $0.0 }, "Blue 1x, green 2x, pink 3x, red 4x.")
        }
    }

    static func genPortal() -> QuizQ {
        let items: [(String, String, [String], String)] = [
            ("Which color is the mini-size portal?", "Pink", ["Green", "Blue", "Red"], "Pink makes you mini, green makes you big."),
            ("Which color is the big-size portal?", "Green", ["Pink", "Blue", "Red"], "Green makes you big, pink makes you mini."),
            ("Which gravity portal color flips gravity upside down?", "Yellow", ["Blue", "Green", "Red"], "Yellow flips gravity up, blue returns it to normal."),
            ("Which gravity portal color restores normal gravity?", "Blue", ["Yellow", "Green", "Pink"], "Blue returns gravity to normal.")
        ]
        let it = items.randomElement() ?? items[0]
        return makeQ(it.0, it.1, it.2, it.3)
    }

    static func genModJson() -> QuizQ {
        let required = ["id", "name", "version", "developer"]
        let optional = ["settings", "dependencies", "tags", "resources"]
        let a = required.randomElement() ?? "id"
        return makeQ("Which of these is a REQUIRED property of every Geode mod.json?", a, optional,
                     "Required: Geode version, id, name, developer and version. Settings, dependencies, tags and resources are optional.")
    }

    static func generated(_ d: QuizDifficulty) -> [QuizQ] {
        var out: [QuizQ] = []
        switch d {
        case .easy:
            for _ in 0..<4 { out.append(genLevelByNumber(1...3)) }
            for _ in 0..<4 { out.append(genOrb(["Yellow", "Blue"])) }
        case .normal:
            for _ in 0..<4 { out.append(genOrb(["Yellow", "Pink", "Red", "Blue"])) }
            for _ in 0..<4 { out.append(genStars(2...5)) }
            for _ in 0..<3 { out.append(genLevelByNumber(1...10)) }
            for _ in 0..<2 { out.append(genSpeed(["Blue", "Green"])) }
            for _ in 0..<3 { out.append(genPortal()) }
        case .hard:
            for _ in 0..<4 { out.append(genLevelByNumber(4...17)) }
            for _ in 0..<4 { out.append(genOrb(["Green", "Black", "Red", "Pink"])) }
            for _ in 0..<4 { out.append(genStars(4...10)) }
            for _ in 0..<3 { out.append(genSpeed(["Pink", "Red", "Green"])) }
            for _ in 0..<3 { out.append(genArtist()) }
            for _ in 0..<3 { out.append(genModJson()) }
        case .demon:
            for _ in 0..<4 { out.append(genLevelByNumber(11...21)) }
            for _ in 0..<4 { out.append(genNumberByLevel(11...21)) }
            for _ in 0..<5 { out.append(genArtist(["Electrodynamix", "Theory of Everything 2", "Geometrical Dominator", "Deadlocked", "Clubstep", "Blast Processing", "Clutterfunk", "Electroman Adventures", "Jumper", "Polargeist"])) }
            for _ in 0..<3 { out.append(genNumberByLevel(5...14)) }
        }
        return out
    }

    static func build(_ d: QuizDifficulty, count: Int = 10) -> [QuizQ] {
        var pool = bank.filter { $0.d == d }.map { makeQ($0.q, $0.a, $0.wrong, $0.why) }
        pool.append(contentsOf: generated(d))
        var seen = Set<String>()
        var out: [QuizQ] = []
        for q in pool.shuffled() {
            if seen.insert(q.text).inserted {
                out.append(q)
            }
            if out.count == count { break }
        }
        return out
    }
}

final class QuizModel: ObservableObject {
    enum Phase { case menu, question, result }

    @Published var phase: Phase = .menu
    @Published var difficulty: QuizDifficulty = .easy
    @Published var questions: [QuizQ] = []
    @Published var index = 0
    @Published var picked: Int? = nil
    @Published var score = 0
    @Published var bests: [String: Int] = (UserDefaults.standard.dictionary(forKey: "quizBests") as? [String: Int]) ?? [:]

    var current: QuizQ { questions[index] }

    func start(_ d: QuizDifficulty) {
        difficulty = d
        questions = QuizBuilder.build(d)
        index = 0
        picked = nil
        score = 0
        phase = .question
    }

    func answer(_ i: Int) {
        guard picked == nil else { return }
        picked = i
        if i == current.correct { score += 1 }
    }

    func next() {
        if index + 1 < questions.count {
            index += 1
            picked = nil
        } else {
            finish()
        }
    }

    func finish() {
        let key = difficulty.rawValue
        if score > (bests[key] ?? -1) {
            bests[key] = score
            UserDefaults.standard.set(bests, forKey: "quizBests")
        }
        phase = .result
    }

    func backToMenu() {
        phase = .menu
    }

    var rank: String {
        let total = max(1, questions.count)
        let pct = Double(score) / Double(total)
        if pct >= 1.0 { return "Perfect run! RobTop would be proud." }
        if pct >= 0.8 { return "Demon-level knowledge." }
        if pct >= 0.5 { return "Not bad - keep practicing." }
        return "Back to Stereo Madness with you."
    }
}

struct QuizView: View {
    @ObservedObject var quiz: QuizModel

    var body: some View {
        switch quiz.phase {
        case .menu:
            menu
        case .question:
            questionView
        case .result:
            resultView
        }
    }

    private func bestText(_ d: QuizDifficulty) -> String {
        if let b = quiz.bests[d.rawValue] { return "\(b)/10" }
        return "–"
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Geometry Dash & Geode Quiz")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("10 random questions every time, answers shuffled, facts checked against the docs and wikis.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(QuizDifficulty.allCases) { d in
                Button {
                    quiz.start(d)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: d.symbol)
                            .font(.system(size: 26))
                            .foregroundColor(d.color)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.title)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(d.blurb)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Best")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(bestText(d))
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(d.color)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(d.color.opacity(0.5), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var questionView: some View {
        let q = quiz.current
        return VStack(spacing: 12) {
            HStack {
                Text("Question \(quiz.index + 1) of \(quiz.questions.count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(quiz.difficulty.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(quiz.difficulty.color.opacity(0.3)))
                Text("Score \(quiz.score)")
                    .font(.system(size: 12, weight: .semibold))
            }

            ProgressView(value: Double(quiz.index + (quiz.picked == nil ? 0 : 1)), total: Double(max(1, quiz.questions.count)))
                .tint(quiz.difficulty.color)

            Text(q.text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))

            VStack(spacing: 8) {
                ForEach(0..<q.options.count, id: \.self) { i in
                    optionButton(q, i)
                }
            }

            if quiz.picked != nil {
                Text(q.why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))

                Button {
                    quiz.next()
                } label: {
                    Text(quiz.index + 1 < quiz.questions.count ? "Next question" : "See results")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
    }

    private func optionButton(_ q: QuizQ, _ i: Int) -> some View {
        var bg = Color.primary.opacity(0.08)
        var stroke = Color.clear
        var icon: String? = nil
        if let p = quiz.picked {
            if i == q.correct {
                bg = Color.green.opacity(0.25)
                stroke = Color.green
                icon = "checkmark.circle.fill"
            } else if i == p {
                bg = Color.red.opacity(0.25)
                stroke = Color.red
                icon = "xmark.circle.fill"
            }
        }
        return Button {
            quiz.answer(i)
        } label: {
            HStack {
                Text(q.options[i])
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.leading)
                Spacer()
                if let icon = icon {
                    Image(systemName: icon)
                        .foregroundColor(stroke)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(stroke, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(quiz.picked == nil)
    }

    private var resultView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 10)
            Image(systemName: quiz.difficulty.symbol)
                .font(.system(size: 54))
                .foregroundColor(quiz.difficulty.color)
            Text("\(quiz.score) / \(quiz.questions.count)")
                .font(.system(size: 52, weight: .heavy, design: .rounded))
            Text(quiz.rank)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Difficulty: \(quiz.difficulty.title)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(quiz.difficulty.color)

            Button {
                quiz.start(quiz.difficulty)
            } label: {
                Label("Play again (new random questions)", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                quiz.backToMenu()
            } label: {
                Text("Change difficulty")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
    }
}

// ============================================================
// MARK: - Status tab
// ============================================================

struct StatusView: View {
    @ObservedObject var checker: Checker
    @Binding var autoCheck: Bool

    var body: some View {
        let s = checker.state
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                Group {
                    if s == .checking {
                        ProgressView()
                            .controlSize(.large)
                            .scaleEffect(1.6)
                    } else {
                        Image(systemName: s.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(s.tint)
                    }
                }
                .frame(height: 76)

                Text(s.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(s.tint)

                Text(s.detail)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .broken(let v, let text) = s {
                    VStack(spacing: 8) {
                        if let v = v {
                            Text("Version \(v)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(Color.red.opacity(0.2)))
                                .foregroundStyle(.red)
                        }
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .animation(.easeInOut(duration: 0.3), value: s)

            Button(action: { checker.check() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(s == .checking ? "Checking…" : "Check Now")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(s == .checking)
            .keyboardShortcut("r", modifiers: .command)

            VStack(spacing: 8) {
                Toggle("Auto-check every 10 minutes", isOn: $autoCheck)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                HStack(spacing: 6) {
                    if let d = checker.lastChecked {
                        Text("Last checked \(d.formatted(date: .omitted, time: .standard))")
                    } else {
                        Text("Not checked yet")
                    }
                    Text("·")
                    Button("Open site") {
                        NSWorkspace.shared.open(URL(string: "https://geode-sdk.org")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Text("Bored while you wait? Try the Games, Sim, MegaHack or Quiz tabs.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
    }
}

// ============================================================
// MARK: - Root
// ============================================================

enum AppTab: String, CaseIterable, Identifiable {
    case status, games, sim, hack, quiz
    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .games: return "Games"
        case .sim: return "Sim"
        case .hack: return "MegaHack"
        case .quiz: return "Quiz"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "antenna.radiowaves.left.and.right"
        case .games: return "gamecontroller.fill"
        case .sim: return "shippingbox.fill"
        case .hack: return "slider.horizontal.3"
        case .quiz: return "questionmark.circle.fill"
        }
    }
}

struct TabBar: View {
    @Binding var selection: AppTab
    let badge: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases) { t in
                Button {
                    selection = t
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.symbol)
                        Text(t.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if t == .status && badge {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selection == t ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                    .foregroundColor(selection == t ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var checker = Checker()
    @StateObject private var flappy = FlappyGame()
    @StateObject private var wave = WaveGame()
    @StateObject private var memory = MemoryGame()
    @StateObject private var reaction = ReactionGame()
    @StateObject private var clicker = ClickerGame()
    @StateObject private var sim = SimStore()
    @StateObject private var runner = MiniRunner()
    @StateObject private var quiz = QuizModel()
    @State private var tab: AppTab = .status
    @AppStorage("autoCheck") private var autoCheck = false
    private let timer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    private var isBroken: Bool {
        if case .broken = checker.state { return true }
        return false
    }

    private var stripText: String {
        if case .broken(let v, _) = checker.state, let v = v {
            return "Geode is broken (GD \(v))"
        }
        return checker.state.title
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [checker.state.tint.opacity(0.30), Color(nsColor: .windowBackgroundColor)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: checker.state)

            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Geode Checker")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("geode-sdk.org")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(checker.state.tint).frame(width: 9, height: 9)
                        Text(stripText)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }

                TabBar(selection: $tab, badge: isBroken)

                Group {
                    switch tab {
                    case .status:
                        StatusView(checker: checker, autoCheck: $autoCheck)
                    case .games:
                        GamesView(flappy: flappy, wave: wave, memory: memory, reaction: reaction, clicker: clicker)
                    case .sim:
                        GeodeSimView(store: sim)
                    case .hack:
                        MegaHackView(run: runner)
                    case .quiz:
                        QuizView(quiz: quiz)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(22)
        }
        .frame(width: 560, height: 720)
        .onAppear { checker.check() }
        .onReceive(timer) { _ in
            if autoCheck && !checker.isChecking { checker.check() }
        }
    }
}

@main
struct GeodeCheckerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
SWIFT_EOF

# ---- app icon generator (draws a crystal gem icon, then builds AppIcon.icns) ----
mkdir -p "$WORK/icon" "$WORK/AppIcon.iconset"
cat > "$WORK/icon/main.swift" <<'ICON_EOF'
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let s = CGFloat(px)

    // rounded-square background
    let inset = s * 0.055
    let bgRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.22, yRadius: s * 0.22)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.14, blue: 0.80, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.50, blue: 0.95, alpha: 1)])!
        .draw(in: bgRect, angle: -60)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.38), NSColor(white: 1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: s * 0.5, y: s * 0.52), radius: 0,
              toCenter: NSPoint(x: s * 0.5, y: s * 0.52), radius: s * 0.46, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // soft shadow under the gem
    let shadow = NSBezierPath(ovalIn: NSRect(x: s * 0.26, y: s * 0.12, width: s * 0.48, height: s * 0.07))
    NSColor(white: 0, alpha: 0.22).setFill()
    shadow.fill()

    func facet(_ pts: [(CGFloat, CGFloat)], _ color: NSColor) {
        let p = NSBezierPath()
        for (i, pt) in pts.enumerated() {
            let q = NSPoint(x: pt.0 * s, y: pt.1 * s)
            if i == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        color.setFill()
        p.fill()
        NSColor(white: 1, alpha: 0.45).setStroke()
        p.lineWidth = max(1, s * 0.006)
        p.stroke()
    }

    // gem (y points up)
    let TL: (CGFloat, CGFloat) = (0.30, 0.68)
    let TR: (CGFloat, CGFloat) = (0.70, 0.68)
    let L: (CGFloat, CGFloat) = (0.15, 0.55)
    let R: (CGFloat, CGFloat) = (0.85, 0.55)
    let TL2: (CGFloat, CGFloat) = (0.38, 0.55)
    let TR2: (CGFloat, CGFloat) = (0.62, 0.55)
    let apex: (CGFloat, CGFloat) = (0.50, 0.20)

    facet([TL, TR, TR2, TL2], NSColor(calibratedRed: 0.95, green: 0.99, blue: 1.0, alpha: 1))
    facet([TL, TL2, L], NSColor(calibratedRed: 0.72, green: 0.93, blue: 1.0, alpha: 1))
    facet([TR, R, TR2], NSColor(calibratedRed: 0.52, green: 0.84, blue: 1.0, alpha: 1))
    facet([L, TL2, apex], NSColor(calibratedRed: 0.42, green: 0.74, blue: 0.98, alpha: 1))
    facet([TL2, TR2, apex], NSColor(calibratedRed: 0.78, green: 0.92, blue: 1.0, alpha: 1))
    facet([TR2, R, apex], NSColor(calibratedRed: 0.28, green: 0.58, blue: 0.92, alpha: 1))

    // sparkle
    let cx = s * 0.80
    let cy = s * 0.80
    let r1 = s * 0.075
    let r2 = s * 0.018
    let sp = NSBezierPath()
    sp.move(to: NSPoint(x: cx, y: cy + r1))
    sp.line(to: NSPoint(x: cx + r2, y: cy + r2))
    sp.line(to: NSPoint(x: cx + r1, y: cy))
    sp.line(to: NSPoint(x: cx + r2, y: cy - r2))
    sp.line(to: NSPoint(x: cx, y: cy - r1))
    sp.line(to: NSPoint(x: cx - r2, y: cy - r2))
    sp.line(to: NSPoint(x: cx - r1, y: cy))
    sp.line(to: NSPoint(x: cx - r2, y: cy + r2))
    sp.close()
    NSColor.white.setFill()
    sp.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments[1]
let spec: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in spec {
    try! render(px).write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
}
ICON_EOF

cat > "$APP/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Geode Checker</string>
    <key>CFBundleDisplayName</key><string>Geode Checker</string>
    <key>CFBundleIdentifier</key><string>com.local.geodechecker</string>
    <key>CFBundleExecutable</key><string>GeodeChecker</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

echo "Compiling the app…"
swiftc -O -parse-as-library "$WORK/GeodeChecker.swift" -o "$APP/Contents/MacOS/GeodeChecker"

echo "Making the app icon…"
if swiftc -O "$WORK/icon/main.swift" -o "$WORK/makeicon" \
   && "$WORK/makeicon" "$WORK/AppIcon.iconset" \
   && iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "Icon created."
else
  echo "(Icon generation failed - the app will still work with the default icon.)"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"
rm -rf "$WORK"

echo "Done: $(pwd)/$APP"
echo "To uninstall later:  $0 --uninstall"
echo "Opening it now…"
open "$APP"
