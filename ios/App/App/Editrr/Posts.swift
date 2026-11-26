import SwiftUI
import UIKit
import UserNotifications
import FoundationModels

// The content plan: every edit holds its cuts (the Main cut and any Remixes), and each cut can go
// up with its lyrics and without. A post is just a day on one of those: nothing is rendered until
// post day, when one tap makes the video and opens the share sheet.

extension Notification.Name {
    /// A post's notification (or a post on creatrr's calendar) was tapped: open Edits, then that post.
    static let creatrrOpenPost = Notification.Name("creatrr.openPost")
    /// editrr should open the post waiting in `PostBook.pendingOpen`.
    static let editrrPost = Notification.Name("editrr.post")
    /// The posts changed (a day picked, a post marked posted, an edit deleted): creatrr's calendar redraws.
    static let creatrrPostsChanged = Notification.Name("creatrr.postsChanged")
    /// The weekly goal was changed in creatrr's Settings.
    static let creatrrGoalChanged = Notification.Name("creatrr.goalChanged")
}

/// One post's plan: the day it goes up, when it went up, and its caption.
struct PostPlan: Codable, Equatable, Sendable {
    /// The day it's planned for (the start of that day, on this phone). nil: not planned yet.
    var date: Date?
    /// When it was marked posted. nil: not posted yet.
    var posted: Date?
    var caption: String?

    var isPlanned: Bool { date != nil }
}

/// One cut of an edit: the Main cut, or a Remix made on the Performance page. Only the cuts are its
/// own (which video shows when, and their effects); the song, videos, words and overlays are the
/// edit's, so every cut has them.
struct Variation: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var cuts: [Cut]
    /// This cut with the lyrics on.
    var lyricsPost = PostPlan()
    /// This cut without them (or just as it is, when the edit has no lyrics).
    var plainPost = PostPlan()

    init(id: UUID = UUID(), name: String, cuts: [Cut]) {
        self.id = id
        self.name = name
        self.cuts = cuts
    }

    /// Anything missing from an older save keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Cut"
        cuts = (try? c.decodeIfPresent([Cut].self, forKey: .cuts)) ?? []
        lyricsPost = (try? c.decodeIfPresent(PostPlan.self, forKey: .lyricsPost)) ?? PostPlan()
        plainPost = (try? c.decodeIfPresent(PostPlan.self, forKey: .plainPost)) ?? PostPlan()
    }

    func plan(lyrics: Bool) -> PostPlan { lyrics ? lyricsPost : plainPost }

    mutating func change(lyrics: Bool, _ body: (inout PostPlan) -> Void) {
        if lyrics { body(&lyricsPost) } else { body(&plainPost) }
    }

    var isMain: Bool { !name.hasPrefix("Remix") }
}

extension SavedProject {
    /// Every cut of this edit, the Main cut first. An edit that never had a Remix or a planned post
    /// has only its Main cut, which uses the edit's own id.
    var cutList: [Variation] {
        if let variations, !variations.isEmpty { return variations }
        return [Variation(id: id, name: "Main cut", cuts: cuts)]
    }

    /// The cut on screen when the edit opens.
    var activeCut: UUID {
        let list = cutList
        if let active = activeVariation, list.contains(where: { $0.id == active }) { return active }
        return list[0].id
    }

    /// It has lyrics, so each cut can go up with them and without.
    var postsLyrics: Bool { !(lyrics ?? []).isEmpty }

    /// The ways each cut can go up: with lyrics first, then without (or just as it is).
    var postKinds: [Bool] { postsLyrics ? [true, false] : [false] }

    /// How many posts this edit can give: each cut, with and without lyrics.
    var postCount: Int { cutList.count * postKinds.count }

    var isPerformance: Bool { kind != "video" }

    /// Filmed and lined up, but not edited yet (one video all the way through), with nothing planned.
    var justFilmed: Bool {
        isPerformance && cutList.allSatisfy { $0.cuts.count <= 1 }
            && !cutList.contains { $0.lyricsPost.isPlanned || $0.plainPost.isPlanned }
    }

    /// Which song it is, so the same song doesn't go up two days running.
    var songKey: String { (songName ?? name).lowercased() }

    /// Turns the one implied Main cut into a real list, so a plan or a Remix has somewhere to live.
    mutating func makeCutsReal() {
        if variations == nil || variations!.isEmpty {
            variations = [Variation(id: id, name: "Main cut", cuts: cuts)]
        }
        if activeVariation == nil || !variations!.contains(where: { $0.id == activeVariation }) {
            activeVariation = variations![0].id
        }
    }

