//! The SDK's extension tables in the wallet database.
//!
//! Tables this SDK stores alongside `zcash_client_sqlite`'s own schema follow the wallet
//! database's extension contract (see `WalletMigrator::with_external_migrations`): every
//! name carries the `ext_zcashlc_` prefix (the wallet promises never to use `ext_`), and
//! the schema is created and evolved exclusively by the [`schemerz`] migrations registered
//! here — never ad hoc at call time — so extension tables share the wallet database's
//! schema versioning. Runtime access goes through
//! [`WalletDb::transactionally_with_extension`], whose authorizer confines writes to the
//! `ext_` namespace and refuses schema changes outright.
//!
//! [`zcashlc_init_data_database`](crate::zcashlc_init_data_database) applies these
//! migrations alongside the wallet's own; every other entry point may assume the tables
//! exist, because the platform initializes the database before using it (the Swift
//! `Initializer` does this at startup).
//!
//! [`WalletDb::transactionally_with_extension`]: zcash_client_sqlite::WalletDb::transactionally_with_extension

use std::collections::HashSet;

use schemerz_rusqlite::RusqliteMigration;
use uuid::Uuid;
use zcash_client_sqlite::wallet::init::{WalletMigrationError, migrations::V_0_22_0_RC6};

/// The immediate-run record: one row per account naming the most recently broadcast
/// immediate-lane sweep and the chain tip it was recorded at (see [`crate::migration`]).
pub(crate) const IMMEDIATE_RUNS_TABLE: &str =
    "ext_zcashlc_orchard_ironwood_migration_immediate_runs";

/// The SDK's external migrations, in the form [`WalletMigrator::with_external_migrations`]
/// accepts.
///
/// # Retired migrations
///
/// `AddInvalidTransferMarksTable` (id `0e1fd980-5cad-41c5-a6db-183dab527dcc` — reserved
/// forever, never reuse it) created `ext_zcashlc_orchard_ironwood_migration_invalid_marks`,
/// the side table that recorded terminal pool-migration rejection classifications back when
/// the engine had no failure states. The engine now records rejection testimony and adjudicates
/// it through the sqlite satisfiability oracle, so the migration is no longer registered: fresh
/// wallets never create the table, and [`DropRetiredInvalidMarksTable`] drops it wherever an
/// earlier build left it behind. Removing the registration is
/// safe because `schemerz`'s `Migrator::up` walks REGISTERED migrations only and checks
/// each against the applied set — a recorded id it no longer knows is simply never
/// consulted, so wallets that already ran the migration keep its inert row in the
/// migrations table and are otherwise unaffected.
///
/// [`WalletMigrator::with_external_migrations`]: zcash_client_sqlite::wallet::init::WalletMigrator::with_external_migrations
pub(crate) fn external_migrations() -> Vec<Box<dyn RusqliteMigration<Error = WalletMigrationError>>>
{
    vec![
        Box::new(AddImmediateRunsTable),
        Box::new(DropRetiredInvalidMarksTable),
    ]
}

const ADD_IMMEDIATE_RUNS_TABLE_ID: Uuid = Uuid::from_u128(0x9cd25140_4f7e_4bf4_9e48_de9551fa09fc);

/// Where earlier SDK versions kept the immediate-run record, creating the table on demand at
/// every read-write migration call. [`AddImmediateRunsTable`] moves its rows over and drops it.
const LEGACY_IMMEDIATE_RUNS_TABLE: &str = "sdk_immediate_runs";

/// Adds [`IMMEDIATE_RUNS_TABLE`].
///
/// A wallet upgraded from an SDK that kept the record in [`LEGACY_IMMEDIATE_RUNS_TABLE`] has
/// its rows carried over and that table dropped, so a sweep still in flight across the upgrade
/// keeps reporting progress. The account is stored as raw uuid bytes rather than a foreign key
/// into `accounts`, per the extension contract's warning against depending on wallet-internal
/// ids.
struct AddImmediateRunsTable;

impl schemerz::Migration<Uuid> for AddImmediateRunsTable {
    fn id(&self) -> Uuid {
        ADD_IMMEDIATE_RUNS_TABLE_ID
    }

    fn dependencies(&self) -> HashSet<Uuid> {
        // The table refers to no wallet schema, so it needs no particular internal migration
        // first; anchoring on the release this SDK builds against just gives it a stable place
        // in the graph.
        V_0_22_0_RC6.iter().copied().collect()
    }

