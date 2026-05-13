import Foundation
import AppKit
import SwiftUI

/// Models the per-row metadata declared in `pet.json` (hatch-pet skill).
///
/// The skill documents an array of named rows; the canonical order is
/// (idle, waving, jumping, failed, review, running-right, running-left, ...).
/// We treat the JSON as the source of truth — falling back to a sensible
/// default ordering if a key is missing.
struct PetMetadata: Decodable {
    let rows: [String]
    let cols: Int
    let cellWidth: Int
    let cellHeight: Int

    enum CodingKeys: String, CodingKey {
        case rows
        case cols
        case columns
        case cellWidth = "cell_width"
        case cellHeight = "cell_height"
        case frameWidth = "frame_width"
        case frameHeight = "frame_height"
        case animations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Rows can be either a [String] field, or a list of objects under `animations`.
        if let names = try? c.decode([String].self, forKey: .rows) {
            self.rows = names
        } else if let anim = try? c.decode([PetAnimation].self, forKey: .animations) {
            self.rows = anim.map { $0.name }
        } else {
            self.rows = PetMetadata.defaultRows
        }

        self.cols = (try? c.decode(Int.self, forKey: .cols))
            ?? (try? c.decode(Int.self, forKey: .columns))
            ?? 8
        self.cellWidth = (try? c.decode(Int.self, forKey: .cellWidth))
            ?? (try? c.decode(Int.self, forKey: .frameWidth))
            ?? 192
        self.cellHeight = (try? c.decode(Int.self, forKey: .cellHeight))
            ?? (try? c.decode(Int.self, forKey: .frameHeight))
            ?? 208
    }

    static let defaultRows: [String] = [
        "idle", "waving", "jumping", "failed", "review",
        "running-right", "running-left", "sleeping", "celebrating"
    ]

    static let fallback = PetMetadata(rows: defaultRows, cols: 8, cellWidth: 192, cellHeight: 208)

    private init(rows: [String], cols: Int, cellWidth: Int, cellHeight: Int) {
        self.rows = rows
        self.cols = cols
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }
}

private struct PetAnimation: Decodable {
    let name: String
}

/// Slices a hatch-pet spritesheet into `[row][col]` NSImage frames.
///
/// Resolution order (see `load(customSpritePath:)`):
///   1. The user's custom sprite directory (`AgentProfile.spritePath`), if set
///      and readable. Intended for power users running the hatch-pet skill
///      themselves in Codex CLI and pointing here at `~/.codex/pets/<slug>/`.
///   2. The app-bundled default at `Resources/pets/zen-robot/` (shipped with
///      the DMG — no Codex setup needed for a working pet).
///   3. A gradient placeholder, as a last resort when the bundle is missing
///      its resources (unusual; mostly relevant during early dev).
final class SpriteAtlas {
    let metadata: PetMetadata
    let frames: [[NSImage]]
    let isPlaceholder: Bool

    /// Slug of the bundled atlas that ships inside the .app — the default
    /// pet when the user hasn't pointed at a custom sprite path.
    static let bundledDefaultSlug = "zen-robot"

    private init(metadata: PetMetadata, frames: [[NSImage]], placeholder: Bool) {
        self.metadata = metadata
        self.frames = frames
        self.isPlaceholder = placeholder
    }

    /// URL of a bundled sprite atlas (e.g. "zen-robot") shipped inside
    /// `Resources/pets/<slug>/`. Returns nil if the folder isn't present
    /// in the running app bundle (only happens in non-Xcode builds).
    static func bundledSpritePath(slug: String) -> URL? {
        Bundle.main.url(forResource: "pets/\(slug)", withExtension: nil)
    }

