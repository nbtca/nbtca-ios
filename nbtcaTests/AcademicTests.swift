import XCTest
@testable import nbtca

@MainActor
final class AcademicTests: XCTestCase {
    private let term = AcademicTerm(year: "2026", semester: "3", yearLabel: "2026-2027", semesterLabel: "3", current: true)
    func testRoutesUseUniversityOrigins() {
        XCTAssertEqual(CampusRoute.campus.origin, "https://jwxt.nbt.edu.cn")
        XCTAssertEqual(CampusRoute.webVPN.origin, "https://jwxt-443.webvpn.nbt.edu.cn")
        XCTAssertFalse(CampusRoute.campus.allows(URL(string: "https://jwxt-443.webvpn.nbt.edu.cn")!))
        XCTAssertFalse(CampusRoute.webVPN.allows(URL(string: "https://jwxt.nbt.edu.cn")!))
    }
    func testUntrustedOriginsCredentialsAndPortsAreRejected() {
        for source in ["http://jwxt.nbt.edu.cn", "https://jwxt.nbt.edu.cn.evil.example", "https://user:password@jwxt.nbt.edu.cn", "https://jwxt.nbt.edu.cn:8443"] {
            XCTAssertFalse(CampusRoute.campus.allows(URL(string: source)!))
        }
        XCTAssertTrue(CampusRoute.campus.allows(URL(string: "https://authserver.nbt.edu.cn/authserver/login")!))
    }
    func testRouterCampusProbeRecognizesDirectCASRedirect() {
        XCTAssertTrue(CampusRoute.recognizesCampusProbe(url: CampusRoute.campus.ssoURL, status: 302, location: "https://authserver.nbt.edu.cn/authserver/login?service=https%3A%2F%2Fjwxt.nbt.edu.cn%2Fsso%2Fjziotlogin", body: ""))
    }
    func testCaptivePortalAndGenericWiFiResponseDoNotCountAsCampus() {
        XCTAssertFalse(CampusRoute.recognizesCampusProbe(url: CampusRoute.campus.ssoURL, status: 200, location: nil, body: "<html>Welcome to WiFi</html>"))
        XCTAssertFalse(CampusRoute.recognizesCampusProbe(url: CampusRoute.campus.ssoURL, status: 302, location: "http://192.168.1.1/login", body: ""))
        XCTAssertFalse(CampusRoute.recognizesCampusProbe(url: CampusRoute.webVPN.ssoURL, status: 200, location: nil, body: "pwdEncryptSalt"))
    }
    func testRecognizableUniversityLoginIsCampusReachable() {
        XCTAssertTrue(CampusRoute.recognizesCampusProbe(url: CampusRoute.campus.ssoURL, status: 200, location: nil, body: "<input id='pwdEncryptSalt'>"))
        XCTAssertFalse(CampusRoute.recognizesCampusProbe(url: CampusRoute.campus.ssoURL, status: 503, location: nil, body: "pwdEncryptSalt"))
    }
    func testTermCatalogAndCurrentSemester() throws {
        let html = "<select id='xnm'><option value='2025'>2025-2026</option><option value='2026' selected>2026-2027</option></select><select name='xqm'><option value='3' selected>3</option><option value='12'>12</option></select>"
        let terms = try AcademicParser.terms(html)
        XCTAssertEqual(terms.count, 4); XCTAssertEqual(terms.first(where: \.current)?.id, "2026-3")
        XCTAssertEqual(terms.first(where: \.current)?.title, "2026-2027 · 第一学期")
    }
    func testLoginPageDoesNotProduceFakeTermCatalog() {
        XCTAssertThrowsError(try AcademicParser.terms("<html><input id='pwdEncryptSalt'></html>"))
        XCTAssertThrowsError(try AcademicParser.terms("<script><select id='xnm'><option value='2026'>2026</option></select></script>"))
    }
    func testOddEvenAndDisjointWeekRanges() {
        XCTAssertEqual(AcademicParser.weeks("1-8周，10-16周(双)"), [1,2,3,4,5,6,7,8,10,12,14,16])
        XCTAssertEqual(AcademicParser.weeks("1～7周（单）"), [1,3,5,7])
        XCTAssertEqual(AcademicParser.weeks("0-3周,59-61周,未安排"), [])
        XCTAssertEqual(AcademicParser.weeks("第16周、18周"), [16,18])
    }
    func testTimetablePreservesPeriodAndCampusCalendar() throws {
        let payload: [String: Any] = ["xsxx": ["XNM":"2026","XQM":"3"], "kbList": [["kcmc":"离散数学","xqj":"2","zcd":"1-15周(单)","jcs":"3-5","xm":"教师甲","cdmc":"A101"]],
            "rqazcList": [["zc":"1","xqj":"2","rq":"2026-09-08"]],
            "xqbzxxszList": [["jcdm":"3","qssj":"09:50","jssj":"10:35"], ["jcdm":"5","qssj":"11:30","jssj":"12:15"]]]
        let timetable = try AcademicParser.timetable(payload, term: term)
        XCTAssertEqual(timetable.courses.first?.weekday, 2); XCTAssertEqual(timetable.courses.first?.endPeriod, 5)
        XCTAssertEqual(timetable.days.first?.date, "2026-09-08")
        XCTAssertEqual(timetable.time(for: timetable.courses[0]), "09:50 – 12:15")
    }
    func testWrongTermIsRejected() {
        XCTAssertThrowsError(try AcademicParser.timetable(["xsxx": ["XNM":"2025","XQM":"3"],"kbList":[]], term: term))
        XCTAssertThrowsError(try AcademicParser.timetable(["kbList":[]], term: term))
    }
    func testPracticeCompositeIsRetainedWithoutInventingTimes() throws {
        let result = try AcademicParser.timetable(["xsxx":["XNM":"2026","XQM":"3"],"sjkList":[["qtkcgs":"综合实践★教师乙（共2周）/17-18周/"]]], term: term)
        XCTAssertEqual(result.courses.first?.name, "综合实践"); XCTAssertEqual(result.courses.first?.teacher, "教师乙")
        XCTAssertEqual(result.courses.first?.weeks, [17,18]); XCTAssertFalse(result.courses[0].hasTime)
        XCTAssertNil(result.courses.first?.startPeriod)
    }
    func testConflictingOrInvalidCalendarDatesAreNotInvented() throws {
        let result = try AcademicParser.timetable(["xsxx":["XNM":"2026","XQM":"3"],"kbList":[],"rqazcList":[
            ["zc":"1","xqj":"1","rq":"2026-09-07"], ["zc":"1","xqj":"1","rq":"2026-09-14"],
            ["zc":"2","xqj":"1","rq":"2026-09-08"], ["zc":"3","xqj":"2","rq":"2026-02-30"]]], term: term)
        XCTAssertTrue(result.days.isEmpty)
    }
    func testBellTimesValidateAndZeroPad() {
        let periods = AcademicParser.periods([["jcdm":"第一节1","qssj":"8:00","jssj":"08:45"], ["jcdm":"2","qssj":"25:00","jssj":"26:00"]])
        XCTAssertEqual(periods.count, 1); XCTAssertEqual(periods.first?.start, "08:00")
    }
    func testExamTimesUseShanghaiAndUnpublishedDatesRemainNil() throws {
        let exams = try AcademicParser.exams([["kcmc":"课程甲","kssj":"未放开不可查"], ["kcmc":"课程乙","kssj":"2026-12-10(09:00-11:00)","zwh":"08"]])
        XCTAssertEqual(exams.first?.start, ISO8601DateFormatter().date(from: "2026-12-10T01:00:00Z"))
        XCTAssertEqual(exams.first?.seat, "08"); XCTAssertNil(exams.last?.start)
        XCTAssertEqual(exams.last?.timeText, "未放开不可查")
    }
    func testInvalidExamTimesRemainText() throws {
        for time in ["2026-02-30(09:00-11:00)","2026-12-10(25:00-26:00)","2026-12-10(11:00-09:00)"] {
            XCTAssertNil(try AcademicParser.exams([["kcmc":"课程","kssj":time]]).first?.start)
        }
    }
    func testGradesPreserveZeroLabelsAndVoidedFlag() throws {
        let grades = try AcademicParser.grades([["kcmc":"课程甲","cj":0,"xf":"2.5","jd":0,"cjsfzf":"否","xh":"PRIVATE-STUDENT"], ["kcmc":"课程乙","cj":"良好","cjsfzf":"是"]])
        XCTAssertEqual(grades.first?.grade, "0"); XCTAssertEqual(grades.first?.point, "0"); XCTAssertEqual(grades.first?.voided, false)
        XCTAssertEqual(grades.last?.grade, "良好"); XCTAssertEqual(grades.last?.voided, true)
    }
    func testMissingCourseNameFailsClosed() {
        XCTAssertThrowsError(try AcademicParser.grades([["cj": "90"]]))
        XCTAssertThrowsError(try AcademicParser.exams([["kssj":"未公布"]]))
    }
    func testAcademicQueryRoutesAreReadOnlyAndKeepSelectedTerm() async throws {
        for route in CampusRoute.allCases {
            let client = client(route: route) { request in
                XCTAssertEqual(request.url?.host, route.host); XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "doType" }?.value, "query")
                XCTAssertEqual(request.url?.path, AcademicKind.grades.queryPath)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                let body = academicBody(request)
                XCTAssertTrue(body.contains("xnm=2026")); XCTAssertTrue(body.contains("xqm=3")); XCTAssertFalse(body.contains("xh="))
                return (200, ["items":[],"currentPage":1,"totalPage":0,"totalResult":0])
            }
            let rows = try await client.records(.grades, term: term)
            XCTAssertTrue(rows.isEmpty)
        }
    }
    func testPaginationFetchesEveryPage() async throws {
        let client = client { request in
            let second = academicBody(request).contains("queryModel.currentPage=2")
            return (200, ["items":[["xnm":"2026","xqm":"3","kcmc":second ? "B" : "A"]],"currentPage":second ? 2:1,"totalPage":2,"totalResult":2])
        }
        let rows = try await client.records(.exams, term: term)
        XCTAssertEqual(rows.count, 2)
    }
    func testTruncatedPaginationDoesNotShowPartialRecords() async {
        let client = client { _ in (200, ["items":[],"currentPage":1,"totalPage":2,"totalResult":2]) }
        do { _ = try await client.records(.grades, term: term); XCTFail("Incomplete pages should throw") } catch { XCTAssertTrue(error is AcademicError) }
    }
    func testRecordTermMismatchIsRejected() async {
        let client = client { _ in (200, ["items":[["xnm":"2025","xqm":"3","kcmc":"A"]],"currentPage":1,"totalPage":1,"totalResult":1]) }
        do { _ = try await client.records(.grades, term: term); XCTFail("Another term should throw") } catch { XCTAssertEqual(error.localizedDescription, AcademicError.termMismatch.localizedDescription) }
    }
    func testHTTP200LoginPageMeansSessionExpired() async {
        let client = client { _ in (200, "<input id='pwdEncryptSalt' value='salt'>") }
        do { _ = try await client.terms(); XCTFail("Login HTML should throw") } catch { XCTAssertEqual(error.localizedDescription, AcademicError.sessionExpired.localizedDescription) }
    }
    func testHTTP403MeansSessionExpired() async {
        let client = client { _ in (403, [:]) }
        do { _ = try await client.terms(); XCTFail("403 should throw") } catch { XCTAssertEqual(error.localizedDescription, AcademicError.sessionExpired.localizedDescription) }
    }
    func testFormEncodingKeepsLiteralPlusAndUnicode() {
        let data = CampusClient.form(["value":"A+B & 课程"])
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("%2B")); XCTAssertTrue(encoded.contains("%26"))
        XCTAssertEqual(URLComponents(string: "https://example.test/?" + encoded)?.queryItems?.first?.value, "A+B & 课程")
    }
    func testStaleDOMInspectionCannotInterruptCampusRedirect() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish()
        flow.begin() // The school has started its next redirect before JS returns.
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: token, hasTerms: false, hasLoginForm: false), .wait)
        _ = flow.finish()
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: token, hasTerms: true, hasLoginForm: false), .wait)
    }
    func testCampusLandingNavigatesToTimetableOnlyOnce() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish()
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: token, hasTerms: false, hasLoginForm: false), .timetable)
        flow.begin(); let next = flow.finish()
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: next, hasTerms: false, hasLoginForm: false), .wait)
    }
    func testLoginFormAndErrorPageNeverTriggerAutomaticQuery() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish()
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: token, hasTerms: false, hasLoginForm: true), .wait)
        XCTAssertEqual(flow.step(route: .campus, url: URL(string: CampusRoute.campus.origin + "/jwglxt/error.html")!, token: token, hasTerms: false, hasLoginForm: false), .wait)
        XCTAssertEqual(flow.step(route: .campus, url: URL(string: "https://authserver.nbt.edu.cn/authserver/login")!, token: token, hasTerms: false, hasLoginForm: false), .wait)
    }
    func testVPNLandingEntersSSOOnceAndPreservesLoginForm() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish()
        XCTAssertEqual(flow.step(route: .webVPN, url: CampusRoute.webVPN.loginURL, token: token, hasTerms: false, hasLoginForm: true), .wait)
        XCTAssertEqual(flow.step(route: .webVPN, url: CampusRoute.webVPN.loginURL, token: token, hasTerms: false, hasLoginForm: false), .sso)
        flow.begin(); let next = flow.finish()
        XCTAssertEqual(flow.step(route: .webVPN, url: CampusRoute.webVPN.loginURL, token: next, hasTerms: false, hasLoginForm: false), .wait)
    }
    func testOnlyCurrentUniversityDocumentCanCompleteLogin() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish()
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.webVPN.ssoURL, token: token, hasTerms: true, hasLoginForm: false), .wait)
        XCTAssertEqual(flow.step(route: .campus, url: URL(string: CampusRoute.campus.origin + AcademicKind.timetable.indexPath)!, token: token, hasTerms: true, hasLoginForm: false), .complete)
        XCTAssertEqual(flow.step(route: .campus, url: CampusRoute.campus.ssoURL, token: token, hasTerms: true, hasLoginForm: false), .wait)
    }
    func testDestroyedWebViewCannotApplyPendingInspection() {
        var flow = CampusLoginNavigation()
        flow.begin(); let token = flow.finish(); flow.invalidate()
        XCTAssertFalse(flow.isCurrent(token))
    }
    func testOnlyURLCancellationIsIgnored() {
        XCTAssertTrue(CampusConnectionDiagnostics.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(CampusConnectionDiagnostics.isCancellation(NSError(domain: "Other", code: -999)))
        XCTAssertFalse(CampusConnectionDiagnostics.isCancellation(URLError(.timedOut)))
    }
    func testDiagnosticsIdentifyFailureWithoutLeakingTicketOrCredentials() {
        let url = URL(string: "https://authserver.nbt.edu.cn/authserver/login?ticket=secret-ticket&username=student#secret-fragment")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                            userInfo: [NSLocalizedDescriptionKey: "private-password", NSURLErrorFailingURLErrorKey: url])
        let message = CampusConnectionDiagnostics.message(error, route: .campus, url: url)
        XCTAssertTrue(message.contains("authserver.nbt.edu.cn")); XCTAssertTrue(message.contains("-1003"))
        XCTAssertTrue(message.contains("域名")); XCTAssertTrue(message.contains("WebVPN"))
        for secret in ["secret-ticket", "student", "secret-fragment", "private-password", "/authserver/login"] {
            XCTAssertFalse(message.contains(secret))
        }
    }
    func testQueryConnectionFailureKeepsActionableDiagnostic() async {
        let client = client(route: .campus) { _ in throw URLError(.timedOut) }
        do { _ = try await client.terms(); XCTFail("Timeout must throw") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
            XCTAssertTrue(error.localizedDescription.contains("jwxt.nbt.edu.cn"))
            XCTAssertTrue(error.localizedDescription.contains("-1001"))
        }
    }
    func testSavedSessionRestoresCookieScopeAndFlags() throws {
        let now = Date()
        let original = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie":
            "JSESSIONID=test-session; Path=/jwglxt; Secure; HttpOnly; SameSite=Lax; Max-Age=3600"],
            for: URL(string: CampusRoute.campus.origin)!).first)
        XCTAssertTrue(original.isHTTPOnly); XCTAssertTrue(original.isSecure)
        let encoded = try JSONEncoder().encode(CampusSessionArchive(cookies: [original], route: .campus, now: now))
        let archive = try JSONDecoder().decode(CampusSessionArchive.self, from: encoded)
        let restored = try XCTUnwrap(archive.restored(for: .campus, now: now.addingTimeInterval(10)).first)
        XCTAssertEqual(restored.name, original.name); XCTAssertEqual(restored.value, original.value)
        XCTAssertEqual(restored.domain, original.domain); XCTAssertEqual(restored.path, original.path)
        XCTAssertEqual(restored.isSecure, original.isSecure); XCTAssertEqual(restored.isHTTPOnly, original.isHTTPOnly)
        XCTAssertEqual(restored.sameSitePolicy, original.sameSitePolicy)
        XCTAssertEqual(restored.expiresDate?.timeIntervalSince1970 ?? 0, original.expiresDate?.timeIntervalSince1970 ?? 0, accuracy: 1)
    }
    func testSavedCookiesNeverCrossRoutesOrAcceptOtherDomains() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "test", .domain: "jwxt.nbt.edu.cn", .path: "/"]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [.name: "other", .value: "test", .domain: "example.org", .path: "/"]))
        let archive = CampusSessionArchive(cookies: [cookie, unrelated], route: .campus)
        XCTAssertEqual(archive.restored(for: .campus).map(\.name), ["session"])
        XCTAssertTrue(archive.restored(for: .webVPN).isEmpty)
    }
    func testExpiredCookiesAndOldSavedSessionAreDiscarded() throws {
        let now = Date()
        let fresh = try XCTUnwrap(HTTPCookie(properties: [.name: "fresh", .value: "test", .domain: "jwxt.nbt.edu.cn", .path: "/", .expires: now.addingTimeInterval(60)]))
        let expired = try XCTUnwrap(HTTPCookie(properties: [.name: "expired", .value: "test", .domain: "jwxt.nbt.edu.cn", .path: "/", .expires: now.addingTimeInterval(-60)]))
        let archive = CampusSessionArchive(cookies: [fresh, expired], route: .campus, now: now)
        XCTAssertEqual(archive.restored(for: .campus, now: now).map(\.name), ["fresh"])
        XCTAssertTrue(archive.restored(for: .campus, now: now.addingTimeInterval(61)).isEmpty)
        let sessionOnly = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "test", .domain: "jwxt.nbt.edu.cn", .path: "/", .discard: "TRUE"]))
        let sessionArchive = CampusSessionArchive(cookies: [sessionOnly], route: .campus, now: now)
        XCTAssertEqual(sessionArchive.restored(for: .campus, now: now.addingTimeInterval(60)).first?.isSessionOnly, true)
        XCTAssertTrue(sessionArchive.restored(for: .campus, now: now.addingTimeInterval(CampusSessionArchive.maximumAge)).isEmpty)
    }
    func testUniversityParentCookieIsAcceptedOnlyForDirectRoute() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "SSO", .value: "test", .domain: ".nbt.edu.cn", .path: "/"]))
        XCTAssertTrue(CampusRoute.campus.acceptsCookie(cookie))
        XCTAssertFalse(CampusRoute.webVPN.acceptsCookie(cookie))
        let publicSuffix = try XCTUnwrap(HTTPCookie(properties: [.name: "bad", .value: "test", .domain: ".edu.cn", .path: "/"]))
        XCTAssertFalse(CampusRoute.campus.acceptsCookie(publicSuffix))
    }
    func testDormitoryOriginsAndCookiesStayInTheirServiceAndRoute() throws {
        let campus = URL(string: "https://xsgl.nbt.edu.cn/xsfw/sys/sswsapp/*default/index.do")!
        let vpn = URL(string: "https://xsgl-443.webvpn.nbt.edu.cn/xsfw/sys/sswsapp/*default/index.do")!
        XCTAssertEqual(CampusService.dormitory.origin(.campus), "https://xsgl.nbt.edu.cn")
        XCTAssertTrue(CampusRoute.campus.allows(campus, service: .dormitory))
        XCTAssertTrue(CampusRoute.webVPN.allows(vpn, service: .dormitory))
        XCTAssertFalse(CampusRoute.campus.allows(campus))
        XCTAssertFalse(CampusRoute.campus.allows(vpn, service: .dormitory))
        XCTAssertFalse(CampusRoute.campus.allows(CampusRoute.campus.ssoURL, service: .dormitory))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name:"JSESSIONID", .value:"synthetic", .domain:"xsgl.nbt.edu.cn", .path:"/xsfw"]))
        let archive = CampusSessionArchive(cookies: [cookie], route: .campus, service: .dormitory)
        XCTAssertEqual(archive.restored(for: .campus, service: .dormitory).count, 1)
        XCTAssertTrue(archive.restored(for: .campus).isEmpty)
        XCTAssertTrue(archive.restored(for: .webVPN, service: .dormitory).isEmpty)
    }
    func testLegacyAcademicArchiveStillRestores() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name:"JSESSIONID", .value:"synthetic", .domain:"jwxt.nbt.edu.cn", .path:"/"]))
        let archive = CampusSessionArchive(cookies: [cookie], route: .campus)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object.removeValue(forKey: "service")
        let legacy = try JSONDecoder().decode(CampusSessionArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.restored(for: .campus).count, 1)
        XCTAssertTrue(legacy.restored(for: .campus, service: .dormitory).isEmpty)
    }
    func testDormitoryModelUsesSchoolFieldsWithoutAcademicSemesterConversion() throws {
        let result = try DormitoryParser.page(dormitoryPage(rows: [dormitoryRow("synthetic-1")]), kind: .room)
        let record = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(record.location, "A 幢 · 101 室"); XCTAssertEqual(record.score, "9.5")
        XCTAssertEqual(record.deductions, "地面整洁0.5"); XCTAssertEqual(record.date, "2026-10-01")
        XCTAssertEqual(record.year, "2026"); XCTAssertEqual(record.semester, "1")
        XCTAssertEqual(record.semesterLabel, "第一学期"); XCTAssertFalse(record.hasAttachments)
        XCTAssertTrue(record.matches("地面")); XCTAssertFalse(record.matches("不存在的内容"))
    }
    func testDormitoryNullScoreIsUnpublishedAndZeroIsRetained() throws {
        var pending = dormitoryRow("pending"), zero = dormitoryRow("zero")
        pending["FS"] = NSNull(); pending["BZ"] = NSNull()
        zero["FS"] = 0; zero["FJ"] = "synthetic-attachment"
        let records = try DormitoryParser.page(dormitoryPage(rows: [pending, zero], total: 2), kind: .room).rows
        XCTAssertEqual(records[0].score, ""); XCTAssertEqual(records[0].remark, "")
        XCTAssertEqual(records[1].score, "0"); XCTAssertTrue(records[1].hasAttachments)
    }
    func testDormitoryLoadsCompletePaginationAndConfirmedPostPath() async throws {
        let client = client(route: .campus, service: .dormitory) { request in
            XCTAssertEqual(request.url?.host, "xsgl.nbt.edu.cn")
            XCTAssertEqual(request.url?.path, "/xsfw/sys/sswsapp/modules/dorm_health_student/sswsxs_sswsxsbg.do")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.value(forHTTPHeaderField: "Referer")?.contains("#") ?? true)
            let fields = URLComponents(string: "https://example.test/?" + academicBody(request))?.queryItems ?? []
            XCTAssertEqual(fields.first(where: { $0.name == "pageSize" })?.value, "50")
            XCTAssertNil(fields.first(where: { $0.name == "xqm" }))
            let page = Int(fields.first(where: { $0.name == "pageNumber" })?.value ?? "0") ?? 0
            return (200, self.dormitoryPage(rows: [self.dormitoryRow("row-\(page)")], total: 2, page: page, size: 1))
        }
        let records = try await client.dormitory(.room)
        XCTAssertEqual(records.count, 2)
    }
    func testPersonalHygieneUsesItsOwnDatasetAndQuery() async throws {
        let client = client(service: .dormitory) { request in
            XCTAssertEqual(request.url?.path, "/xsfw/sys/sswsapp/modules/person_health_student/grwsxs_grwsxsbg.do")
            return (200, self.dormitoryPage(rows: [], total: 0, kind: .personal))
        }
        let records = try await client.dormitory(.personal)
        XCTAssertTrue(records.isEmpty)
    }
    func testDormitoryRejectsDuplicateAndIncompletePages() async {
        let client = client(service: .dormitory) { request in
            let second = academicBody(request).contains("pageNumber=2")
            return (200, self.dormitoryPage(rows: [self.dormitoryRow("duplicate")], total: 2, page: second ? 2 : 1, size: 1))
        }
        do { _ = try await client.dormitory(.room); XCTFail("Duplicate pages must not become complete records") }
        catch { XCTAssertEqual(error.localizedDescription, AcademicError.incompletePages.localizedDescription) }
        let incomplete = clientForIncompleteDormitory()
        do { _ = try await incomplete.dormitory(.room); XCTFail("Truncated page must fail") }
        catch { XCTAssertEqual(error.localizedDescription, AcademicError.incompletePages.localizedDescription) }
    }
    func testDormitoryRejectsMalformedPagingAndAuthenticationFailure() {
        XCTAssertThrowsError(try DormitoryParser.page(["datas": [:]], kind: .room))
        var invalid = dormitoryPage(rows: [])
        invalid["datas"] = [DormitoryKind.room.action: ["totalSize": true, "pageNumber":1, "pageSize":50, "rows":[]]]
        XCTAssertThrowsError(try DormitoryParser.page(invalid, kind: .room))
        XCTAssertThrowsError(try DormitoryParser.page(["code":"401"], kind: .room)) { error in
            XCTAssertEqual(error.localizedDescription, AcademicError.sessionExpired.localizedDescription)
        }
    }
    func testDormitoryLoginWaitsForSPAAndRejectsWrongServicePage() {
        var flow = CampusLoginNavigation(); flow.begin(); let token = flow.finish()
        let url = CampusService.dormitory.entryURL(.campus)
        XCTAssertEqual(flow.step(route: .campus, service: .dormitory, url: url, token: token, hasTerms: false, hasLoginForm: false), .wait)
        XCTAssertEqual(flow.step(route: .campus, service: .dormitory, url: CampusRoute.campus.ssoURL, token: token, hasTerms: true, hasLoginForm: false), .wait)
        XCTAssertEqual(flow.step(route: .campus, service: .dormitory, url: url, token: token, hasTerms: true, hasLoginForm: false), .complete)
    }
    func testDormitoryFirstPageValidationDoesNotFetchAllHistory() async throws {
        var requests = 0
        let client = client(service: .dormitory) { _ in
            requests += 1
            return (200, self.dormitoryPage(rows: [self.dormitoryRow("only-validation")], total: 200))
        }
        let rows = try await client.dormitory(.room, firstPageOnly: true)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(requests, 1)
    }
    func testDormitoryAcceptsStringPaginationWithoutWeakeningValidation() throws {
        let payload: [String: Any] = ["datas": [DormitoryKind.room.action: ["totalSize":"1", "pageNumber":"1", "pageSize":"50", "rows":[dormitoryRow("string-page")]]]]
        let page = try DormitoryParser.page(payload, kind: .room)
        XCTAssertEqual(page.total, 1); XCTAssertEqual(page.number, 1); XCTAssertEqual(page.rows.count, 1)
        for bad: Any in [true, "1.5", "-1", "1e3", "not-a-number", "999999999"] {
            let invalid: [String: Any] = ["datas": [DormitoryKind.room.action: ["totalSize":bad, "pageNumber":1, "pageSize":50, "rows":[]]]]
            XCTAssertThrowsError(try DormitoryParser.page(invalid, kind: .room))
        }
    }
    func testDormitoryEmptyResultCanOmitEchoedPageAndRows() throws {
        let empty: [String: Any] = ["datas": [DormitoryKind.room.action: ["totalSize":"0", "rows":NSNull()]]]
        let page = try DormitoryParser.page(empty, kind: .room, requestedPage: 2, requestedSize: 50)
        XCTAssertEqual(page.total, 0); XCTAssertEqual(page.number, 2); XCTAssertEqual(page.size, 50); XCTAssertTrue(page.rows.isEmpty)
        let missingRows: [String: Any] = ["datas": [DormitoryKind.room.action: ["totalSize":"2"]]]
        XCTAssertThrowsError(try DormitoryParser.page(missingRows, kind: .room))
    }
    func testDormitoryContinuesWhenGatewayCapsPageSizeWithoutEchoingIt() async throws {
        var requests = 0
        let client = client(service: .dormitory) { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://xsgl-443.webvpn.nbt.edu.cn")
            return (200, ["datas": [DormitoryKind.room.action: ["totalSize":"2", "rows":[self.dormitoryRow("capped-\(requests)")]]]])
        }
        let rows = try await client.dormitory(.room)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(requests, 2)
    }
    func testDormitoryValidationRetriesOnlyUntilDatasetIsReady() async throws {
        var requests = 0
        let client = client(service: .dormitory) { _ in
            requests += 1
            if requests < 3 { return (200, ["datas":[:]]) }
            return (200, self.dormitoryPage(rows: [], total: 0))
        }
        try await client.validateDormitorySession()
        XCTAssertEqual(requests, 3)
    }
    func testDormitoryValidationNeverAcceptsRepeatedInitializationFailure() async {
        var requests = 0
        let client = client(service: .dormitory) { _ in requests += 1; return (200, ["datas":[:]]) }
        do { try await client.validateDormitorySession(); XCTFail("Missing dataset is not an authenticated session") }
        catch { XCTAssertEqual(error.localizedDescription, DormitoryResponseError.missingDataset.localizedDescription) }
        XCTAssertEqual(requests, 3)
    }
    func testDormitoryGatewayHTMLHasSpecificErrorWithoutLeakingResponse() async {
        let client = client(service: .dormitory) { _ in (200, "\u{feff}<!doctype html><html>webvpn vpn_key private-ticket</html>") }
        do { _ = try await client.dormitory(.room); XCTFail("Gateway page is not a dataset") }
        catch {
            XCTAssertEqual(error.localizedDescription, DormitoryResponseError.webVPNPage.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("private-ticket"))
        }
    }
    func testLoginCanRetryVerificationWithoutDestroyingTheBrowser() {
        var flow = CampusLoginNavigation(); flow.begin(); let token = flow.finish()
        let url = CampusService.dormitory.entryURL(.webVPN)
        XCTAssertEqual(flow.step(route: .webVPN, service: .dormitory, url: url, token: token, hasTerms: true, hasLoginForm: false), .complete)
        flow.manualQuery(); let retryToken = flow.finish()
        XCTAssertNotEqual(token, retryToken)
        XCTAssertEqual(flow.step(route: .webVPN, service: .dormitory, url: url, token: retryToken, hasTerms: true, hasLoginForm: false), .complete)
    }
    func testNewDocumentAfterVerificationCanFinishLoadingAgain() {
        var flow = CampusLoginNavigation(); flow.begin(); let token = flow.finish()
        let url = CampusService.dormitory.entryURL(.campus)
        XCTAssertEqual(flow.step(route: .campus, service: .dormitory, url: url, token: token, hasTerms: true, hasLoginForm: false), .complete)
        flow.begin(); let next = flow.finish()
        XCTAssertFalse(flow.completed); XCTAssertTrue(flow.isCurrent(next)); XCTAssertFalse(flow.isCurrent(token))
        XCTAssertEqual(flow.step(route: .campus, service: .dormitory, url: url, token: next, hasTerms: true, hasLoginForm: false), .complete)
    }
    func testSharedSchoolCookiesSurviveEitherServiceLogin() throws {
        let storage = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let academic = CampusClient(route: .campus, sharedCookies: storage)
        let dormitory = CampusClient(route: .campus, service: .dormitory, sharedCookies: storage)
        let cas = try XCTUnwrap(HTTPCookie(properties: [.name:"CASTGC", .value:"synthetic-cas", .domain:"authserver.nbt.edu.cn", .path:"/authserver"]))
        let timetable = try XCTUnwrap(HTTPCookie(properties: [.name:"JSESSIONID", .value:"synthetic-academic", .domain:"jwxt.nbt.edu.cn", .path:"/jwglxt"]))
        let room = try XCTUnwrap(HTTPCookie(properties: [.name:"JSESSIONID", .value:"synthetic-dormitory", .domain:"xsgl.nbt.edu.cn", .path:"/xsfw"]))
        academic.importCookies([cas, timetable])
        dormitory.importCookies([cas, room])
        XCTAssertEqual(academic.cookies.first { $0.domain == "jwxt.nbt.edu.cn" }?.value, "synthetic-academic")
        XCTAssertEqual(dormitory.cookies.first { $0.domain == "xsgl.nbt.edu.cn" }?.value, "synthetic-dormitory")
        XCTAssertTrue(academic.cookies.contains { $0.name == "CASTGC" })
        XCTAssertTrue(dormitory.cookies.contains { $0.name == "CASTGC" })
        XCTAssertFalse(academic.cookies.contains { $0.domain == "xsgl.nbt.edu.cn" })
        XCTAssertFalse(dormitory.cookies.contains { $0.domain == "jwxt.nbt.edu.cn" })
        // Re-entering the academic service must not delete the dormitory cookie.
        academic.importCookies([cas, timetable])
        XCTAssertEqual(dormitory.cookies.first { $0.domain == "xsgl.nbt.edu.cn" }?.value, "synthetic-dormitory")
        let academicArchive = CampusSessionArchive(cookies: storage.cookies ?? [], route: .campus)
        let dormitoryArchive = CampusSessionArchive(cookies: storage.cookies ?? [], route: .campus, service: .dormitory)
        XCTAssertEqual(academicArchive.restored(for: .campus).count, 2)
        XCTAssertEqual(dormitoryArchive.restored(for: .campus, service: .dormitory).count, 2)
        academic.clear()
        XCTAssertTrue(dormitory.cookies.isEmpty)
        dormitory.clear()
    }
    func testDormitoryUsesAuthenticatedBrowserTransportForAllPages() async throws {
        var pages: [Int] = []
        let client = CampusClient(route: .campus, service: .dormitory, browserTransport: { request in
            XCTAssertEqual(request.url?.host, "xsgl.nbt.edu.cn")
            let page = academicBody(request).contains("pageNumber=2") ? 2 : 1
            pages.append(page)
            let object = self.dormitoryPage(rows: [self.dormitoryRow("browser-\(page)")], total: 2, page: page, size: 1)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: object), response)
        })
        let records = try await client.dormitory(.room)
        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(records.count, 2)
    }
    private func dormitoryRow(_ id: String) -> [String: Any] {
        ["WID": id, "SSLMC":"A", "FJH":"101", "JCRQ":"2026-10-01", "JCLXDM_DISPLAY":"定期检查", "ZC":"4", "FS":9.5,
         "BZ": NSNull(), "FJ": NSNull(), "XN":"2026", "XQ":"1", "XN_DISPLAY":"2026-2027学年", "XQ_DISPLAY":"第一学期", "WGLXDM_DISPLAY":"地面整洁0.5"]
    }
    private func dormitoryPage(rows: [[String: Any]], total: Int = 1, page: Int = 1, size: Int = 50, kind: DormitoryKind = .room) -> [String: Any] {
        ["datas": [kind.action: ["rows": rows, "totalSize": total, "pageNumber": page, "pageSize": size]]]
    }
    private func clientForIncompleteDormitory() -> CampusClient {
        client(service: .dormitory) { _ in (200, self.dormitoryPage(rows: [], total: 2)) }
    }
    private func client(route: CampusRoute = .webVPN, service: CampusService = .academic, _ handler: @escaping AcademicMockURLProtocol.Handler) -> CampusClient {
        AcademicMockURLProtocol.setHandler(handler)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AcademicMockURLProtocol.self]
        return CampusClient(route: route, service: service, transport: URLSession(configuration: config))
    }
}

private func academicBody(_ request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return String(decoding: data, as: UTF8.self)
}

private final class AcademicMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Any)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func setHandler(_ handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let (status, value) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = try (value as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: value)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