    fn description(&self) -> &'static str {
        "Adds the SDK's immediate-run record for Orchard -> Ironwood pool migrations."
    }
}

impl RusqliteMigration for AddImmediateRunsTable {
    type Error = WalletMigrationError;

    fn up(&self, transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        transaction.execute_batch(&format!(
            "CREATE TABLE {IMMEDIATE_RUNS_TABLE} (
                account_uuid BLOB NOT NULL PRIMARY KEY,
                txid BLOB NOT NULL,
                recorded_at_height INTEGER NOT NULL
            )"
        ))?;
        let legacy_exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
            [LEGACY_IMMEDIATE_RUNS_TABLE],
            |row| row.get(0),
        )?;
        if legacy_exists {
            transaction.execute_batch(&format!(
                "INSERT INTO {IMMEDIATE_RUNS_TABLE} (account_uuid, txid, recorded_at_height)
                 SELECT account_uuid, txid, recorded_at_height FROM {LEGACY_IMMEDIATE_RUNS_TABLE};
                 DROP TABLE {LEGACY_IMMEDIATE_RUNS_TABLE};"
            ))?;
        }
        Ok(())
    }

    fn down(&self, _transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        Err(WalletMigrationError::CannotRevert(
            ADD_IMMEDIATE_RUNS_TABLE_ID,
        ))
    }
}

const DROP_RETIRED_INVALID_MARKS_TABLE_ID: Uuid =
    Uuid::from_u128(0x7c41c0f2_dd7f_4d37_b025_457796984d4e);

/// The table the retired `AddInvalidTransferMarksTable` migration created (see the
/// `# Retired migrations` note on [`external_migrations`]).
const RETIRED_INVALID_MARKS_TABLE: &str = "ext_zcashlc_orchard_ironwood_migration_invalid_marks";

/// Drops [`RETIRED_INVALID_MARKS_TABLE`] wherever an earlier build left it behind.
///
/// Its rows recorded node rejections of pool-migration transfers from before the engine had
/// failure states. Earlier SDK versions replayed them into the engine state on the first
/// read-write migration call and then dropped the table, so it survives only in a wallet that has
/// made no such call since; those marks are discarded here, and the engine adjudicates the
/// affected transfers afresh on their next broadcast attempt.
struct DropRetiredInvalidMarksTable;

impl schemerz::Migration<Uuid> for DropRetiredInvalidMarksTable {
    fn id(&self) -> Uuid {
        DROP_RETIRED_INVALID_MARKS_TABLE_ID
    }

    fn dependencies(&self) -> HashSet<Uuid> {
        // Like the table it removes, this touches no wallet schema; anchoring on the release
        // this SDK builds against just gives it a stable place in the graph.
        V_0_22_0_RC6.iter().copied().collect()
    }

    fn description(&self) -> &'static str {
        "Drops the SDK's retired invalid-transfer marks table."
    }
}

impl RusqliteMigration for DropRetiredInvalidMarksTable {
    type Error = WalletMigrationError;

    fn up(&self, transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        transaction.execute_batch(&format!(
            "DROP TABLE IF EXISTS {RETIRED_INVALID_MARKS_TABLE}"
        ))?;
        Ok(())
    }

    fn down(&self, _transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        Err(WalletMigrationError::CannotRevert(
            DROP_RETIRED_INVALID_MARKS_TABLE_ID,
        ))
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use zcash_client_sqlite::WalletDb;
    use zcash_client_sqlite::util::SystemClock;
    use zcash_client_sqlite::wallet::init::init_wallet_db;
    use zcash_protocol::consensus::MAIN_NETWORK;

    use super::IMMEDIATE_RUNS_TABLE;

    fn table_exists(conn: &Connection, name: &str) -> bool {
        conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
            [name],
            |row| row.get(0),
        )
        .expect("the existence probe succeeds")
    }

    /// The SDK's own initialization of the wallet database: `zcash_client_sqlite`'s schema plus
    /// the external migrations registered in this module, exactly as the platform runs it.
    fn init_data_db(path: &std::path::Path) {
        let path_bytes = path.to_str().expect("the temp path is UTF-8").as_bytes();
        let init = unsafe {
            crate::zcashlc_init_data_database(
                path_bytes.as_ptr(),
                path_bytes.len(),
                std::ptr::null(),
                0,
                crate::NETWORK_ID_MAINNET,
            )
        };
        assert!(init >= 0, "wallet-db initialization must succeed");
    }

