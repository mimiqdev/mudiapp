import Foundation

/// Captured from `herdr terminal session observe w55:p1 --cols 20 --rows 5`.
/// The command was run without `--takeover`; this is a real terminal.frame
/// envelope emitted by the installed Herdr 0.8.2 binary.
enum Phase4HerdrTerminalFixtures {
    static let observedFullFrame = [
        #"{"bytes":"G1s/MjAyNmgbWz8yNWwbXTg7OxtcG1syShtbMTsxSBtbMDszOTs0ODsyOzI"#,
        #"zMjsyNDA7MjMybSAbWzA7MTszODsyOzMxOzM1OzQwOzQ4OzI7MjMyOzI0MDsyMzJtU3dpd"#,
        #"GNoaW5nIERhcmsvTGlnaBtbMjsxSBtbMDszOTs0ODsyOzI"#,
        #"zMjsyNDA7MjMybSAbWzA7MTszODsyOzMxOzM1OzQwOzQ4OzI7MjMyOzI0MDsyMzJtU2V0d"#,
        #"GluZ3Mgc2hlZXQgdW50aRtbMzsxSBtbMDszOTs0ODsyOzI"#,
        #"zMjsyNDA7MjMybSAbWzA7MTszODsyOzMxOzM1OzQwOzQ4OzI7MjMyOzI0MDsyMzJtRU9GG"#,
        #"1swOzM4OzI7MzE7MzU7NDA7NDg7MjsyMzI7MjQwOzI"#,
        #"zMm0gICAgICAgICAgICAgICAgG1s0OzFIG1swOzM5OzQ4OzI7MjMyOzI0MDsyMzJtIBtbM"#,
        #"DsxOzM4OzI7MzE7MzU7NDA7NDg7MjsyMzI7MjQwOzI"#,
        #"zMm0pIhtbMDszODsyOzMxOzM1OzQwOzQ4OzI7MjMyOzI0MDsyMzJtICAgICAgICAgICAgI"#,
        #"CAgICAbWzU7MUgbWzA7Mzk7NDg7MjsyMzI7MjQwOzI"#,
        #"zMm0gG1swOzE7Mzg7MjszMTszNTs0MDs0ODsyOzI"#,
        #"zMjsyNDA7MjMybXFpbmcgcmVtb3ZlIHBoYXNlNC0bWzBtG1s1OzIwSBtbPzI1bBtbPzIwM"#,
        #"jZsG1s1OzIwSBtbPzI1bA==","encoding":"ansi","full":true,"height":5,"seq"#,
        #"":1,"type":"terminal.frame","width":20}"#
    ].joined()
}