    mutating func changeCut(_ cut: UUID, _ body: (inout Variation) -> Void) {
        guard let index = variations?.firstIndex(where: { $0.id == cut }) else { return }
        body(&variations![index])
    }
}

/// The post being made right now (from its reminder or the calendar).
struct PostTarget: Equatable {
    let project: UUID
    let cut: UUID
    let lyrics: Bool
}

extension EditorModel {
    /// The post being made, as it stands now.
    var postingSlot: PostSlot? {
        guard let target = posting, let project = postProject(target.project),
              let cut = project.cutList.first(where: { $0.id == target.cut }) else { return nil }
        return PostSlot(project: project, cut: cut, lyrics: target.lyrics)
    }
}

/// One post: a cut of an edit, with or without its lyrics.
struct PostSlot: Identifiable {
    let project: SavedProject
    let cut: Variation
    let lyrics: Bool

    var plan: PostPlan { cut.plan(lyrics: lyrics) }
    var id: String { PostBook.key(project.id, cut.id, lyrics) }
    /// "Main cut · with lyrics"
    var label: String { PostBook.label(project, cut, lyrics) }
}

/// The content plan across every edit: the weekly goal, the counts on Edits, the days posts go up,
/// their reminders, and what creatrr's calendar shows. (Used on the main thread.)
enum PostBook {
    static let goalKey = "creatrr.postsPerWeek"