    /// A wallet database holding `zcash_client_sqlite`'s schema and none of the SDK's tables:
    /// what an earlier SDK version left behind before any of these migrations existed.
    fn wallet_without_sdk_tables(path: &std::path::Path) {
        let mut db = WalletDb::for_path(path, MAIN_NETWORK, SystemClock, rand::rngs::OsRng)
            .expect("the wallet database opens");
        init_wallet_db(&mut db, None).expect("the wallet schema initializes");
    }

    #[test]
    fn init_creates_the_immediate_runs_table() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("wallet.db");
        init_data_db(&path);

        let conn = Connection::open(&path).expect("the database reopens");
        assert!(table_exists(&conn, IMMEDIATE_RUNS_TABLE));
        assert!(!table_exists(&conn, "sdk_immediate_runs"));
    }

    /// A wallet upgraded from an SDK that kept the record in `sdk_immediate_runs` keeps it: the
    /// row moves to the extension table and the old table is gone.
    #[test]
    fn init_carries_legacy_immediate_runs_over_and_drops_the_old_table() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("wallet.db");
        wallet_without_sdk_tables(&path);
        {
            let conn = Connection::open(&path).expect("the fixture connection opens");
            conn.execute_batch(
                "CREATE TABLE sdk_immediate_runs (
                    account_uuid BLOB NOT NULL PRIMARY KEY,
                    txid BLOB NOT NULL,
                    recorded_at_height INTEGER NOT NULL
                )",
            )
            .expect("the legacy table creates");
            conn.execute(
                "INSERT INTO sdk_immediate_runs (account_uuid, txid, recorded_at_height)
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![&[9u8; 16][..], &[1u8; 32][..], 3_600_000u32],
            )
            .expect("the legacy record inserts");
        }

        init_data_db(&path);

        let conn = Connection::open(&path).expect("the database reopens");
        assert!(!table_exists(&conn, "sdk_immediate_runs"));
        let (txid, height): (Vec<u8>, u32) = conn
            .query_row(
                &format!(
                    "SELECT txid, recorded_at_height FROM {IMMEDIATE_RUNS_TABLE}
                     WHERE account_uuid = ?1"
                ),
                [&[9u8; 16][..]],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("the record was carried over");
        assert_eq!(txid, vec![1u8; 32]);
        assert_eq!(height, 3_600_000);
    }

    /// Initializing an already-initialized wallet (which the platform does at every start) runs
    /// no migration twice, so the record survives.
    #[test]
    fn reinitializing_keeps_the_immediate_run_record() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("wallet.db");
        init_data_db(&path);
        {
            let conn = Connection::open(&path).expect("the fixture connection opens");
            conn.execute(
                &format!(
                    "INSERT INTO {IMMEDIATE_RUNS_TABLE} (account_uuid, txid, recorded_at_height)
                     VALUES (?1, ?2, ?3)"
                ),
                rusqlite::params![&[9u8; 16][..], &[1u8; 32][..], 3_600_000u32],
            )
            .expect("the record inserts");
        }

        init_data_db(&path);

        let conn = Connection::open(&path).expect("the database reopens");
        let count: u32 = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM {IMMEDIATE_RUNS_TABLE}"),
                [],
                |row| row.get(0),
            )
            .expect("the record counts");
        assert_eq!(count, 1);
    }

    /// A wallet an earlier build left holding the retired invalid-marks table loses it, rows and
    /// all, at its next initialization.
    #[test]
    fn init_drops_the_retired_invalid_marks_table() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("wallet.db");
        wallet_without_sdk_tables(&path);
        {
            let conn = Connection::open(&path).expect("the fixture connection opens");
            conn.execute_batch(
                "CREATE TABLE ext_zcashlc_orchard_ironwood_migration_invalid_marks (
                    account_uuid BLOB NOT NULL,
                    tx_id INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    PRIMARY KEY (account_uuid, tx_id)
                )",
            )
            .expect("the retired table creates");
            conn.execute(
                "INSERT INTO ext_zcashlc_orchard_ironwood_migration_invalid_marks
                    (account_uuid, tx_id, reason)
                 VALUES (?1, 3, 'invalid_note')",
                [&[9u8; 16][..]],
            )
            .expect("the retired mark inserts");
        }

        init_data_db(&path);

        let conn = Connection::open(&path).expect("the database reopens");
        assert!(!table_exists(
            &conn,
            "ext_zcashlc_orchard_ironwood_migration_invalid_marks"
        ));
    }
}
