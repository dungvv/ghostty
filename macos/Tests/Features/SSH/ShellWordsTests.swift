import Foundation
import Testing
@testable import Ghostty

@Suite
struct ShellWordsTests {
    @Test
    func splitsOnWhitespace() {
        #expect(ShellWords.split("-v -o Compression=yes")
                == ["-v", "-o", "Compression=yes"])
    }

    @Test
    func keepsQuotedValuesTogether() {
        #expect(ShellWords.split("-o \"ProxyCommand=nc %h %p\"")
                == ["-o", "ProxyCommand=nc %h %p"])
        #expect(ShellWords.split("'single quoted'") == ["single quoted"])
    }

    @Test
    func handlesEscapes() {
        #expect(ShellWords.split("a\\ b") == ["a b"])
        #expect(ShellWords.split("'a\\b'") == ["a\\b"])
    }

    @Test
    func roundTrips() {
        let words = ["-o", "ProxyCommand=nc %h %p", "-v"]
        #expect(ShellWords.split(ShellWords.join(words)) == words)
    }

    @Test
    func ignoresExtraWhitespace() {
        #expect(ShellWords.split("   -v   ") == ["-v"])
        #expect(ShellWords.split("") == [])
    }
}
