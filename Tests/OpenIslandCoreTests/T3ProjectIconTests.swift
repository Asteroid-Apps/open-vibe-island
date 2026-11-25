import Foundation
import Testing
@testable import OpenIslandCore

struct T3ProjectIconTests {
    @Test func defaultMonogramsAndColorsMatchT3IncludingUnicodeAndDigits() {
        let fixtures = [
            ("Open Vibe Island", "OI", "violet"), ("Example", "EE", "sky"), ("Demo", "DO", "violet"),
            ("Sample Project", "SP", "rose"), ("T3 Code", "T3", "pink"),
            ("Ｒ２Ｄ２", "R2", "purple"), ("日本語", "日語", "rose"), ("---", "PR", "cyan"), ("", "PR", "fuchsia")
        ]
        for (name, text, color) in fixtures {
            let icon = T3ProjectIcon.fallback(projectName: name)
            #expect(icon.kind == "monogram")
            #expect(icon.text == text)
            #expect(icon.color == color)
        }
    }

    @Test func nativeProjectAppearanceDecodesAndLegacySnapshotsRemainCompatible() throws {
        for json in [
            #"{"kind":"lucide","name":"rocket","color":"violet"}"#,
            #"{"kind":"monogram","text":"OI","color":"blue"}"#,
            #"{"kind":"emoji","emoji":"🚀"}"#
        ] {
            let project = try JSONDecoder().decode(T3Project.self, from: Data("{\"id\":\"p\",\"title\":\"Project\",\"workspaceRoot\":\"/tmp\",\"projectIcon\":\(json)}".utf8))
            #expect(project.projectIcon != nil)
            let metadata = T3SessionMetadata(projectName: project.title, projectIcon: project.projectIcon)
            #expect(!metadata.isEmpty)
            #expect(try JSONDecoder().decode(T3SessionMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
        }
        let legacy = try JSONDecoder().decode(T3Project.self, from: Data(#"{"id":"p","title":"Project","workspaceRoot":"/tmp"}"#.utf8))
        #expect(legacy.projectIcon == nil)
        #expect(legacy.faviconPath == nil)
    }
}
