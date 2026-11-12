# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0] - 2026-11-12

First public release, tested on the Microsoft MDS sample models (Product, Customer and Chart of Accounts).

### Added

- **Step 1, Create tables and copy data.** One table per MDS entity with the MDS member ID kept as an identity
  primary key, Code as a unique key and the same data types as in MDS. Copies the active members of the latest
  version of each model.
  - Naming: `dbo.Model_Entity` or one schema per model, with options for spaces in names.
  - Optional change tracking columns (created/modified on/by) filled with the history from MDS, stored as
    `datetimeoffset`, compatible with SQL Spreads Change Tracking.
  - Optional MUID column for systems that identify members by GUID.
  - Mapping tables in the schema `migration` that document the migration and are used by the later steps.
  - Protection of existing tables: stops without changes unless `@OverwriteExistingTables = 1`.
- **Step 2, Create lookups.** Foreign keys and indexes for all domain-based attributes, with a report of lookups
  that point to members that were not copied, and a choice of how to handle them.
- **Step 3, Create subscription views.** Recreates leaf attribute views and derived hierarchy views (levels and
  parent-child) with the same names, columns and data types as in MDS, and compares row counts with MDS.
- Dry-run mode in every script: prints the SQL it would run, as a script you can review or run, and changes
  nothing.

### Not included yet

- Explicit hierarchies, collections, file attributes and the MDS transaction history.
- History and SCD type 2 subscription views, recursive derived hierarchy views.
- Business rules (planned for a later version).
- Security (MDS users, groups and permissions).

[1.0]: https://github.com/obnex/mds-to-sql-server-migration/releases/tag/v1.0
