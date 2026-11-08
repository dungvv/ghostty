import Foundation

/// Split and join argument lists the way a shell would, so users can type
/// extra ssh flags naturally (including quoted values with spaces).
enum ShellWords {
    static func split(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch)
                hasCurrent = true
                escaped = false
                continue
            }

            if ch == "\\" && quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }

            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                hasCurrent = true
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                hasCurrent = true
                continue
            }

            if ch == " " || ch == "\t" || ch == "\n" {
                if hasCurrent {
                    words.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }

            current.append(ch)
            hasCurrent = true
        }

        if hasCurrent { words.append(current) }
        return words
    }

    static func join(_ words: [String]) -> String {
        words.map { word in
            let needsQuoting = word.isEmpty || word.contains(where: {
                " \t\n\"'\\$`&|;<>()*?[]{}#~".contains($0)
            })
            return needsQuoting ? word.shellQuoted : word
        }.joined(separator: " ")
    }
}