    /// Walks the fallback chain documented at the top of the file. A nil or
    /// empty `customSpritePath` means "no override — use the bundled default."
    static func load(customSpritePath: String?) -> SpriteAtlas {
        if let custom = customSpritePath?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            let url = URL(
                fileURLWithPath: (custom as NSString).expandingTildeInPath,
                isDirectory: true
            )
            if let atlas = load(directory: url) {
                return atlas
            }
            NSLog("[ductor] custom sprite path \(custom) missing or unreadable — using bundled default.")
        }
        if let bundled = bundledSpritePath(slug: bundledDefaultSlug),
           let atlas = load(directory: bundled) {
            return atlas
        }
        return placeholder(using: .fallback)
    }

    /// Attempt to slice a sprite atlas from a specific directory. Returns
    /// nil when the spritesheet is missing/unreadable so callers can move
    /// down the fallback chain.
    private static func load(directory: URL) -> SpriteAtlas? {
        let sheetURL = directory.appendingPathComponent("spritesheet.webp")
        let jsonURL = directory.appendingPathComponent("pet.json")

        let metadata: PetMetadata = {
            guard let data = try? Data(contentsOf: jsonURL),
                  let m = try? JSONDecoder().decode(PetMetadata.self, from: data)
            else { return .fallback }
            return m
        }()

        guard let image = NSImage(contentsOf: sheetURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let rows = metadata.rows.count
        let cols = metadata.cols
        let cellW = metadata.cellWidth
        let cellH = metadata.cellHeight

        var grid: [[NSImage]] = []
        grid.reserveCapacity(rows)

        for r in 0..<rows {
            var rowFrames: [NSImage] = []
            for c in 0..<cols {
                let rect = CGRect(x: c * cellW, y: r * cellH, width: cellW, height: cellH)
                if let cropped = cg.cropping(to: rect) {
                    rowFrames.append(NSImage(
                        cgImage: cropped,
                        size: NSSize(width: cellW, height: cellH)
                    ))
                }
            }
            if !rowFrames.isEmpty { grid.append(rowFrames) }
        }
        guard !grid.isEmpty else { return nil }
        return SpriteAtlas(metadata: metadata, frames: grid, placeholder: false)
    }

    /// Resolves a logical row name (e.g. "idle", "waving") to its numeric index,
    /// returning 0 when the name isn't declared in the atlas.
    func rowIndex(named name: String) -> Int {
        let lower = name.lowercased()
        if let idx = metadata.rows.firstIndex(where: { $0.lowercased() == lower }) {
            return idx
        }
        // Common aliases the rest of the app uses
        let aliases: [String: [String]] = [
            "idle": ["idle", "rest", "default"],
            "waving": ["waving", "wave", "hello", "speaking", "talking"],
            "running": ["running-right", "running", "run", "running-left"],
            "celebrating": ["celebrating", "celebrate", "happy"],
        ]
        if let candidates = aliases[lower] {
            for alt in candidates {
                if let idx = metadata.rows.firstIndex(where: { $0.lowercased() == alt }) {
                    return idx
                }
            }
        }
        return 0
    }

    func frames(for rowName: String) -> [NSImage] {
        let idx = rowIndex(named: rowName)
        guard idx < frames.count else { return frames.first ?? [] }
        return frames[idx]
    }

    // MARK: - Placeholder

    private static func placeholder(using metadata: PetMetadata) -> SpriteAtlas {
        let cellW = metadata.cellWidth
        let cellH = metadata.cellHeight
        let frame = NSImage(size: NSSize(width: cellW, height: cellH))
        frame.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: cellW, height: cellH)
        let gradient = NSGradient(starting: NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1.0),
                                  ending: NSColor(red: 0.30, green: 0.40, blue: 0.78, alpha: 1.0))
        gradient?.draw(in: rect, angle: 90)
        let glyph = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                            accessibilityDescription: nil)
        if let glyph = glyph {
            let g = glyph.copy() as! NSImage
            g.isTemplate = false
            let size = CGFloat(min(cellW, cellH)) * 0.6
            let origin = NSPoint(x: (CGFloat(cellW) - size) / 2,
                                 y: (CGFloat(cellH) - size) / 2)
            NSColor.white.set()
            g.draw(in: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 0.85)
        }
        frame.unlockFocus()
        let single = Array(repeating: frame, count: max(metadata.cols, 1))
        let grid = Array(repeating: single, count: max(metadata.rows.count, 1))
        return SpriteAtlas(metadata: metadata, frames: grid, placeholder: true)
    }
}
