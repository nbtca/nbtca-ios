import Foundation
import Observation
import WebKit

@MainActor @Observable
final class DormitoryStore {
    static let shared = DormitoryStore()
    private(set) var records: [DormitoryReport] = []
    private(set) var route: CampusRoute?
    private(set) var hasSession = false
    private(set) var hasRememberedSession = false
    private(set) var loading = false
    private(set) var validating = false
    private(set) var error: String?
    private(set) var sessionNotice: String?
    private var sessions: [CampusRoute: CampusWebSession] = [:]
    private var revision = UUID()
    private var requestID = UUID()
    private var suspended = false
    var queryKey: String { "\(route?.rawValue ?? "offline")|\(revision)|\(suspended)" }
    init() { CampusSchoolSession.shared.register(self) }
    func session(for route: CampusRoute) -> CampusWebSession {
        if let session = sessions[route] { return session }
        let session = CampusWebSession(route: route, service: .dormitory)
        sessions[route] = session; return session
    }
    func resume() { suspended = false }
    func clearSensitiveRecords() { suspended = true; records = []; requestID = UUID(); loading = false }
    func activate(_ route: CampusRoute?) async {
        revision = UUID(); requestID = UUID(); self.route = route; records = []; error = nil; hasSession = false; validating = false; loading = false
        hasRememberedSession = CampusRoute.allCases.contains { CampusSchoolSession.shared.hasCredentials(for: $0) }; sessionNotice = nil
        guard let route else { return }
        let session = session(for: route), token = revision
        hasRememberedSession = CampusRoute.allCases.contains { CampusSchoolSession.shared.hasCredentials(for: $0) }; sessionNotice = session.storageNotice
        guard session.hasCredentials else { return }
        validating = true; defer { if revision == token { validating = false } }
        do {
            try await session.restoreSession()
            _ = try await session.client.dormitory(.room, firstPageOnly: true)
            try Task.checkCancellation(); guard revision == token, self.route == route else { return }
            hasSession = true; session.persist(); sessionNotice = session.storageNotice
            revision = UUID(); validating = false
        } catch is CancellationError { }
        catch {
            guard revision == token else { return }
            if case AcademicError.sessionExpired = error { session.expire(); hasRememberedSession = CampusRoute.allCases.contains { CampusSchoolSession.shared.hasCredentials(for: $0) } }
            self.error = error.localizedDescription
        }
    }
    func finishLogin(cookies: [HTTPCookie], route: CampusRoute) async throws {
        guard self.route == route else { throw AcademicError.routeChanged }
        let session = session(for: route), token = revision
        session.client.importCookies(cookies)
        try await session.restoreSession()
        try await session.client.validateDormitorySession()
        try Task.checkCancellation(); guard self.route == route, revision == token else { throw AcademicError.routeChanged }
        hasSession = true; hasRememberedSession = true; error = nil
        session.persist(); sessionNotice = session.storageNotice; revision = UUID()
        CampusSchoolSession.shared.didLogin()
    }
    func reload() async {
        guard let route, hasSession, !validating, !suspended else { return }
        let id = UUID(); requestID = id; loading = true; error = nil; records = []
        let session = session(for: route)
        defer { if requestID == id { loading = false } }
        do {
            let result = try await session.query { try await $0.dormitoryReports() }
            try Task.checkCancellation(); guard requestID == id, self.route == route else { return }
            records = result; session.persist(); sessionNotice = session.storageNotice
        } catch is CancellationError { }
        catch {
            guard requestID == id else { return }
            if case AcademicError.sessionExpired = error {
                session.expire(); hasSession = false; hasRememberedSession = CampusRoute.allCases.contains { CampusSchoolSession.shared.hasCredentials(for: $0) }
            }
            self.error = error.localizedDescription
        }
    }
    func schoolIdentityChanged() {
        revision = UUID(); requestID = UUID(); records = []
        hasSession = false; loading = false; validating = false
    }
    func resetSession() {
        revision = UUID(); requestID = UUID()
        sessions.values.forEach { $0.stop() }; sessions.removeAll()
        records = []; hasSession = false; hasRememberedSession = false
        loading = false; validating = false; error = nil; sessionNotice = nil
    }
    func logout() async { await CampusSchoolSession.shared.logout() }
}
