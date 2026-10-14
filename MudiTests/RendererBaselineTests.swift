import CryptoKit
import GhosttyVt
import SwiftTerm
import UIKit
import XCTest
@testable import Mudi

/// Informational benchmark. Excluded from normal runs unless explicitly opted in.
/// Offscreen CPU raster duration and display-link opportunity cadence are separate;
/// neither is GPU time or proof of a presented frame.
@MainActor
final class RendererBaselineTests: XCTestCase {
    struct CorpusEntry: Decodable { let file: String; let sha256: String; let bytes: Int }
    struct Manifest: Decodable { let version: Int; let corpora: [CorpusEntry] }

    func testCorpusHashesAndCrossEngineSemanticCells() throws {
        let (_, corpora) = try loadCorpus()
        let vt = try GhosttyVTView(configuration: .init(columns: 40, rows: 12, maxScrollback: 1_000))
        let swift = ShellTerminalView(frame: .zero)
        defer { swift.stop() }
        swift.resize(cols: 40, rows: 12)
        // UTF-8 + control sequences deliberately split one byte at a time.
        for byte in try XCTUnwrap(corpora["mixed.vt"]) {
            _ = try vt.feed(Data([byte]))
            swift.feed(byteArray: [byte][...])
        }
        let parsed = swift.getTerminal()
        for row in 0..<4 {
            let expected = vt.screen.rows[row]?.cells.filter { $0.width != .spacerTail && $0.width != .spacerHead && !$0.text.isEmpty } ?? []
            for cell in expected {
                let other = try XCTUnwrap(parsed.getCharData(col: Int(cell.column), row: row))
                XCTAssertEqual(String(parsed.getCharacter(for: other)), cell.text, "row \(row) col \(cell.column)")
                XCTAssertEqual(Int(other.width), cell.width == .wide ? 2 : 1)
                switch cell.style.foreground {
                case .palette(let index): XCTAssertEqual(other.attribute.fg, .ansi256(code: UInt8(index)))
                case .rgb(let color): XCTAssertEqual(other.attribute.fg, .trueColor(red: color.red, green: color.green, blue: color.blue))
                default: break
                }
            }
        }
        XCTAssertTrue(vt.screen.rows[3]?.cells.first?.style.underline != nil)
        let underline = try XCTUnwrap(parsed.getCharData(col: 0, row: 3))
        XCTAssertTrue(underline.attribute.style.contains(.underline))
        // This asserts parser metadata, not that Ghostty's draw implements decoration.
    }

