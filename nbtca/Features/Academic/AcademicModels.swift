// Adapted from nbtca/Prompt and @nbtca/nbtcal. See Resources/AcademicNotices.txt.
import Foundation
import CoreFoundation

nonisolated enum CampusService: String, Codable, Sendable {
    case academic, dormitory
    var title: String { self == .academic ? "教务" : "寝室文明" }
    func origin(_ route: CampusRoute) -> String {
        if self == .academic { return route.origin }
        return route == .campus ? "https://xsgl.nbt.edu.cn" : "https://xsgl-443.webvpn.nbt.edu.cn"
    }
    func host(_ route: CampusRoute) -> String { URL(string: origin(route))!.host! }
    func entryURL(_ route: CampusRoute) -> URL {
        self == .academic ? route.ssoURL : URL(string: origin(route) + "/xsfw/sys/sswsapp/*default/index.do?THEME=indigo#/dorm_health_student")!
    }
    func loginURL(_ route: CampusRoute) -> URL { route == .webVPN ? route.loginURL : entryURL(route) }
}

nonisolated enum CampusRoute: String, CaseIterable, Sendable {
    case campus, webVPN
    var origin: String { self == .campus ? "https://jwxt.nbt.edu.cn" : "https://jwxt-443.webvpn.nbt.edu.cn" }
    var title: String { self == .campus ? "校园网直连" : "WebVPN" }
    var host: String { URL(string: origin)!.host! }
    var allowedHosts: Set<String> {
        allowedHosts(for: .academic)
    }
    func allowedHosts(for service: CampusService) -> Set<String> {
        self == .campus ? [service.host(self), "authserver.nbt.edu.cn"] : ["webvpn.nbt.edu.cn", service.host(self), "authserver-443.webvpn.nbt.edu.cn"]
    }
    var loginURL: URL { URL(string: self == .campus ? origin + "/sso/jziotlogin" : "https://webvpn.nbt.edu.cn/")! }
    var ssoURL: URL { URL(string: origin + "/sso/jziotlogin")! }
    func allows(_ url: URL, service: CampusService = .academic) -> Bool {
        url.scheme?.lowercased() == "https" && allowedHosts(for: service).contains(url.host?.lowercased() ?? "") &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    func acceptsCookie(_ cookie: HTTPCookie, service: CampusService = .academic) -> Bool {
        let domain = cookie.domain.lowercased()
        return allowedHosts(for: service).contains(domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) ||
            (self == .campus && domain == ".nbt.edu.cn")
    }
    /// Only a recognizable response from the direct university service proves campus access.
    static func recognizesCampusProbe(url: URL?, status: Int, location: String?, body: String) -> Bool {
        guard let url, CampusRoute.campus.allows(url), url.host == CampusRoute.campus.host else { return false }
        if (300..<400).contains(status), let location, let target = URL(string: location, relativeTo: url)?.absoluteURL {
            return CampusRoute.campus.allows(target) &&
                ((target.host == "authserver.nbt.edu.cn" && target.path == "/authserver/login") ||
                 (target.host == CampusRoute.campus.host && ["/jwglxt/ticketlogin", "/jwglxt/xtgl/login_slogin.html"].contains(target.path)))
        }
        return status == 200 && (AcademicParser.isLoginHTML(body) ||
            (body.contains("jwglxt") && (body.contains("教务") || body.contains("jziotlogin"))) ||
            (body.contains("xnm") && body.contains("xqm") && body.contains("<select")))
    }
}

nonisolated enum AcademicKind: String, CaseIterable, Identifiable, Sendable {
    case timetable, exams, grades
    var id: String { rawValue }
    var title: String { switch self { case .timetable: "课表查询"; case .exams: "考试查询"; case .grades: "成绩查询" } }
    var symbol: String { switch self { case .timetable: "calendar"; case .exams: "pencil.and.list.clipboard"; case .grades: "chart.bar.doc.horizontal" } }
    var indexPath: String {
        switch self {
        case .timetable: "/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html"
        case .exams: "/jwglxt/kwgl/kscx_cxXsksxxIndex.html"
        case .grades: "/jwglxt/cjcx/cjcx_cxDgXscj.html"
        }
    }
    var queryPath: String {
        switch self {
        case .timetable: "/jwglxt/kbcx/xskbcx_cxXsgrkb.html"
        case .exams: indexPath
        case .grades: "/jwglxt/cjcx/cjcx_cxXsgrcj.html"
        }
    }
    var code: String { switch self { case .timetable: "N2151"; case .exams: "N358105"; case .grades: "N305005" } }
}

nonisolated enum AcademicError: LocalizedError {
    case sessionExpired, invalidData, termMismatch, network(String), unsafeURL, routeChanged, incompletePages, http(Int)
    var errorDescription: String? {
        switch self {
        case .sessionExpired: "学校登录已失效，请重新登录学校账号"
        case .invalidData: "学校查询服务返回了暂时无法识别的数据，请重试或在官方页面查看"
        case .termMismatch: "教务系统返回的学期与所选学期不一致，请重新选择学期"
        case .network(let message): message
        case .unsafeURL: "学校登录跳转到了未识别的地址，已停止访问"
        case .routeChanged: "访问线路已切换，请在当前线路重新登录"
        case .incompletePages: "教务记录分页不完整，请刷新重试"
        case .http(let status): "教务服务请求失败（\(status)），请稍后重试"
        }
    }
}

nonisolated struct AcademicTerm: Codable, Identifiable, Equatable, Sendable {
    let year, semester, yearLabel, semesterLabel: String
    let current: Bool
    var id: String { year + "-" + semester }
    var title: String {
        let semesterText = ["3": "第一学期", "12": "第二学期", "16": "第三学期"][semester] ?? semesterLabel
        return yearLabel + " · " + semesterText
    }
}
nonisolated struct AcademicCourse: Codable, Identifiable, Sendable {
    let id, name, teacher, location, weekText, periodText: String
    let weekday: Int?
    let startPeriod, endPeriod: Int?
    let weeks: [Int]
    let practice: Bool
    var hasTime: Bool { weekday != nil && startPeriod != nil && endPeriod != nil && !weeks.isEmpty }
}
nonisolated struct AcademicPeriod: Codable, Sendable {
    let number: Int
    let start, end: String
}
nonisolated struct AcademicCalendarDay: Codable, Sendable {
    let week, weekday: Int
    let date: String
}
nonisolated struct AcademicTimetable: Codable, Sendable {
    let courses: [AcademicCourse]
    var periods: [AcademicPeriod]
    let days: [AcademicCalendarDay]
    let unrecognizedCount: Int
    var weekOneMonday: String? = nil
    var unavailableDays: Set<String> = []
    var maxWeek: Int { max(1, max(courses.flatMap(\.weeks).max() ?? 1, days.map(\.week).max() ?? 1)) }
    func time(for course: AcademicCourse) -> String? {
        guard let first = periods.first(where: { $0.number == course.startPeriod }),
              let last = periods.first(where: { $0.number == course.endPeriod }) else { return nil }
        return first.start + " – " + last.end
    }
}
nonisolated struct AcademicExam: Identifiable, Sendable {
    let id, name, examName, timeText, location, campus, seat, assessment: String
    let start, end: Date?
}
nonisolated struct AcademicGrade: Identifiable, Sendable {
    let id, name, grade, credits, point, nature, examNature, remark: String
    let voided: Bool?
}

nonisolated enum AcademicParser {
    typealias Object = [String: Any]
    static func text(_ object: Object, _ keys: String...) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        }
        return ""
    }
    static func matches(_ pattern: String, _ value: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } ?? "" }
        }
    }
    static func replacing(_ pattern: String, in value: String, with replacement: String = "") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
    static func decodeHTML(_ text: String) -> String {
        var result = text
        let named = ["&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        for (entity, replacement) in named { result = result.replacingOccurrences(of: entity, with: replacement) }
        for match in matches("&#(x[0-9a-f]+|[0-9]+);", result).reversed() {
            let raw = match[1]
            if let code = UInt32(raw.lowercased().hasPrefix("x") ? String(raw.dropFirst()) : raw, radix: raw.lowercased().hasPrefix("x") ? 16 : 10), let scalar = UnicodeScalar(code) {
                result = result.replacingOccurrences(of: match[0], with: String(scalar))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
    static func isLoginHTML(_ body: String) -> Bool {
        !matches("pwdEncryptSalt|id\\s*=\\s*[\"']pwdFromId[\"']|name\\s*=\\s*[\"']execution[\"']|/users/sign_in", body).isEmpty
    }
    static func terms(_ html: String) throws -> [AcademicTerm] {
        let clean = replacing("<!--[\\s\\S]*?(?:-->|$)|<(script|style|template)\\b[\\s\\S]*?</\\1\\s*>", in: html)
        func options(_ name: String) -> [(String, String, Bool)] {
            guard let select = matches("<select\\b[^>]*(?:id|name)\\s*=\\s*[\"']" + name + "[\"'][^>]*>([\\s\\S]*?)</select>", clean).first else { return [] }
            return matches("<option\\b([^>]*)>([\\s\\S]*?)</option>", select[1]).compactMap { match in
                let values = matches("(?:^|\\s)value\\s*=\\s*(?:[\"']([^\"']*)[\"']|([^\\s>]+))", match[1]).first
                guard let values else { return nil }
                let value = decodeHTML(values[1].isEmpty ? values[2] : values[1])
                let label = decodeHTML(replacing("<[^>]*>", in: match[2])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !label.isEmpty else { return nil }
                return (value, label, !matches("(?:^|\\s)selected(?:\\s|=|$)", match[1]).isEmpty)
            }
        }
        let years = options("xnm"), semesters = options("xqm")
        guard !years.isEmpty, !semesters.isEmpty else { throw AcademicError.invalidData }
        return years.flatMap { year in semesters.map { semester in AcademicTerm(year: year.0, semester: semester.0, yearLabel: year.1, semesterLabel: semester.1, current: year.2 && semester.2) } }
    }
    static func weeks(_ expression: String) -> [Int] {
        let normalized = replacing("[，、；;]", in: replacing("[~～—–至]", in: expression, with: "-"), with: ",")
        var result = Set<Int>()
        for part in normalized.split(separator: ",") {
            let string = String(part)
            let parity: Int? = string.contains("单") ? 1 : string.contains("双") ? 0 : nil
            let cleaned = replacing("[第周单双（）()\\s]", in: string)
            guard let match = matches("^(\\d{1,2})(?:-(\\d{1,2}))?$", cleaned).first, let first = Int(match[1]), let last = Int(match[2].isEmpty ? match[1] : match[2]), first >= 1, last >= first, last <= 60 else { continue }
            for week in first...last where parity == nil || week % 2 == parity { result.insert(week) }
        }
        return result.sorted()
    }
    static func timetable(_ json: Object, term: AcademicTerm) throws -> AcademicTimetable {
        guard json["kbList"] is [Any] || json["sjkList"] is [Any] else { throw AcademicError.invalidData }
        guard let student = json["xsxx"] as? Object, text(student, "XNM", "xnm") == term.year, text(student, "XQM", "xqm") == term.semester else { throw AcademicError.termMismatch }
        var courses: [AcademicCourse] = [], invalid = 0
        for (key, practice) in [("kbList", false), ("sjkList", true)] {
            for (index, raw) in (json[key] as? [Any] ?? []).enumerated() {
                guard let row = raw as? Object else { invalid += 1; continue }
                var name = text(row, "kcmc", "KCMC")
                var weekText = text(row, "zcd", "ZCD", "qsjsz", "QSJSZ")
                var teacher = text(row, "xm", "XM", "jsxm", "JSXM")
                if practice, let composite = matches("^(.+?)[★●○◇](.*?)/([^/]+)(?:/|$)", text(row, "qtkcgs", "QTKCGS", "sjkcgs", "SJKCGS")).first {
                    if name.isEmpty { name = composite[1].trimmingCharacters(in: .whitespacesAndNewlines) }
                    if weekText.isEmpty { weekText = composite[3].trimmingCharacters(in: .whitespacesAndNewlines) }
                    if teacher.isEmpty { teacher = replacing("[（(]共[^)）]*[)）]", in: composite[2]).trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                let periodText = text(row, "jcs", "JCS", "jc", "JC")
                let numbers = matches("\\d{1,2}", periodText).compactMap { Int($0[0]) }
                let start = numbers.first, end = numbers.last
                let validPeriods = start != nil && end != nil && start! >= 1 && end! >= start! && end! <= 99
                let day = Int(text(row, "xqj", "XQJ")).flatMap { (1...7).contains($0) ? $0 : nil }
                guard !name.isEmpty else { invalid += 1; continue }
                let course = AcademicCourse(id: key + "-\(index)", name: name, teacher: teacher, location: text(row, "cdmc", "CDMC"), weekText: weekText, periodText: periodText, weekday: day, startPeriod: validPeriods ? start : nil, endPeriod: validPeriods ? end : nil, weeks: weeks(weekText), practice: practice)
                courses.append(course)
                if !course.hasTime && !practice { invalid += 1 }
            }
        }
        var calendarDays: [String: AcademicCalendarDay] = [:]
        var conflicts = Set<String>()
        for row in json["rqazcList"] as? [Object] ?? [] {
            guard let week = Int(text(row, "zc", "ZC")), (1...60).contains(week), let weekday = Int(text(row, "xqj", "XQJ")), (1...7).contains(weekday) else { continue }
            let date = text(row, "rq", "RQ")
            guard let parsed = dateTime(date, "00:00"), calendar.component(.weekday, from: parsed) == weekday % 7 + 1 else { continue }
            let key = "\(week):\(weekday)"
            if conflicts.contains(key) { continue }
            if let old = calendarDays[key], old.date != date { calendarDays.removeValue(forKey: key); conflicts.insert(key) }
            else { calendarDays[key] = AcademicCalendarDay(week: week, weekday: weekday, date: date) }
        }
        let days = calendarDays.values.sorted { ($0.week, $0.weekday) < ($1.week, $1.weekday) }
        return AcademicTimetable(courses: courses, periods: periods(json["xqbzxxszList"]), days: days, unrecognizedCount: invalid, unavailableDays: conflicts)
    }
    static func periods(_ raw: Any?) -> [AcademicPeriod] {
        let object = raw as? Object ?? [:]
        let rows = raw as? [Object] ?? object["data"] as? [Object] ?? object["jcList"] as? [Object] ?? []
        var result: [Int: AcademicPeriod] = [:]
        for row in rows {
            guard let number = matches("\\d{1,2}", text(row, "jcdm", "JCDM", "jc", "JC", "jcmc", "JCMC")).first.flatMap({ Int($0[0]) }), (1...99).contains(number),
                  let start = normalizeTime(text(row, "qssj", "QSSJ")), let end = normalizeTime(text(row, "jssj", "JSSJ")), start < end else { continue }
            result[number] = AcademicPeriod(number: number, start: start, end: end)
        }
        return result.values.sorted { $0.number < $1.number }
    }
    static func exams(_ rows: [Object]) throws -> [AcademicExam] {
        try rows.enumerated().map { index, row in
            let name = text(row, "kcmc")
            guard !name.isEmpty else { throw AcademicError.invalidData }
            let time = text(row, "kssj")
            let match = matches("^(\\d{4}-\\d{2}-\\d{2})\\s*[（(](\\d{2}:\\d{2})\\s*[-–~～]\\s*(\\d{2}:\\d{2})[）)]$", time).first
            let start = match.flatMap { dateTime($0[1], $0[2]) }, end = match.flatMap { dateTime($0[1], $0[3]) }
            let valid = start != nil && end != nil && end! > start!
            return AcademicExam(id: "exam-\(index)", name: name, examName: text(row, "ksmc"), timeText: time, location: text(row, "cdmc"), campus: text(row, "cdxqmc"), seat: text(row, "zwh"), assessment: text(row, "khfs"), start: valid ? start : nil, end: valid ? end : nil)
        }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }
    static func grades(_ rows: [Object]) throws -> [AcademicGrade] {
        try rows.enumerated().map { index, row in
            let name = text(row, "kcmc")
            guard !name.isEmpty else { throw AcademicError.invalidData }
            let flag = text(row, "cjsfzf")
            return AcademicGrade(id: "grade-\(index)", name: name, grade: text(row, "cj"), credits: text(row, "xf"), point: text(row, "jd"), nature: text(row, "kcxzmc"), examNature: text(row, "ksxz"), remark: text(row, "cjbz"), voided: ["是", "1"].contains(flag) ? true : ["否", "0"].contains(flag) ? false : nil)
        }
    }
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    static func dateTime(_ date: String, _ time: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let string = date + " " + time
        guard let value = formatter.date(from: string), formatter.string(from: value) == string else { return nil }
        return value
    }
    static func normalizeTime(_ string: String) -> String? {
        guard let match = matches("^(\\d{1,2}):(\\d{2})(?::\\d{2})?$", string).first,
              let hour = Int(match[1]), let minute = Int(match[2]), hour <= 23, minute <= 59 else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }
}
