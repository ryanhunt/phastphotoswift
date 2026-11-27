import Testing
@testable import PhastPhotoImaging

/// Ports of `test_ffscan.py:186-190` (dates) and `:193-197` (handwriting filter).
@Suite struct BackTextTests {
    @Test func datesWrittenOnBacks() {
        #expect(BackText.date(from: "Seaside, summer 1986")?.description == "1986")
        #expect(BackText.date(from: "14.7.1986 grandma")?.description == "1986-07-14")  // day first (European)
        #expect(BackText.date(from: "7/14/86")?.description == "1986-07-14")  // impossible as day-first: US order
        #expect(BackText.date(from: "08/1992")?.description == "1992-08")
        #expect(BackText.date(from: "no date here, 504 1111 N N") == nil)
    }

    @Test func dateParts() {
        #expect(BackText.date(from: "14.7.1986") == BackDate(year: 1986, month: 7, day: 14))
        #expect(BackText.date(from: "1986") == BackDate(year: 1986))
        #expect(BackText.date(from: "14-07-05") == BackDate(year: 1905, month: 7, day: 14))
        // out-of-range month-year ends the search; invalid day-month-year falls through to the next pattern
        #expect(BackText.date(from: "13/1992 1986") == nil)
        #expect(BackText.date(from: "31.31.1986") == nil)  // month-year matches "31.1986" and ends the search
        #expect(BackText.date(from: "13.13.99 in 1986")?.description == "1986")
        #expect(BackText.date(from: "5/1850") == nil)
    }

    @Test func labCodesAndWatermarksAreDropped() {
        for noise in ["Kodak", "5041111 NN N-12", "Kod", "•Kodak", "MADE IN GERMANY", "QUALITY PAPER", "AGRA", "akl",
                      "JAL3145(AX(NO 25 )058", "073 01** N N N N-232 (038)", "L3145CAXCNO.4A 2009", "[Kodak", "dak"] {
            #expect(BackText.humanText(noise) == "", Comment(rawValue: noise))
        }
    }

    @Test func handwritingIsKept() {
        for writing in ["Living room, 14.7.1986", "Seaside, summer 1986", "Mom 1986", "08/1992", "Dana and Yoni"] {
            #expect(BackText.humanText(writing) == writing, Comment(rawValue: writing))
        }
    }

    @Test func unicodeLettersCountAsWords() {
        #expect(BackText.humanText("Zoë und Jürgen") == "Zoë und Jürgen")
        #expect(BackText.humanText("Привет мир") == "Привет мир")
    }

    @Test func linesAreFilteredIndependentlyAndStripped() {
        let text = "Kodak\r\n  Mom 1986  \n504 1111\u{2028}Dana and Yoni\n"
        #expect(BackText.humanText(text) == "Mom 1986\nDana and Yoni")
        // the year lookbehind: a year glued to a dot is not standalone
        #expect(BackText.humanText("Mom .1986") == "")
        #expect(BackText.humanText("Mom 1986.") == "")
    }
}
