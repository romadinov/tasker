import Foundation
import Testing
@testable import TaskerCore

@Suite struct FractionalIndexTests {
    @Test func betweenIsStrictlyOrdered() {
        var rng = SeededRNG(state: 42)
        var keys = [FractionalIndex.between(nil, nil)]
        for _ in 0..<2000 {
            let i = Int.random(in: 0...keys.count, using: &rng)
            let a = i > 0 ? keys[i - 1] : nil
            let b = i < keys.count ? keys[i] : nil
            let k = FractionalIndex.between(a, b)
            if let a { #expect(a < k) }
            if let b { #expect(k < b) }
            #expect(k.last != "0")
            keys.insert(k, at: i)
        }
        #expect(keys == keys.sorted())
    }

    @Test func evenlySpacedKeysAreSortedAndShort() {
        for n in [1, 2, 10, 61, 62, 500, 5000] {
            let k = FractionalIndex.evenlySpaced(n)
            #expect(k.count == n)
            #expect(k == k.sorted())
            #expect(Set(k).count == n)
            #expect(k.allSatisfy { $0.last != "0" && $0.count <= 4 })
        }
    }
}

@Suite struct RRuleTests {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Moscow")!; c.firstWeekday = 2; return c }()
    func d(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    @Test func daily() { #expect(RRule("FREQ=DAILY;INTERVAL=2").next(after: d("2026-10-16 17:00"), calendar: cal) == d("2026-10-18 17:00")) }
    @Test func weeklyByDay() {
        // Friday -> next Monday or Wednesday
        #expect(RRule("FREQ=WEEKLY;BYDAY=MO,WE").next(after: d("2026-10-16 09:00"), calendar: cal) == d("2026-10-19 09:00"))
        #expect(RRule("FREQ=WEEKLY;BYDAY=MO,WE").next(after: d("2026-10-19 09:00"), calendar: cal) == d("2026-10-21 09:00"))
    }
    @Test func monthlyLastDay() {
        #expect(RRule("FREQ=MONTHLY;BYMONTHDAY=-1").next(after: d("2026-10-31 10:00"), calendar: cal) == d("2026-11-30 10:00"))
    }
    @Test func monthlySecondTuesday() {
        #expect(RRule("FREQ=MONTHLY;BYDAY=2TU").next(after: d("2026-10-16 10:00"), calendar: cal) == d("2026-11-10 10:00"))
    }
    @Test func monthlyPlain() { #expect(RRule("FREQ=MONTHLY").next(after: d("2026-01-31 10:00"), calendar: cal) == d("2026-02-28 10:00")) }
    @Test func roundTrip() { #expect(RRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR").string == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR") }
}

@Suite struct CodecTests {
    @Test func batchRoundTrip() throws {
        let ops = (1...100).map { i in
            Op(replica: "abcDEF12345", counter: Int64(i), hlc: HLC(ms: 1_700_000_000_000 + Int64(i), c: 0, replica: "abcDEF12345"),
               type: .task, id: "t\(i % 7)", field: F.title, value: .string("Задача \(i)"))
        }
        let data = try OpBatchCodec.encode(ops)
        #expect(try OpBatchCodec.decode(data) == ops)
        let name = OpBatchCodec.recordName(replica: "abcDEF12345", first: 1, last: 100)
        let parsed = OpBatchCodec.parseRecordName(name)
        #expect(parsed?.replica == "abcDEF12345" && parsed?.first == 1 && parsed?.last == 100)
        #expect(OpBatchCodec.parseRecordName("h_abc") == nil)
    }

    @Test func hlcOrderingAndClock() {
        var c = HLCClock(replica: "r")
        let a = c.tick(now: 1000), b = c.tick(now: 1000), d = c.tick(now: 999)
        #expect(a < b && b < d)
        c.observe(HLC(ms: 5000, c: 3, replica: "x"), now: 1000)
        #expect(HLC(ms: 5000, c: 3, replica: "x") < c.tick(now: 1000))
    }
}

@Suite struct QuickEntryTests {
    @Test func parsesShorthand() throws {
        let s = try tempStore()
        s.transact { tx in
            tx.createTag("Errands", id: "tg1")
            var p = NewTask(title: "Home Renovation"); p.isProject = true
            tx.createTask(p, id: "p1")
        }
        let now = Date()
        let r = QuickEntryParser(snapshot: s.snapshot(), now: now).parse("Buy paint #err ::home ! due:tomorrow ~30m #newtag")
        #expect(r.title == "Buy paint")
        #expect(r.tagIDs == ["tg1"])
        #expect(r.unknownTags == ["newtag"])
        #expect(r.projectID == "p1")
        #expect(r.flagged)
        #expect(r.estimatedMinutes == 30)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        #expect(r.dueDate == Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow))
    }
}

@Suite struct AvailabilityTests {
    @Test func sequentialProjectsBlockLaterActions() throws {
        let s = try tempStore()
        s.transact { tx in
            var p = NewTask(title: "Seq"); p.isProject = true; p.sequential = true
            tx.createTask(p, id: "P")
            for i in 1...3 { var n = NewTask(title: "Step \(i)"); n.parent = "P"; tx.createTask(n, id: "S\(i)") }
            tx.createTag("Waiting", id: "W")
            var w = NewTask(title: "Inbox thing"); w.tagIDs = ["W"]
            tx.createTask(w, id: "I")
            tx.setTagStatus("W", .onHold)
        }
        var snap = s.snapshot()
        #expect(snap.info["S1"]?.isAvailable == true)
        #expect(snap.info["S1"]?.isFirstAvailable == true)
        #expect(snap.info["S2"]?.isAvailable == false)
        #expect(snap.info["S2"]?.isBlocked == true)
        #expect(snap.info["I"]?.isAvailable == false) // on-hold tag
        s.transact { $0.complete("S1") }
        snap = s.snapshot()
        #expect(snap.info["S2"]?.isAvailable == true)
        #expect(snap.info["S1"]?.isRemaining == false)
    }

    @Test func perspectiveRulesInOmniFocusDialect() throws {
        let s = try tempStore()
        s.transact { tx in
            tx.createTag("Office", id: "office")
            var a = NewTask(title: "Flagged office"); a.flagged = true; a.tagIDs = ["office"]
            tx.createTask(a, id: "A")
            tx.createTask(NewTask(title: "Plain"), id: "B")
        }
        var p = Perspective(id: "x")
        p.rules = [
            .object(["actionAvailability": "available"]),
            .object(["aggregateType": "any", "aggregateRules": .array([.object(["actionHasTagWithStatus": "active"]), .object(["actionIsUntagged": true])])]),
            .object(["actionStatus": "flagged"]),
        ]
        let engine = PerspectiveEngine(s.snapshot())
        #expect(engine.evaluate(p).flatMap(\.taskIDs) == ["A"])
        p.rules = [.object(["actionHasAnyOfTags": .array(["office"])])]
        p.aggregation = "none"
        #expect(engine.evaluate(p).flatMap(\.taskIDs) == ["B"])
    }
}

@Suite struct ProjectPathTests {
    @Test func createAndMatchFolderProjectPaths() throws {
        let s = try tempStore()
        s.transact { tx in tx.createFolder("Common", id: "fc") }
        var id = ""
        s.transact { tx in id = tx.createProject(path: "Common : Домашние дела") }
        var snap = s.snapshot()
        #expect(snap.projectInfo[id]?.folderID == "fc")           // reused existing folder
        #expect(snap.qualifiedName(of: id) == "Common : Домашние дела")
        #expect(snap.project(atPath: "common:домашние дела")?.id == id)
        // Nested, with missing folders created once.
        var a = "", b = ""
        s.transact { tx in a = tx.createProject(path: "Work : Clients : Acme"); b = tx.createProject(path: "Work : Clients : Beta") }
        snap = s.snapshot()
        #expect(snap.folderPath(of: a) == ["Work", "Clients"])
        #expect(snap.projectInfo[a]?.folderID == snap.projectInfo[b]?.folderID)
        #expect(snap.folders.values.filter { $0.name == "Work" }.count == 1)
        // Quick entry shorthand.
        let r = QuickEntryParser(snapshot: snap).parse("Buy bread ::Common:Домашние_дела")
        #expect(r.projectID == id)
        #expect(r.title == "Buy bread")
    }
}

@Suite struct FuzzyTests {
    // Match text is "title  folder path" (title first, so it carries the most weight).
    let projects = ["Новые тулы в тулбокс  Самообразование", "SEEK  Работа", "Рутина  Работа", "Домашняя рутина  Common",
                    "Дема для SF  Работа", "Гитара  Common", "Важная рутина  High", "Программирование  Common"]

    func top(_ q: String) -> String? { Fuzzy.rank(projects, q) { $0 }.first }

    @Test func subsequenceAndWordStarts() {
        #expect(top("тлб") == "Новые тулы в тулбокс  Самообразование")
        #expect(top("нтт") == "Новые тулы в тулбокс  Самообразование")
        #expect(top("дем") == "Дема для SF  Работа")
        #expect(top("гит") == "Гитара  Common")
        #expect(top("seek") == "SEEK  Работа")
    }

    @Test func prefixBeatsScattered() {
        // "рут" should prefer a word starting with рут over scattered letters.
        let r = Fuzzy.rank(projects, "рут") { $0 }
        #expect(r.first?.hasPrefix("Рутина") == true)
    }

    @Test func typoTolerance() {
        // One letter not present (the user's example): still finds the toolbox project.
        #expect(Fuzzy.rank(projects, "Трр") { $0 }.contains("Новые тулы в тулбокс  Самообразование"))
        #expect(top("тулбкос") == "Новые тулы в тулбокс  Самообразование") // transposition-ish typo
    }

    @Test func wrongKeyboardLayout() {
        #expect(top("nekb") == "Новые тулы в тулбокс  Самообразование") // "тулы" typed with EN layout
        #expect(top("ubnf") == "Гитара  Common")
    }

    @Test func typedLayoutBeatsWrongLayoutReading() {
        let items = ["Я хочу понять dynamic algorithms  Самообразование", "Новые тулы в тулбокс  Самообразование"]
        #expect(Fuzzy.rank(items, "нт") { $0 }.first == "Новые тулы в тулбокс  Самообразование")
    }

    @Test func noMatchForGarbage() {
        #expect(Fuzzy.score("щщщщщщ", "Гитара  Common") == nil)
    }
}

@Suite struct LayoutTests {
    @Test func searchInEitherLayout() {
        #expect(Fuzzy.containsAllWords("ubnfhf", in: "Купить струны для гитары") == false) // "гитара" ≠ "гитары"
        #expect(Fuzzy.containsAllWords("ubnfh", in: "Купить струны для гитары"))          // "гитар"
        #expect(Fuzzy.containsAllWords("руддщ", in: "Say hello to Anna"))                  // RU layout typed for "hello"
        #expect(Fuzzy.containsAllWords("Struny", in: "Купить струны") == false)            // transliteration isn't layout
        #expect(Fuzzy.containsAllWords("ЕРУ ыщгксу", in: "Learn the SOURCE"))             // both words typed on RU layout
        #expect(Fuzzy.containsAllWords("еру source", in: "Learn the SOURCE"))             // switched layout mid-query
    }

    @Test func tagsAndProjectsFromWrongLayout() throws {
        let s = try tempStore()
        s.transact { tx in
            tx.createTag("Работа", id: "w"); tx.createTag("Home", id: "h")
            var p = NewTask(title: "Гитара"); p.isProject = true
            tx.createTask(p, id: "g")
        }
        let r = QuickEntryParser(snapshot: s.snapshot()).parse("Струны #hf,jnf #рщьу ::ubnf")
        #expect(r.tagIDs == ["w", "h"])
        #expect(r.projectID == "g")
    }
}

@Suite struct HighlightTests {
    @Test func positions() {
        #expect(Fuzzy.matchPositions("нт", "Самообразование : Новые тулы в тулбокс") == [18, 24])
        #expect(Fuzzy.matchPositions("гит", "Common : Гитара") == [9, 10, 11])
        #expect(Fuzzy.matchPositions("ubn", "Common : Гитара") == [9, 10, 11]) // wrong layout
    }
}
