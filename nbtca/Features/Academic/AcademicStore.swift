import Foundation
import Observation
import WebKit

@MainActor
protocol AcademicQuerySession: AnyObject {
    var hasCredentials: Bool { get }
    var storageNotice: String? { get }
    var client: CampusClient { get }
    func restoreSession() async throws
    func query<T>(_ operation: (CampusClient) async throws -> T) async throws -> T
    func persist()
    func expire()
    func stop()
}

extension CampusWebSession: AcademicQuerySession { }

@MainActor @Observable
final class AcademicStore {
    static let shared = AcademicStore()
    var kind: AcademicKind = .timetable
    var selectedTermID = "" {
        didSet {
            restoreCachedTimetable()
            if selectedTermID != oldValue { showCurrentWeek() }
            do { try cache.select(selectedTermID) }
            catch { cacheNotice = "课表选择未能保存：" + error.localizedDescription }
        }
    }
    var week = 1
    private(set) var route: CampusRoute?
    private(set) var terms: [AcademicTerm] = []
    private(set) var timetable: AcademicTimetable?
    private(set) var exams: [AcademicExam] = []
    private(set) var grades: [AcademicGrade] = []
    private(set) var hasSession = false
    private(set) var hasRememberedSession = false
    private(set) var loading = false
    private(set) var validating = false
    private(set) var error: String?
    private(set) var sessionNotice: String?
    private(set) var cacheNotice: String?
    private(set) var isUsingSavedTimetable = false
    private let cache: TimetableCache
    var hasSavedTimetables: Bool { !cache.entries.isEmpty }
    var savedAt: Date? { cache.saved(for: selectedTermID)?.savedAt }
    private var sessions: [CampusRoute: CampusWebSession] = [:]
    private var providedSessions: [CampusRoute: any AcademicQuerySession] = [:]
    private let sessionProvider: ((CampusRoute) -> any AcademicQuerySession)?
    private var requestID = UUID()
    private var sessionRevision = 0
    private var suspended = false
    private var completedQueryKey: String?
    var selectedTerm: AcademicTerm? { terms.first { $0.id == selectedTermID } }
    var canQuery: Bool { route != nil && selectedTerm != nil && hasSession && !validating && !suspended }
    // Session validation must retrigger the query even when its restored term
    // is identical to the locally cached selection.
    var queryKey: String { (route?.rawValue ?? "offline") + "|\(sessionRevision)|\(suspended)|\(canQuery)|" + selectedTermID + "|" + kind.rawValue }
    var hasLoadedCurrentQuery: Bool { canQuery && completedQueryKey == queryKey }
    init(cache: TimetableCache? = nil, sessionProvider: ((CampusRoute) -> any AcademicQuerySession)? = nil) {
        let cache = cache ?? .shared
        self.cache = cache
        self.sessionProvider = sessionProvider
        terms = cache.entries.map(\.term)
        selectedTermID = cache.selectedTermID
        cacheNotice = cache.error
        restoreCachedTimetable()
        showCurrentWeek()
        CampusSchoolSession.shared.register(self)
    }
    private func restoreCachedTimetable() {
        timetable = cache.saved(for: selectedTermID)?.timetable
        if var saved = timetable, saved.weekOneMonday == nil,
           let term = cache.saved(for: selectedTermID)?.term,
           let monday = VerifiedSchoolCalendar.weekOne(for: term), saved.acceptsWeekOne(monday) {
            saved.weekOneMonday = monday; timetable = saved
        }
        isUsingSavedTimetable = timetable != nil
    }
    func session(for route: CampusRoute) -> CampusWebSession {
        if let session = sessions[route] { return session }
        let session = CampusWebSession(route: route); sessions[route] = session; return session
    }
    private func querySession(for route: CampusRoute) -> any AcademicQuerySession {
        guard let sessionProvider else { return session(for: route) }
        if let existing = providedSessions[route] { return existing }
        let session = sessionProvider(route); providedSessions[route] = session; return session
    }
    private var remembersSchoolSession: Bool {
        if sessionProvider != nil { return CampusRoute.allCases.contains { querySession(for: $0).hasCredentials } }
        return CampusRoute.allCases.contains { CampusSchoolSession.shared.hasCredentials(for: $0) }
    }
    private func clearRecords() { restoreCachedTimetable(); exams = []; grades = []; completedQueryKey = nil }
    func resume() { suspended = false }
    func showCurrentWeek(at date: Date = Date()) {
        guard let timetable else { return }
        if selectedTerm?.current == false { week = 1 }
        else if let current = timetable.currentWeek(at: date) { week = current }
    }
    func clearSensitiveRecords() { suspended = true; requestID = UUID(); clearRecords(); loading = false }
    func activate(_ route: CampusRoute?) async {
        requestID = UUID(); self.route = route; sessionRevision += 1
        clearRecords(); error = nil; hasSession = false; loading = false; validating = false
        sessionNotice = nil
        hasRememberedSession = remembersSchoolSession
        guard let route else { return }
        let session = querySession(for: route); sessionNotice = session.storageNotice
        hasRememberedSession = remembersSchoolSession
        guard session.hasCredentials else { return }
        let revision = sessionRevision
        validating = true; defer { if revision == sessionRevision { validating = false } }
        do {
            try await session.restoreSession()
            let terms = try await session.query { try await $0.terms() }
            try Task.checkCancellation(); guard self.route == route, revision == sessionRevision else { return }
            applyTerms(terms); hasSession = true; session.persist(); sessionNotice = session.storageNotice
        } catch AcademicError.sessionExpired {
            if revision == sessionRevision {
                session.expire(); hasRememberedSession = remembersSchoolSession
                error = AcademicError.sessionExpired.localizedDescription
            }
        }
        catch is CancellationError { }
        catch { if revision == sessionRevision { self.error = error.localizedDescription } }
    }
    func finishLogin(cookies: [HTTPCookie], route: CampusRoute) async throws {
        guard self.route == route else { throw AcademicError.routeChanged }
        let session = querySession(for: route), revision = sessionRevision
        session.client.importCookies(cookies)
        try await session.restoreSession()
        let terms = try await session.query { try await $0.terms() }
        try Task.checkCancellation()
        guard self.route == route, revision == sessionRevision else { throw AcademicError.routeChanged }
        applyTerms(terms); hasSession = true; hasRememberedSession = true; error = nil
        session.persist(); sessionNotice = session.storageNotice
        sessionRevision += 1
        CampusSchoolSession.shared.didLogin()
    }
    private func applyTerms(_ values: [AcademicTerm]) {
        terms = values
        if !values.contains(where: { $0.id == selectedTermID }) {
            selectedTermID = values.first(where: \.current)?.id ?? values.first?.id ?? ""
        }
    }
    func reload() async {
        guard canQuery, let route, let term = selectedTerm else { return }
        let key = queryKey
        let id = UUID(); requestID = id; loading = true; error = nil; clearRecords()
        let kind = kind
        defer { if requestID == id { loading = false } }
        do {
            let session = querySession(for: route)
            switch kind {
            case .timetable:
                let result = try await session.query { try await $0.timetable(term) }
                try Task.checkCancellation(); guard requestID == id, queryKey == key else { return }
                timetable = result; isUsingSavedTimetable = false
                do { try cache.save(result, term: term); cacheNotice = nil }
                catch { cacheNotice = "课表未能保存：" + error.localizedDescription }
                showCurrentWeek()
            case .exams:
                let rows = try await session.query { try await $0.records(.exams, term: term) }
                try Task.checkCancellation(); guard requestID == id, queryKey == key else { return }
                exams = try AcademicParser.exams(rows)
            case .grades:
                let rows = try await session.query { try await $0.records(.grades, term: term) }
                try Task.checkCancellation(); guard requestID == id, queryKey == key else { return }
                grades = try AcademicParser.grades(rows)
            }
            completedQueryKey = key
            session.persist(); sessionNotice = session.storageNotice
        } catch is CancellationError { }
        catch {
            guard requestID == id, queryKey == key else { return }
            if case AcademicError.sessionExpired = error {
                querySession(for: route).expire(); hasSession = false; clearRecords()
                hasRememberedSession = remembersSchoolSession
            }
            self.error = error.localizedDescription
        }
    }
    func discardCachedTimetables() {
        do { try cache.clear(); cacheNotice = nil }
        catch { cacheNotice = "本地课表未能清除：" + error.localizedDescription }
        timetable = nil; isUsingSavedTimetable = false
    }
    func schoolIdentityChanged() {
        requestID = UUID(); sessionRevision += 1
        discardCachedTimetables(); exams = []; grades = []; completedQueryKey = nil
        hasSession = false; loading = false; validating = false
    }
    func resetSession() {
        requestID = UUID(); sessionRevision += 1
        sessions.values.forEach { $0.stop() }; sessions.removeAll()
        providedSessions.values.forEach { $0.stop() }; providedSessions.removeAll()
        sessionNotice = nil; hasRememberedSession = false
        discardCachedTimetables(); exams = []; grades = []; hasSession = false; terms = []; selectedTermID = ""
        completedQueryKey = nil; error = nil; loading = false; validating = false
    }
    func logout() async { await CampusSchoolSession.shared.logout() }
}
