# MDS to SQL Server migration: free scripts for Microsoft Master Data Services

> **This is the first release**, tested on the Microsoft MDS sample models (Product, Customer and Chart of Accounts).
> Business rules are next. The scripts only read from your MDS database and never change it, so you can try them on
> your own data right away. Tell us how it goes, or ask for help with your migration:
> [open an issue](https://github.com/obnex/mds-to-sql-server-migration/issues) or
> [contact us](mailto:support@sqlspreads.com).

Microsoft removed Master Data Services (MDS) from SQL Server 2025. These T-SQL scripts move your MDS models into ordinary SQL Server tables: they create the tables, copy the data, rebuild the relationships and recreate your subscription views.

They are written by the team behind [SQL Spreads](https://sqlspreads.com/?utm_source=github&utm_medium=referral&utm_campaign=mds-to-sql-server-migration), and are free to use and change. For the full migration process, see our guide: [How to migrate from Microsoft MDS, step by step](BLOG-LINK).

## What the scripts do

| Step | Script | What it does |
| --- | --- | --- |
| 1 | `MDS_to_SQL_Step1_CreateTablesAndCopyData.sql` | Creates the target database, one table per MDS entity, and copies the active members of the latest version of each model. Keeps the MDS IDs, so all references stay valid. |
| 2 | `MDS_to_SQL_Step2_CreateLookups.sql` | Turns every domain-based attribute into a foreign key with an index, and reports lookups that point to members that were not copied. |
| 3 | `MDS_to_SQL_Step3_CreateSubscriptionViews.sql` | Recreates your MDS subscription views in the new database, with the same names, columns and data types, so downstream systems only need a new connection. |

The scripts read the MDS metadata and work on any MDS database. Nothing is hard-coded for a particular model.

## What you get

For each MDS entity, a table like this (simplified example):

```sql
CREATE TABLE [dbo].[ChartOfAccounts] (
    [ID] int IDENTITY(1,1) NOT NULL PRIMARY KEY,            -- the MDS member ID, kept
    [Code] nvarchar(250) NOT NULL UNIQUE,                   -- the MDS Code
    [Name] nvarchar(250) NULL,
    [AccountTypeID] int NULL,                               -- lookup, foreign key added in step 2
    [Balance] decimal(38,2) NULL,                           -- same data type as in MDS
    [CreatedOn] datetimeoffset(3) NULL,                     -- change tracking, filled from the MDS history
    [CreatedBy] nvarchar(128) NULL,
    [ModifiedOn] datetimeoffset(3) NULL,
    [ModifiedBy] nvarchar(128) NULL
);
```

- **`ID`** is an identity primary key holding the original MDS member ID. Lookups between tables stay valid without any conversion, and new rows get the next ID.
- **`Code`** stays the unique business key. It is text, as it always is in MDS.
- **Lookups** (domain-based attributes) become `<Attribute>ID` columns with foreign keys.
- **Change tracking columns** (optional, names configurable) are filled with who created and last changed each member in MDS. Times are stored as `datetimeoffset`, so times from MDS (UTC) and from users in different time zones never get mixed up. The columns work with SQL Spreads Change Tracking.
- **`MUID`** (optional) keeps the MDS GUID for systems that identify members by it.
- **Naming:** `dbo.Model_Entity` by default, or one schema per model (`Model.Entity`).

Step 1 also writes its settings and the full mapping (MDS entity to table, MDS attribute to column) to the schema `migration` in the new database. The later steps read it from there, and it documents the migration afterwards.

## Requirements

- The MDS database on a SQL Server instance you can query. The MDS web application does not need to run: a restored backup of the MDS database is enough.
- The target database is created on the same instance.
- Permission to create a database, or an existing empty database you own.
- Tested with: the Microsoft MDS sample models in an MDS database on SQL Server 2025.

## Quick start

1. **Back up your MDS database.** The scripts only read from MDS, but a backup is always the first step.
2. Open `MDS_to_SQL_Step1_CreateTablesAndCopyData.sql` in SSMS and set the values in **Section 1: Settings**: at least `@SourceDb` (your MDS database) and `@TargetDb` (the new database).
3. Run it with `@DryRun = 1` first. It prints the SQL it would run, as a script you can review or run yourself, and changes nothing.
4. Run it with `@DryRun = 0`.
5. Run steps 2 and 3 in order. Each needs only `@TargetDb`; the rest is read from the mapping written by step 1.

Every script ends with a report of what was created and anything it could not handle. Step 3 also compares the row counts of the new views with MDS.

## Step by step

### Step 1: Create tables and copy data

Main settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `@OverwriteExistingTables` | `0` | `0`: stop without changing anything if a table already exists. `1`: drop and recreate existing tables, e.g. when running the migration again. |
| `@NamingMode` | `Prefix` | `Prefix`: `dbo.Model_Entity`. `SchemaPerModel`: `Model.Entity`. |
| `@SpaceHandling` | `Remove` | Spaces in model and entity names: `Keep`, `Remove` or `Underscore`. |
| `@IncludeMuid` | `0` | Keep the MDS MUID column. |
| `@AddChangeTracking` | `1` | Add created/modified on/by columns. |
| `@ChangeTrackingFromMds` | `1` | Fill them with the MDS history (or with the migration time and current user). |

Before anything is created, the script checks for name collisions, names longer than 128 characters and columns that would clash, and stops with a clear message.

**Existing tables are protected.** If the target database already has a table with the same name as one the script creates, the script stops without changing anything. To run the migration again and replace them, set `@OverwriteExistingTables = 1`. The script never drops a database.

### Step 2: Create lookups

Creates an index and a foreign key for every lookup column. A lookup value that points to a member that was not copied (usually a deactivated member) is an **orphan**. `@OrphanHandling` decides what happens:

- `Skip` (default): no foreign key for that column; the data is left as it is and listed in the report with a query to inspect it.
- `SetNull`: the orphaned values are set to NULL, then the key is created.
- `NoCheck`: the key is created `WITH NOCHECK`, so only new and changed values are checked.

Derived hierarchies, recursive hierarchies and many-to-many mapping entities are covered automatically, since they are all lookups.

### Step 3: Create subscription views

Recreates your MDS subscription views in the schema `mdm` of the new database, with the same names, columns and data types:

| Format | Created |
| --- | --- |
| Leaf attributes | Yes |
| Derived hierarchy, levels | Yes |
| Derived hierarchy, parent-child | Yes |
| History, SCD type 2 | No: they need the MDS change history, which is not migrated |
| Explicit hierarchies, collections, consolidated members | No (planned) |

Columns that have no meaning outside MDS get fixed values: `ValidationStatus` is `Validation Succeeded`, `State` is `Active`, and the version columns keep the values of the migrated version.

After creating the views, the script compares the row count of every new view with the MDS view. To compare the content value by value:

```sql
SELECT 'only in MDS' AS Diff, * FROM (
    SELECT * FROM MDS.mdm.[Product members] EXCEPT SELECT * FROM MasterData.mdm.[Product members]) AS a
UNION ALL
SELECT 'only in new', * FROM (
    SELECT * FROM MasterData.mdm.[Product members] EXCEPT SELECT * FROM MDS.mdm.[Product members]) AS b;
```

No rows means the views are identical.

## Re-running

All scripts can be run again. Each drops and recreates only its own objects. To run step 1 again over tables it created earlier, set `@OverwriteExistingTables = 1`. After re-running a step, run the later steps again too: step 1 drops the foreign keys that step 2 created, and so on.

## Known limitations

- Only the latest version of each model is migrated, and only active members.
- Explicit hierarchies, collections, file attributes and the MDS transaction history are not migrated.
- Recursive derived hierarchies and hierarchies with a many-to-many level are not recreated as subscription views.
- Business rules are not migrated yet; a script for them is planned. Until then, see our guide for how to convert them
  to SQL Server constraints. Note that MDS saves data that breaks a rule and marks it as invalid, while a SQL Server
  constraint rejects it, so expect existing rows that break your rules.
- Security (MDS users, groups and permissions) is not migrated.

Found a case the scripts do not handle? Please [open an issue](https://github.com/obnex/mds-to-sql-server-migration/issues).

## Getting help

- **Questions and bugs:** [open an issue](https://github.com/obnex/mds-to-sql-server-migration/issues). Include the report printed at the end of the script, and your MDS and SQL Server versions.
- **Help with your migration:** [contact us](mailto:support@sqlspreads.com).

## Disclaimer

The scripts only read from the MDS database; they never change it. They write to the target database: step 1 stops if tables with the same names already exist there, but with `@OverwriteExistingTables = 1` it drops and recreates them, so use a new database as the target. On a large MDS database, run them outside office hours or against a restored backup, since copying the data reads every entity table. The scripts are provided as is, without warranty of any kind. See [LICENSE](LICENSE).

## License

MIT. Copyright (c) 2026 Obnex Technologies AB. See [LICENSE](LICENSE).

## About SQL Spreads

[SQL Spreads](https://sqlspreads.com/?utm_source=github&utm_medium=referral&utm_campaign=mds-to-sql-server-migration) is an Excel add-in that lets business users view and edit SQL Server tables directly in Excel, with lookups, change tracking and validation. It is a straightforward replacement for the MDS Excel add-in on top of the tables these scripts create.