    /// Posts a week the artist wants to put out (3 until it's changed).
    static var goal: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: goalKey)
            return saved > 0 ? min(14, saved) : 3
        }
        set { UserDefaults.standard.set(max(1, min(14, newValue)), forKey: goalKey) }
    }

    /// Weeks start on Sunday.
    static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 1
        return cal
    }

    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    static func key(_ project: UUID, _ cut: UUID, _ lyrics: Bool) -> String {
        "\(project.uuidString)|\(cut.uuidString)|\(lyrics ? "L" : "P")"
    }

    static func parse(_ key: String) -> (project: UUID, cut: UUID, lyrics: Bool)? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 3, let project = UUID(uuidString: parts[0]), let cut = UUID(uuidString: parts[1]) else { return nil }
        return (project, cut, parts[2] == "L")
    }

    static func label(_ project: SavedProject, _ cut: Variation, _ lyrics: Bool) -> String {
        guard project.postsLyrics else { return cut.name }
        return cut.name + (lyrics ? " \u{00B7} with lyrics" : " \u{00B7} no lyrics")
    }

    /// Every post every edit can give, planned or not.
    static func slots(_ projects: [SavedProject]) -> [PostSlot] {
        projects.flatMap { project in
            project.cutList.flatMap { cut in project.postKinds.map { PostSlot(project: project, cut: cut, lyrics: $0) } }
        }
    }

    // MARK: Counts and how long you're covered

    struct Pipeline {
        var filmed = 0
        var editing = 0
        var ready = 0
        var posted = 0
        var goal = 3
        var line = ""
        /// Running low: film soon.
        var low = false
        /// The next 30 days from today: true where a post is planned (or went up today).
        var days: [Bool] = []
        /// How many of those days have a post.
        var covered = 0
        /// The first of those days with no post.
        var nextEmpty: Date?
        /// "12 of the next 30 days have a post (40%). Next empty day: Wednesday."
        var coverLine = ""
    }

    /// Filmed (lined up, not edited), Editing (edited, nothing planned), Ready (posts with a day,
    /// not posted yet) and Posted this week, plus one line on how long the planned posts last.
    static func pipeline(_ projects: [SavedProject], goal: Int, now: Date = Date()) -> Pipeline {
        var counts = Pipeline()
        counts.goal = goal
        let all = slots(projects)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        for project in projects where !isOlder(project, now: now) {
            if project.justFilmed {
                counts.filmed += 1
            } else if !slots([project]).contains(where: { $0.plan.isPlanned }) {
                counts.editing += 1
            }
        }
        counts.ready = all.filter { $0.plan.isPlanned && $0.plan.posted == nil }.count
        counts.posted = all.filter { slot in
            guard let posted = slot.plan.posted else { return false }
            return week?.contains(posted) ?? false
        }.count
        let left = runway(all, goal: goal, now: now)
        counts.line = left.line
        counts.low = left.low
        let cover = coverage(all, now: now)
        counts.days = cover.days
        counts.covered = cover.covered
        counts.nextEmpty = cover.nextEmpty
        let percent = Int((Double(cover.covered) / Double(max(1, cover.days.count)) * 100).rounded())
        counts.coverLine = "\(cover.covered) of the next \(cover.days.count) days have a post (\(percent)%)."
            + (cover.nextEmpty.map { " Next empty day: \(spoken($0, now: now))." } ?? " Every day has one.")
        return counts
    }

    /// The next 30 days from today: which have a post planned (or posted), how many do, and the
    /// first one with none. Even when you're covered for weeks, gaps show, so you film something new.
    static func coverage(_ all: [PostSlot], now: Date = Date()) -> (days: [Bool], covered: Int, nextEmpty: Date?) {
        let today = day(now)
        let taken = Set(all.compactMap { slot -> Date? in
            if let posted = slot.plan.posted { return day(posted) }
            return slot.plan.date.map { day($0) }
        })
        var days: [Bool] = []
        var nextEmpty: Date?
        for offset in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let has = taken.contains(day(date))
            days.append(has)
            if !has && nextEmpty == nil { nextEmpty = date }
        }
        return (days, days.filter { $0 }.count, nextEmpty)
    }

    /// How long the planned posts last: from today, each post no further from the one before than
    /// the goal asks (3 a week: every 3 days), up to the last one in that run. Under 2 days of
    /// that is running low. `last` is that last post's day, `runsOut` the day a post would be due
    /// after it.
    static func runway(_ all: [PostSlot], goal: Int, now: Date = Date()) -> (line: String, low: Bool, last: Date?, runsOut: Date?) {
        let today = day(now)
        let gap = max(1, Int((7.0 / Double(max(1, goal))).rounded(.up)))
        let ready = all.compactMap { slot -> Date? in
            guard slot.plan.posted == nil, let date = slot.plan.date, date >= today else { return nil }
            return date
        }.sorted()
        guard let first = ready.first else {
            return ("Nothing planned yet. Pick days for your posts, or film soon.", true, nil, nil)
        }
        guard let reach = calendar.date(byAdding: .day, value: gap, to: today), first <= reach else {
            return ("Your next post is \(spoken(first, now: now)). Plan one sooner to keep up.", true, nil, nil)
        }
        var last = today
        for date in ready {
            guard let limit = calendar.date(byAdding: .day, value: gap, to: last), date <= limit else { break }
            last = max(last, date)
        }
        let out = calendar.date(byAdding: .day, value: gap, to: last)
        let daysLeft = calendar.dateComponents([.day], from: today, to: last).day ?? 0
        if daysLeft < 2 {
            let line = daysLeft == 0
                ? "Film soon: today's post is the last one planned."
                : "Film soon: your last planned post is tomorrow."
            return (line, true, last, out)
        }
        return ("You're good through \(spoken(last, now: now)).", false, last, out)
    }

    /// "today", "tomorrow", "Friday" (this week) or "Fri, Nov 28".
    static func spoken(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return "today" }
        if let next = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: next) { return "tomorrow" }
        let days = cal.dateComponents([.day], from: day(now), to: day(date)).day ?? 99
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Posted a month ago or more, with nothing left to post: it folds into Older on Edits.
    /// An edit with anything not posted yet never folds away.
    static func isOlder(_ project: SavedProject, now: Date = Date()) -> Bool {
        let planned = slots([project]).map(\.plan).filter(\.isPlanned)
        guard !planned.isEmpty, planned.allSatisfy({ $0.posted != nil }),
              let last = planned.compactMap(\.posted).max(),
              let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) else { return false }
        return last < monthAgo && project.updated < monthAgo
    }

    // MARK: Fill the calendar

    /// Plan all, like filling a glass of water: posts go one a day from today, with no gaps, so the
    /// days close by fill up before any go further out. Every post planned after today moves too,
    /// so each new edit mixes in with the rest: edits take turns (and songs, where they can), never
    /// the same edit two days running while another has posts left. Posted posts, and anything on
    /// today or before, stay put.
    static func fill(adding project: SavedProject?, among projects: [SavedProject],
                     now: Date = Date()) -> [(project: UUID, cut: UUID, lyrics: Bool, date: Date)] {
        let cal = calendar
        let today = day(now)
        var all = projects
        if let project {
            if let at = all.firstIndex(where: { $0.id == project.id }) { all[at] = project } else { all.append(project) }
        }
        // Days that keep what they have: anything posted, and anything planned for today or before.
        var fixed = Set<Date>()
        for slot in slots(all) {
            if let posted = slot.plan.posted {
                fixed.insert(day(posted))
            } else if let date = slot.plan.date, day(date) <= today {
                fixed.insert(day(date))
            }
        }
        // What moves: every post planned after today, and this edit's posts with no day yet. Each
        // edit keeps its own order: its planned ones as they were, then its new ones.
        struct Group { let id: UUID; let song: String; var posts: [PostSlot] }
        var groups: [Group] = []
        for each in all {
            let mine = slots([each]).filter { slot in
                guard slot.plan.posted == nil else { return false }
                if let date = slot.plan.date { return day(date) > today }
                return each.id == project?.id
            }
            guard !mine.isEmpty else { continue }
            let planned = mine.filter { $0.plan.date != nil }.sorted { $0.plan.date! < $1.plan.date! }
            // New ones: every cut with lyrics first, then every cut without, so the looks change.
            let new = mine.filter { $0.plan.date == nil }.enumerated().sorted { a, b in
                let kindA = each.postKinds.firstIndex(of: a.element.lyrics) ?? 0
                let kindB = each.postKinds.firstIndex(of: b.element.lyrics) ?? 0
                return kindA != kindB ? kindA < kindB : a.offset < b.offset
            }.map(\.element)
            groups.append(Group(id: each.id, song: each.songKey, posts: planned + new))
        }
        // Mix: each day goes to the edit with the most left, but not the edit (or, where there's a
        // choice, the song) of the day before.
        var order: [PostSlot] = []
        var lastEdit: UUID?
        var lastSong: String?
        while groups.contains(where: { !$0.posts.isEmpty }) {
            let left = groups.indices.filter { !groups[$0].posts.isEmpty }
            let otherSong = left.filter { groups[$0].song != lastSong && groups[$0].id != lastEdit }
            let otherEdit = left.filter { groups[$0].id != lastEdit }
            let pool = !otherSong.isEmpty ? otherSong : (!otherEdit.isEmpty ? otherEdit : left)
            // Most left first; on a tie, the edit whose next post was planned soonest.
            let pick = pool.max { a, b in
                let countA = groups[a].posts.count, countB = groups[b].posts.count
                if countA != countB { return countA < countB }
                let dateA = groups[a].posts[0].plan.date ?? .distantFuture
                let dateB = groups[b].posts[0].plan.date ?? .distantFuture
                return dateA > dateB
            }!
            order.append(groups[pick].posts.removeFirst())
            lastEdit = groups[pick].id
            lastSong = groups[pick].song
        }
        // Pour: one a day from today (tomorrow, when today already has one), skipping kept days.
        var out: [(project: UUID, cut: UUID, lyrics: Bool, date: Date)] = []
        var next = today
        for slot in order {
            while fixed.contains(next) { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
            out.append((slot.project.id, slot.cut.id, slot.lyrics, next))
            next = cal.date(byAdding: .day, value: 1, to: next) ?? next
        }
        return out
    }

    /// Days until the content runs out: from today, one post a day, the days in a row with a post
    /// (posted or planned), plus every finished post not on the calendar yet (each is a day more
    /// once it's planned). Today with nothing yet doesn't break the run when tomorrow has one.
    static func daysOfContent(_ projects: [SavedProject], now: Date = Date()) -> Int {
        let cal = calendar
        let today = day(now)
        let all = slots(projects)
        let taken = Set(all.compactMap { slot -> Date? in
            if let posted = slot.plan.posted { return day(posted) }
            return slot.plan.date.map { day($0) }
        })
        var run = 0
        var at = taken.contains(today) ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
        while taken.contains(at), run < 3650 {
            run += 1
            at = cal.date(byAdding: .day, value: 1, to: at) ?? at
        }
        let waiting = projects.filter { !$0.justFilmed && !isOlder($0, now: now) }
            .flatMap { slots([$0]) }
            .filter { $0.plan.date == nil && $0.plan.posted == nil }
            .count
        return run + waiting
    }

    // MARK: Reminders and creatrr's calendar

    /// A post waiting to be opened (from its notification or creatrr's calendar).
    static var pendingOpen: String?

    private static let scheduledKey = "creatrr.postReminders"
    /// Post day reminders go out at 10 in the morning.
    static let reminderHour = 10

    /// Something about the posts changed: their reminders are set again and creatrr's calendar
    /// redraws. Export files left over from earlier days are cleared too.
    static func changed(_ projects: [SavedProject]) {
        reschedule(projects)
        clearOldExports()
        NotificationCenter.default.post(name: .creatrrPostsChanged, object: nil)
    }

    /// One reminder on each post's day, and one more two days before the planned posts run out.
    /// Nothing else.
    static func reschedule(_ projects: [SavedProject]) {
        let center = UNUserNotificationCenter.current()
        let earlier = UserDefaults.standard.stringArray(forKey: scheduledKey) ?? []
        if !earlier.isEmpty { center.removePendingNotificationRequests(withIdentifiers: earlier) }
        let now = Date()
        let all = slots(projects)
        var requests: [UNNotificationRequest] = []
        let upcoming = all.compactMap { slot -> (PostSlot, Date)? in
            guard slot.plan.posted == nil, let date = slot.plan.date,
                  let fire = calendar.date(bySettingHour: reminderHour, minute: 0, second: 0, of: date),
                  fire > now else { return nil }
            return (slot, fire)
        }.sorted { $0.1 < $1.1 }
        for (slot, fire) in upcoming.prefix(60) {
            let content = UNMutableNotificationContent()
            content.title = "Time to post"
            content.body = "\(slot.project.name): \(slot.label). Tap to make it and share."
            content.sound = .default
            content.userInfo = ["post": slot.id]
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(UNNotificationRequest(identifier: "creatrr.post." + slot.id, content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
        // Running low: one heads-up the day before the last planned post (none if that's already past).
        let left = runway(all, goal: goal, now: now)
        if let last = left.last, let before = calendar.date(byAdding: .day, value: -1, to: last),
           let fire = calendar.date(bySettingHour: reminderHour, minute: 0, second: 0, of: before), fire > now {
            let content = UNMutableNotificationContent()
            content.title = "Film soon"
            content.body = "Tomorrow's post is the last one planned. One shoot can give you a week of posts."
            content.sound = .default
            content.userInfo = ["runway": true]
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(UNNotificationRequest(identifier: "creatrr.runway", content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
        UserDefaults.standard.set(requests.map(\.identifier), forKey: scheduledKey)
        guard !requests.isEmpty else { return }
        Task {
            // Asks once; after that it only says whether it's allowed.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for request in requests { try? await center.add(request) }
        }
    }

    /// Exported videos are only made on post day and handed to the share sheet; any left over in
    /// the phone's temporary folder from earlier days are thrown away.
    static func clearOldExports() {
        let folder = FileManager.default.temporaryDirectory
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("creatrr-") && file.pathExtension == "mp4" {
            let made = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if made < dayAgo { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Small thumbnails for creatrr's calendar, kept until the edit's thumbnail changes.
    private static var thumbCache: [UUID: (made: Date, url: String)] = [:]

    private static func smallThumb(_ id: UUID) -> String? {
        let file = ProjectStore.root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("thumb.jpg")
        let made = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let kept = thumbCache[id], kept.made == made { return kept.url }
        guard let image = UIImage(contentsOfFile: file.path), image.size.width > 0 else { return nil }
        let width: CGFloat = 160
        let size = CGSize(width: width, height: (width * image.size.height / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.7) else { return nil }
        let url = "data:image/jpeg;base64," + data.base64EncodedString()
        thumbCache[id] = (made, url)
        return url
    }

    /// What creatrr's calendar shows: each planned post on its day with its edit's thumbnail, and the goal.
    static func webPayload(_ projects: [SavedProject]) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        var posts: [[String: Any]] = []
        for slot in slots(projects) {
            guard let date = slot.plan.date else { continue }
            var post: [String: Any] = ["key": slot.id, "date": format.string(from: date), "name": slot.project.name,
                                       "cut": slot.label, "posted": slot.plan.posted != nil]
            if let thumb = smallThumb(slot.project.id) { post["thumb"] = thumb }
            posts.append(post)
        }
        let payload: [String: Any] = ["goal": goal, "posts": posts]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "{\"goal\":3,\"posts\":[]}" }
        return text
    }
}

// MARK: - Caption ideas

/// A caption idea for a post, from Apple's on-device model (nothing leaves the phone).
enum CaptionWriter {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static func suggest(song: String, lyrics: [LyricWord], cut: String, before: String?) async throws -> String {
        let words = lyrics.prefix(40).map(\.text).joined(separator: " ")
        let instructions = """
        You write short social media captions for musicians posting a performance video of their own song \
        on Instagram, TikTok and YouTube Shorts. Write in the artist's own voice, first person, casual and \
        warm. One or two short sentences, under 150 characters. At most one emoji. At most two hashtags, at \
        the end. No quotation marks. Never invent facts like release dates, places or names.
        """
        var prompt = "The song is called \(song). This post is the \(cut)."
        if !words.isEmpty { prompt += " Some of its lyrics: \(words)" }
        if let before, !before.isEmpty { prompt += " Write something different from this caption: \(before)" }
        prompt += " Write one caption."
        let session = LanguageModelSession(instructions: instructions)
        let answer = try await session.respond(to: prompt)
        return answer.content.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} \n"))
    }
}

// MARK: - Edits home: the counts, the weekly goal, the plan-it card

/// Filmed, Editing, Ready and Posted this week, over one line on how long the planned posts last.
/// Tap Posted to change the weekly goal.
/// The next 30 days as 30 tiny stars spiraling out from today, lit (yellow) where a post is
/// planned. They drift slowly, like dust in the light; still when Reduce Motion is on.
struct CoverageStars: View {
    let days: [Bool]
    @Environment(\.accessibilityReduceMotion) private var still

    /// Where each day sits in a 36 x 36 box: a spiral, today in the middle.
    private static let spots: [CGPoint] = (0..<30).map { i in
        let angle = Double(i) * 2.4
        let distance = 3 + Double(i).squareRoot() * 2.6
        // A small fixed nudge per star, so it looks scattered rather than drawn with a ruler.
        let nudgeX = (sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) * 1.5
        let nudgeY = (sin(Double(i) * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1) * 1.5
        return CGPoint(x: 18 + cos(angle) * distance + nudgeX, y: 18 + sin(angle) * distance + nudgeY)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let scale = min(size.width, size.height) / 36
                for (i, spot) in Self.spots.enumerated() {
                    let lit = i < days.count && days[i]
                    let seed = Double(i)
                    // Each star wanders on its own slow loop, under a point either way.
                    let dx = sin(t * (0.35 + seed.truncatingRemainder(dividingBy: 5) * 0.06) + seed * 1.7) * 0.7
                    let dy = cos(t * (0.3 + seed.truncatingRemainder(dividingBy: 7) * 0.05) + seed * 2.3) * 0.7
                    let radius = lit ? 1.8 : 1.1
                    let x = (spot.x + dx) * scale, y = (spot.y + dy) * scale, r = radius * scale
                    let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    if lit {
                        // A soft halo that breathes a little, then the star.
                        let breathe = 0.18 + 0.1 * sin(t * 0.8 + seed)
                        let halo = Path(ellipseIn: CGRect(x: x - r * 2.2, y: y - r * 2.2, width: r * 4.4, height: r * 4.4))
                        context.fill(halo, with: .color(Tint.accent.opacity(breathe)))
                        context.fill(dot, with: .color(Tint.accent))
                    } else {
                        context.fill(dot, with: .color(.white.opacity(0.22)))
                    }
                }
            }
        }
    }
}

struct PipelineBar: View {
    let projects: [SavedProject]
    let goal: Int
    let changeGoal: () -> Void

    var body: some View {
        // Redrawn every minute, so the days count goes down as days pass and up as edits come in.
        TimelineView(.everyMinute) { timeline in
            content(now: timeline.date)
        }
    }

    private func content(now: Date) -> some View {
        let counts = PostBook.pipeline(projects, goal: goal, now: now)
        let days = PostBook.daysOfContent(projects, now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                cell("\(counts.filmed)", "Filmed", .white)
                cell("\(counts.editing)", "Editing", .white)
                cell("\(counts.ready)", "Ready", Tint.accent)
                Button(action: changeGoal) {
                    cell("\(counts.posted)/\(counts.goal)", "Posted", counts.posted >= counts.goal ? Tint.good : .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Posted this week: \(counts.posted) of \(counts.goal). Change the weekly goal")
            }
            // The next 30 days as a little spiral of stars (lit where a post is planned), then one
            // big number: the days until the content runs out.
            HStack(alignment: .center, spacing: 12) {
                CoverageStars(days: counts.days)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                Text("\(days)")
                    .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Tint.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: days)
                Text(days == 1 ? "day until your content runs out" : "days until your content runs out")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func cell(_ number: String, _ name: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(number)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Tint.surface, in: Corner.card)
        .accessibilityElement(children: .combine)
    }
}

/// Posts a week: the number creatrr plans around.
struct GoalSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Posts a week").font(.title2.weight(.bold))
            HStack(spacing: 28) {
                Button { model.setGoal(model.postGoal - 1) } label: {
                    Image(systemName: "minus").font(.title2.weight(.bold)).frame(width: 56, height: 56)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.postGoal <= 1)
                .accessibilityLabel("Fewer")
                Text("\(model.postGoal)")
                    .font(.system(size: 54, weight: .bold).monospacedDigit())
                    .frame(minWidth: 70)
                Button { model.setGoal(model.postGoal + 1) } label: {
                    Image(systemName: "plus").font(.title2.weight(.bold)).frame(width: 56, height: 56)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.postGoal >= 14)
                .accessibilityLabel("More")
            }
            Text("Plan all fills your calendar one post a day from today, and creatrr tells you when it's time to film more to keep up with this.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(GlassButtonStyle(selected: true, big: true))
        }
        .foregroundStyle(.white)
        .padding(24)
        .padding(.top, 10)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }
}

/// On Edits home, for the last edit with posts left to plan: how many posts it can give, and one
/// tap to plan them all.
struct PlanCard: View {
    let project: SavedProject
    let planAll: () -> Void
    let seeAll: () -> Void
    let hide: () -> Void

    var body: some View {
        let left = PostBook.slots([project]).filter { !$0.plan.isPlanned && $0.plan.posted == nil }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\u{201C}\(project.name)\u{201D} can give you \(project.postCount) post\(project.postCount == 1 ? "" : "s")")
                        .font(.headline)
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: hide) {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel("Not now")
            }
            HStack(spacing: 8) {
                Button(action: planAll) {
                    Label(left == project.postCount ? "Plan all \(left)" : "Plan the other \(left)", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(GlassButtonStyle(selected: true))
                Button("See them", action: seeAll)
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tint.surface, in: Corner.card)
    }

    private var hint: String {
        let cuts = project.cutList.count
        var bits: [String] = []
        bits.append(cuts == 1 ? "1 cut" : "\(cuts) cuts")
        if project.postsLyrics { bits.append("each with lyrics and without") }
        var line = bits.joined(separator: ", ") + "."
        if project.isPerformance, cuts < 3 { line += " Remix on the Performance page for more." }
        return line
    }
}

// MARK: - Posts: every cut of one edit and the days they go up

/// Every cut of one edit (the Main cut and any Remixes), each with and without lyrics, and the day
/// each goes up. Tap one to pick its day, write or get a caption, or mark it posted.
struct PostsSheet: View {
    @Bindable var model: EditorModel
    let projectID: UUID
    /// Open from inside the editor: each cut can be put on screen to edit it.
    var inEditor = false
    @Environment(\.dismiss) private var dismiss
    /// The post that's open (its key).
    @State private var open: String?
    @State private var captionDraft = ""
    @State private var captionBusy = false
    @State private var captionProblem: String?
    @State private var deleting: Variation?

    var body: some View {
        Group {
            if let project = model.postProject(projectID) {
                content(project)
            } else {
                Text("This edit isn't here anymore.").padding(30)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { commitCaption() }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete this cut", role: .destructive) {
                if let cut = deleting { model.deleteCut(projectID, cut: cut.id) }
                deleting = nil
            }
        } message: {
            Text("Its posts come off the calendar. The Main cut and your videos stay.")
        }
    }

    private func content(_ project: SavedProject) -> some View {
        let slots = PostBook.slots([project])
        let planned = slots.filter { $0.plan.isPlanned }.count
        let left = slots.filter { !$0.plan.isPlanned && $0.plan.posted == nil }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Posts").font(.title2.weight(.bold))
                    Text("This edit can give you \(project.postCount) post\(project.postCount == 1 ? "" : "s"). \(planned) planned.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                ForEach(tips(project), id: \.self) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "lightbulb").foregroundStyle(Tint.accent)
                        Text(tip).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                }
                if left > 0 {
                    Button {
                        commitCaption()
                        open = nil
                        model.planAll(projectID)
                    } label: {
                        Label(left == project.postCount ? "Plan all \(left) for me" : "Plan the other \(left) for me",
                              systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle(selected: true, big: true))
                    Text("Up to \(model.postGoal) a week from tomorrow, spread out, never the same song two days running.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                ForEach(project.cutList) { cut in
                    cutCard(project, cut)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func tips(_ project: SavedProject) -> [String] {
        var list: [String] = []
        if project.isPerformance, project.cutList.count < 3 {
            list.append("Remix on the Performance page makes another cut from the same takes: \(project.postKinds.count) more post\(project.postKinds.count == 1 ? "" : "s") each time.")
        }
        if !project.postsLyrics {
            list.append("Add lyrics and every cut can go up twice, with them and without.")
        }
        if list.count < 2 {
            list.append("A caption on each post makes the same video feel new. Tap a post to add one.")
        }
        return Array(list.prefix(2))
    }

    private func cutCard(_ project: SavedProject, _ cut: Variation) -> some View {
        let showing = inEditor && project.activeCut == cut.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(cut.name).font(.headline)
                if showing {
                    Text("On screen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Tint.accent)
                }
                Spacer()
                if inEditor && !showing {
                    Button("Edit this cut") {
                        commitCaption()
                        model.useCut(cut.id)
                        dismiss()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(GlassButtonStyle())
                }
                if !cut.isMain {
                    Button { deleting = cut } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel("Delete \(cut.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            ForEach(project.postKinds, id: \.self) { lyrics in
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                slotRow(PostSlot(project: project, cut: cut, lyrics: lyrics))
            }
        }
        .background(Tint.surface2.opacity(0.7))
    }

    private func slotRow(_ slot: PostSlot) -> some View {
        let isOpen = open == slot.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                commitCaption()
                withAnimation(.snappy) {
                    if isOpen {
                        open = nil
                    } else {
                        open = slot.id
                        captionDraft = slot.plan.caption ?? ""
                        captionProblem = nil
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: slot.lyrics ? "quote.bubble" : "film")
                        .frame(width: 22)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(kindName(slot))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    status(slot)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                details(slot)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private func kindName(_ slot: PostSlot) -> String {
        slot.project.postsLyrics ? (slot.lyrics ? "With lyrics" : "No lyrics") : "This cut"
    }

    @ViewBuilder private func status(_ slot: PostSlot) -> some View {
        let plan = slot.plan
        if let posted = plan.posted {
            Label("Posted \(posted.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tint.good)
        } else if let date = plan.date {
            let late = date < PostBook.day(Date())
            Text(late ? "Was \(PostBook.spoken(date))" : PostBook.spoken(date).capitalizedFirst)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(late ? Tint.warn : Tint.accent)
        } else {
            Text("Pick a day")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder private func details(_ slot: PostSlot) -> some View {
        let plan = slot.plan
        let ids = (project: slot.project.id, cut: slot.cut.id, lyrics: slot.lyrics)
        let tomorrow = PostBook.calendar.date(byAdding: .day, value: 1, to: PostBook.day(Date())) ?? Date()
        DatePicker("Post day", selection: Binding(
            get: { plan.date ?? tomorrow },
            set: { model.setPostDay(ids.project, cut: ids.cut, lyrics: ids.lyrics, to: $0) }),
                   displayedComponents: .date)
            .datePickerStyle(.graphical)
            .environment(\.calendar, PostBook.calendar)
            .tint(Tint.accent)
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            TextField("Write one, or get an idea", text: $captionDraft, axis: .vertical)
                .lineLimit(2...5)
                .padding(10)
                .background(Tint.surface3)
                .onSubmit { commitCaption() }
            if CaptionWriter.isAvailable {
                Button {
                    suggest(slot)
                } label: {
                    Label(captionBusy ? "Writing one…" : (captionDraft.isEmpty ? "Get a caption idea" : "Another idea"),
                          systemImage: "sparkles")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(captionBusy)
            }
            if let captionProblem {
                Text(captionProblem).font(.caption).foregroundStyle(Tint.bad)
            }
            Text("It's copied for you when you post, so you can paste it in.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        HStack(spacing: 8) {
            if plan.posted == nil {
                Button("Mark posted") {
                    commitCaption()
                    model.setPosted(ids.project, cut: ids.cut, lyrics: ids.lyrics, true)
                }
                .buttonStyle(GlassButtonStyle())
            } else {
                Button("Not posted yet") {
                    model.setPosted(ids.project, cut: ids.cut, lyrics: ids.lyrics, false)
                }
                .buttonStyle(GlassButtonStyle())
            }
            if plan.isPlanned, plan.posted == nil {
                Button("Clear the day") {
                    model.setPostDay(ids.project, cut: ids.cut, lyrics: ids.lyrics, to: nil)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    /// Writes the caption being typed into the open post.
    private func commitCaption() {
        guard let key = open, let ids = PostBook.parse(key),
              let project = model.postProject(projectID),
              let cut = project.cutList.first(where: { $0.id == ids.cut }) else { return }
        let text = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let was = cut.plan(lyrics: ids.lyrics).caption ?? ""
        guard text != was else { return }
        model.setCaption(ids.project, cut: ids.cut, lyrics: ids.lyrics, text.isEmpty ? nil : text)
    }

    private func suggest(_ slot: PostSlot) {
        captionBusy = true
        captionProblem = nil
        let song = slot.project.songName ?? slot.project.name
        let words = slot.project.lyrics ?? []
        let label = slot.label
        let before = captionDraft
        Task {
            do {
                let idea = try await CaptionWriter.suggest(song: song, lyrics: words, cut: label, before: before)
                captionDraft = idea
                commitCaption()
            } catch {
                captionProblem = "Couldn't get an idea just now: \(error.localizedDescription)"
            }
            captionBusy = false
        }
    }
}

extension String {
    /// "tomorrow" to "Tomorrow".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