    func testReplayPerformanceBaseline() async throws {
        guard ProcessInfo.processInfo.environment["MUDI_RENDERER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MUDI_RENDERER_BENCHMARK=1 for the informational replay baseline")
        }
        let (manifest, corpora) = try loadCorpus()
        let started = Date()
        var runs: [[String: Any]] = []
        let workloads = ["static-mixed", "log-burst", "log-10hz", "log-30hz", "log-60hz", "tui-30hz", "scroll-60hz", "resize", "theme", "font", "local-input-echo"]
        // Interleave engines by repetition to avoid systematically giving one the
        // colder environment. Each warm-up is a fresh terminal just like each run.
        for workload in workloads {
            for repetition in 0..<10 {
                let engines = repetition.isMultiple(of: 2) ? ["ghostty", "swiftterm"] : ["swiftterm", "ghostty"]
                for engine in engines {
                    let result = try await replay(engine: engine, workload: workload, corpora: corpora, repetition: repetition - 5)
                    runs.append(result)
                }
            }
        }
        var summary: [[String: Any]] = []
        for workload in workloads {
            for engine in ["ghostty", "swiftterm"] {
                let selected = runs.filter { $0["engine"] as? String == engine && $0["workload"] as? String == workload }
                let stages = Set(selected.flatMap { ($0["metrics_ms"] as? [String: Double] ?? [:]).keys })
                var metrics: [String: Any] = [:]
                for stage in stages {
                    let values = selected.compactMap { ($0["metrics_ms"] as? [String: Double])?[stage] }.sorted()
                    metrics[stage] = ["p50": percentile(values, 0.5), "p95": percentile(values, 0.95), "per_run": values]
                }
                summary.append(["engine": engine, "workload": workload, "metrics_ms": metrics])
            }
        }
        let environment: [String: Any] = [
            "device": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
            "simulator_name": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "kind": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil ? "device-reference" : "simulator",
            "os_version": UIDevice.current.systemVersion,
            "host_arch": "arm64", "configuration": "Release", "coverage": false,
            "grid": [40, 12], "viewport_points": [400, 260], "font": "JetBrainsMono Nerd Font Mono 14",
            "theme": TerminalThemeRegistry.builtInThemes[0].name,
            "scrollback_limit": 1_000,
            "git_commit": ProcessInfo.processInfo.environment["MUDI_BENCHMARK_COMMIT"] ?? "unrecorded",
            "xcode": ProcessInfo.processInfo.environment["MUDI_BENCHMARK_XCODE"] ?? "unrecorded",
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "warmup_runs_per_engine_workload": 5, "measured_runs_per_engine_workload": 5,
            "corpus_version": manifest.version,
            "corpora": manifest.corpora.map { ["file": $0.file, "sha256": $0.sha256, "bytes": $0.bytes] as [String: Any] },
            "started": ISO8601DateFormatter().string(from: started), "ended": ISO8601DateFormatter().string(from: Date())
        ]
        let report: [String: Any] = ["schema_version": 1, "environment": environment, "runs": runs, "summary": summary,
            "percentile_method": "linear interpolation between closest ranks (numpy linear); p50 is the interpolated median",
            "limitations": ["draw_total_inclusive includes CoreText construction; do not add these metrics together",
                             "SwiftTerm public feed combines parser/display scheduling; cache and CoreText stages unavailable separately without patching dependency",
                             "CPU raster is explicit UIView.layer.render, not a presented frame; display_link_intervals describe opportunities, not renderer FPS or GPU duration",
                             "local-input-echo is controlled immediate local echo, not network or remote key-to-pixel latency",
                             "footprint samples are process-wide, sampled after workload operations; sampled maximum is not an allocation peak",
                             "fixed logical grid and viewport; engine cell metrics recorded separately; no arbitrary cell-size override"]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "renderer-baseline-v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RENDERER_BASELINE_JSON:" + String(decoding: data, as: UTF8.self))
    }

    private func replay(engine: String, workload: String, corpora: [String: Data], repetition: Int) async throws -> [String: Any] {
        let start = Date()
        let probe = RendererPerformanceProbe()
        let vt = engine == "ghostty" ? try GhosttyVTView(configuration: .init(columns: 40, rows: 12, maxScrollback: 1_000)) : nil
        let swift = engine == "swiftterm" ? ShellTerminalView(frame: .zero) : nil
        let view: UIView = vt ?? swift!
        let window = Phase7TerminalScreenHarness.makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 260)
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        let host = (view as! any TerminalHost)
        host.shortcutBar?.isHidden = true
        host.updateFont(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: 14)
        try host.apply(theme: TerminalThemeRegistry.builtInThemes[0])
        view.layoutIfNeeded()
        swift?.changeScrollback(1_000)
        swift?.getTerminal().resize(cols: 40, rows: 12)
        try vt?.terminal.resize(to: .init(columns: 40, rows: 12))
        try vt?.refresh()
        vt?.performanceProbe = probe
        let display = BaselineDisplayCadence()
        display.start()
        defer {
            display.stop(); host.stop(); view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        }
        let memoryStart = baselineFootprint()
        var footprintSamples = [memoryStart]
        var metrics: [String: Double] = [:]
        var writes: [Double] = []
        let monotonicStart = CACurrentMediaTime()
        let raster = UIGraphicsImageRenderer(size: view.bounds.size)
        func feed(_ bytes: Data) throws {
            let time = CACurrentMediaTime()
            if let vt { _ = try vt.feed(bytes) }
            else { swift!.feed(byteArray: Array(bytes)[...]) }
            metrics[engine == "ghostty" ? "host_feed_total" : "swift_feed_combined", default: 0] += (CACurrentMediaTime() - time) * 1_000
            writes.append((time - monotonicStart) * 1_000)
        }
        func paint() {
            let time = CACurrentMediaTime()
            _ = raster.image { view.layer.render(in: $0.cgContext) }
            metrics["cpu_layer_raster_total", default: 0] += (CACurrentMediaTime() - time) * 1_000
            footprintSamples.append(baselineFootprint())
        }
        let rate: Double
        if workload == "static-mixed" {
            rate = 0
            try feed(corpora["mixed.vt"]!)
            for _ in 0..<6 { view.setNeedsDisplay(); paint() }
        } else if workload == "log-burst" {
            rate = 0
            for chunk in String(decoding: corpora["logs.vt"]!, as: UTF8.self).components(separatedBy: "\r\n").filter({ !$0.isEmpty }) {
                try feed(Data((chunk + "\r\n").utf8))
            }
            // Both views need their production display-scheduling work to run
            // before the explicit CPU raster. This wait is separately disclosed.
            try await Task.sleep(for: .milliseconds(1))
            paint()
        } else if workload.hasPrefix("log-") {
            rate = Double(workload.dropFirst(4).dropLast(2))!
            let lines = String(decoding: corpora["logs.vt"]!, as: UTF8.self).components(separatedBy: "\r\n").prefix(12)
            for (index, line) in lines.enumerated() {
                let due = monotonicStart + Double(index) / rate
                let wait = max(0, due - CACurrentMediaTime())
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                try feed(Data((line + "\r\n").utf8))
                try await Task.sleep(for: .milliseconds(1)); paint()
            }
        } else if workload == "tui-30hz" {
            rate = 30
            let frames = String(decoding: corpora["overwrite.vt"]!, as: UTF8.self).components(separatedBy: "\u{1b}[H").dropFirst()
            for (index, frame) in frames.enumerated() {
                let wait = max(0, monotonicStart + Double(index) / rate - CACurrentMediaTime())
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                try feed(Data(("\u{1b}[H" + frame).utf8))
                try await Task.sleep(for: .milliseconds(1)); paint()
            }
        } else if workload == "scroll-60hz" {
            rate = 60
            try feed(corpora["logs.vt"]!)
            for index in 0..<12 {
                let wait = max(0, monotonicStart + Double(index) / rate - CACurrentMediaTime())
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let time = CACurrentMediaTime()
                if let vt { try vt.terminal.scroll(to: .row(index * 10)); try vt.refresh() }
                else { swift!.scrollTo(row: index * 10, notifyAccessibility: false) }
                metrics["scroll_update", default: 0] += (CACurrentMediaTime() - time) * 1_000
                writes.append((time - monotonicStart) * 1_000); paint()
            }
        } else {
            rate = 0
            try feed(corpora["mixed.vt"]!)
            let operationStart = CACurrentMediaTime()
            switch workload {
            case "resize":
                for columns in [48, 30, 40] {
                    if let vt { try vt.terminal.resize(to: .init(columns: UInt16(columns), rows: 12)); try vt.refresh() }
                    else { swift!.getTerminal().resize(cols: columns, rows: 12) }
                    view.setNeedsDisplay(); paint()
                }
            case "theme":
                for theme in TerminalThemeRegistry.builtInThemes.prefix(3) { try host.apply(theme: theme); view.setNeedsDisplay(); paint() }
            case "font":
                for size in [16.0, 12.0, 14.0] { host.updateFont(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: size); view.layoutIfNeeded(); paint() }
            default:
                let inputStart = CACurrentMediaTime()
                if let vt { vt.onInput = { _ in } }
                host.insertText("a")
                try feed(Data("a".utf8)); paint()
                metrics["controlled_input_to_raster", default: 0] += (CACurrentMediaTime() - inputStart) * 1_000
            }
            metrics["operation_total_inclusive"] = (CACurrentMediaTime() - operationStart) * 1_000
        }
        // Allow pending production UIKit redraws and display link callbacks to run.
        try await Task.sleep(for: .milliseconds(50))
        display.stop()
        for (stage, values) in probe.milliseconds { metrics[stage] = values.reduce(0, +) }
        if let draw = metrics["draw_total_inclusive"] {
            metrics["draw_excluding_coretext_construct"] = max(0, draw - (metrics["coretext_construct"] ?? 0))
        }
        let intervals = zip(writes.dropFirst(), writes).map { $0 - $1 }
        let end = Date()
        return ["engine": engine, "workload": workload, "repetition": repetition,
                "started": ISO8601DateFormatter().string(from: start), "ended": ISO8601DateFormatter().string(from: end),
                "metrics_ms": metrics, "operations": writes.count, "declared_hz": rate,
                "delivered_intervals_ms": intervals, "schedule_deviation_ms": rate > 0 ? intervals.map { $0 - 1_000 / rate } : [],
                "display_link_intervals_ms": display.intervals,
                "display_link_late_intervals": display.lateIntervals,
                "footprint_start_bytes": memoryStart, "footprint_samples_bytes": footprintSamples,
                "footprint_sampled_max_delta_bytes": max(0, (footprintSamples.max() ?? memoryStart) - memoryStart),
                "glyph_construct_count": probe.milliseconds["coretext_construct"]?.count ?? NSNull() as Any,
                "cell_points": vt.map { [Double($0.cellSize.width), Double($0.cellSize.height)] } ?? [Double(view.bounds.width) / Double(swift!.getTerminal().cols), Double(view.bounds.height) / Double(swift!.getTerminal().rows)],
                "raw_probe_samples_ms": probe.milliseconds,
                "draw_observations": probe.milliseconds["draw_total_inclusive"]?.count ?? 0,
                "buffered_display_flush_delay_ms": workload.hasPrefix("log-") || workload.hasPrefix("tui-") ? 1 : 0,
                "terminal_rows": vt.map { Int($0.screen.size.rows) } ?? swift!.getTerminal().rows]
    }
    private func loadCorpus() throws -> (Manifest, [String: Data]) {
        let bundle = Bundle(for: Self.self)
        let root = bundle.url(forResource: "RendererCorpus", withExtension: nil)?.appendingPathComponent("v1") ?? bundle.resourceURL!
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var corpora: [String: Data] = [:]
        for entry in manifest.corpora {
            let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
            XCTAssertEqual(bytes.count, entry.bytes)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), entry.sha256)
            corpora[entry.file] = bytes
        }
        return (manifest, corpora)
    }
    /// Linear-interpolated percentile (numpy "linear" method). Fixed and
    /// documented so odd/even sample counts cannot silently change the
    /// estimator: p50 of [a,b] is the midpoint, not the lower sample.
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

@MainActor
private final class BaselineDisplayCadence: NSObject {
    var intervals: [Double] = []
    var lateIntervals = 0
    private var last: CFTimeInterval?
    private var link: CADisplayLink?
    func start() { let link = CADisplayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            let interval = link.timestamp - last
            intervals.append(interval * 1_000)
            let expected = link.targetTimestamp - link.timestamp
            if interval > expected * 1.5 { lateIntervals += 1 }
        }
        last = link.timestamp
    }
}

private func baselineFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
