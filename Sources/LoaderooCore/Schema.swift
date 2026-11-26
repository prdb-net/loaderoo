import GRDB

/// The layout of Feed.sqlite. Add each later change as its own migration below the baseline.
enum Schema {
    static func migrate(_ store: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("baseline", migrate: baseline)
        try migrator.migrate(store)
    }

    /// Creates a new database, and completes one from a build that predates the migrator.
    /// Such a database can hold any subset of these tables and columns.
    private static func baseline(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS connection (id INTEGER PRIMARY KEY CHECK(id = 1), config BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS sourceClock (id TEXT PRIMARY KEY, poll DOUBLE, retry DOUBLE);
            CREATE TABLE IF NOT EXISTS offer (
                ref TEXT PRIMARY KEY, source TEXT NOT NULL, entry TEXT NOT NULL, payload BLOB NOT NULL,
                lastSeen DOUBLE NOT NULL, nextCheck DOUBLE, video TEXT, UNIQUE(source, entry));
            CREATE INDEX IF NOT EXISTS offerVideo ON offer(video);
            CREATE INDEX IF NOT EXISTS offerCheck ON offer(nextCheck,ref);
            CREATE TABLE IF NOT EXISTS metadata (video TEXT PRIMARY KEY, payload BLOB NOT NULL, fetched DOUBLE NOT NULL);
            CREATE TABLE IF NOT EXISTS folder(path TEXT PRIMARY KEY, offline BOOLEAN NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS libraryFile(
                path TEXT PRIMARY KEY, root TEXT NOT NULL, size INTEGER NOT NULL, modified DOUBLE NOT NULL,
                hash TEXT, video TEXT, title TEXT, studio TEXT, image TEXT, seen TEXT NOT NULL, checked DOUBLE);
            CREATE INDEX IF NOT EXISTS libraryVideo ON libraryFile(video);
            CREATE TABLE IF NOT EXISTS transfer(
                video TEXT PRIMARY KEY, title TEXT NOT NULL, studio TEXT, image TEXT, provider TEXT NOT NULL,
                endpoint TEXT NOT NULL, token TEXT UNIQUE NOT NULL, job TEXT, state TEXT NOT NULL,
                note TEXT, storage TEXT, localPath TEXT, created DOUBLE NOT NULL);
            CREATE TABLE IF NOT EXISTS paging(source TEXT PRIMARY KEY, offset INTEGER);
            CREATE TABLE IF NOT EXISTS transferSource(video TEXT PRIMARY KEY,entry TEXT NOT NULL,releaseName TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS completedFile(video TEXT PRIMARY KEY,size INTEGER NOT NULL,modified DOUBLE NOT NULL);
            CREATE TABLE IF NOT EXISTS studioRetry(video TEXT PRIMARY KEY,checked DOUBLE NOT NULL);
            CREATE TABLE IF NOT EXISTS staging(video TEXT PRIMARY KEY,path TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS filing(video TEXT PRIMARY KEY,plan BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS actorProfileCache(id TEXT PRIMARY KEY,payload BLOB,checked REAL NOT NULL);
            """)
        try PRDBCatalog.createTables(db)
        if try !db.columns(in: "paging").contains(where: { $0.name == "oldest" }) {
            try db.execute(sql: "ALTER TABLE paging ADD COLUMN oldest DOUBLE")
            try db.execute(sql: """
                UPDATE paging SET oldest = (SELECT MIN(json_extract(CAST(payload AS TEXT),'$.posted'))
                FROM offer WHERE offer.source = paging.source)
                """)
        }
        if try !db.columns(in: "transfer").contains(where: { $0.name == "jobName" }) {
            try db.execute(sql: """
                ALTER TABLE transfer ADD COLUMN jobName TEXT;
                ALTER TABLE transfer ADD COLUMN progress DOUBLE;
                ALTER TABLE transfer ADD COLUMN timeLeft TEXT;
                """)
        }
        if try !db.columns(in: "paging").contains(where: { $0.name == "historyPages" }) {
            // Older builds kept the exact next offset, but not the sizes of individual pages.
            try db.execute(sql: """
                ALTER TABLE paging ADD COLUMN historyPages INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE paging ADD COLUMN through DOUBLE;
                ALTER TABLE paging ADD COLUMN lastAttempt DOUBLE;
                UPDATE paging SET historyPages = (offset - 1) / 100 WHERE offset > 100;
                """)
        }
        // Earlier builds counted three rounds of refetching video details in this table.
        // The third round covers the first two.
        let refetched = try db.tableExists("previewUpgrade")
            ? Int.fetchOne(db, sql: "SELECT MAX(version) FROM previewUpgrade") ?? 0 : 0
        if refetched < 3 { try db.execute(sql: "UPDATE metadata SET fetched=0") }
        try db.execute(sql: "DROP TABLE IF EXISTS previewUpgrade")
    }
}
