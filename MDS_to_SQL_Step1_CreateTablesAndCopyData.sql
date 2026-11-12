/* ==================================================================================================================
   MDS to SQL migration, step 1: create tables and copy data
   Version: 1.0 (https://github.com/obnex/mds-to-sql-server-migration)
   Steps:   1 CreateTablesAndCopyData, 2 CreateLookups, 3 CreateSubscriptionViews
   ------------------------------------------------------------------------------------------------------------------
   What the script does:
   - Reads model, entity and attribute metadata from the MDS database.
   - Works out target schema and table names (see @NamingMode) and checks that no names collide.
   - Creates the target database and schema(s) if they do not exist.
   - Creates one table per entity and copies active leaf members from the latest version of each model.
   - Every table gets an ID column (int IDENTITY, primary key) and a unique constraint on Code. The ID values are
     kept from MDS, so lookups between tables stay valid without any conversion. New rows get the next ID.
   - Optionally keeps the MDS MUID (a GUID per member) for downstream systems that use it as their key.
   - Domain-based attributes (lookups) are named <Attribute>ID, e.g. AccountTypeID, and hold the ID of the
     referenced row. Foreign keys are added in step 2.
   - Column data types are read from the MDS tables, so text lengths and decimals stay the same.
   - Writes the settings and the naming to mapping tables in the schema "migration" in the target database, so later
     steps use exactly the same names. Drops foreign keys pointing to the re-created tables, so it can be re-run.
   - Optionally adds change tracking columns (created/modified on/by), filled with the history from MDS,
     with defaults for new rows.

   How to use:
   - Adjust the settings in section 1.
   - Set @DryRun = 1 to only print the generated SQL without running it. The output is a formatted, runnable script
     with GO between the blocks, so you can copy it to a new query window and run all of it or one table at a time.
   - The script can be run from any database on the instance.
   - The script never drops a database. If the target database already has tables with the same names as the tables
     it creates, it stops without changing anything, unless @OverwriteExistingTables = 1.
   - The MDS database is only read, never changed.
   ================================================================================================================== */

-- Remove temp tables left over from an earlier run in the same session. Must be a separate batch,
-- otherwise SQL Server validates the main script against the old temp table definitions.
IF OBJECT_ID(N'tempdb..#Entities')   IS NOT NULL DROP TABLE #Entities;
IF OBJECT_ID(N'tempdb..#Attributes') IS NOT NULL DROP TABLE #Attributes;
IF OBJECT_ID(N'tempdb..#Columns')    IS NOT NULL DROP TABLE #Columns;
GO

SET NOCOUNT ON;

/* ==================================================================================================================
   SECTION 1: SETTINGS
   ------------------------------------------------------------------------------------------------------------------
   These are the only values you normally need to change.

   @NamingMode
     'Prefix'         All tables in @TargetSchema, named Model_Entity. If the entity has the same name as the model,
                      the table is named after the entity only.
                      Example: dbo.ChartOfAccounts, dbo.ChartOfAccounts_AccountType
     'SchemaPerModel' One schema per model, tables named after the entity. @TargetSchema is ignored.
                      Example: ChartOfAccounts.ChartOfAccounts, ChartOfAccounts.AccountType

   @SpaceHandling  (applies to schema and table names)
     'Keep'           Keep spaces:        [Chart of Accounts]
     'Remove'         Remove spaces:      [ChartofAccounts]
     'Underscore'     Replace with _:     [Chart_of_Accounts]

   @OverwriteExistingTables
     0                Default. Stop without changing anything if any of the tables already exists in the target
                      database. Protects existing data when @TargetDb points to the wrong database.
     1                Drop and recreate the tables that already exist, e.g. when running the migration again. Their
                      data is replaced, and foreign keys from other tables that point to them are dropped.

   Keys
     @IdColumn        Name of the identity / primary key column in every table.
     @LookupSuffix    Added to the name of lookup columns: AccountType + ID = AccountTypeID.
     @IncludeMuid     1 = keep the MDS MUID (uniqueidentifier) in a column named @MuidColumn. Use this if downstream
                      systems identify members by MUID. The column is NOT NULL and unique, and new rows get NEWID().

   Change tracking (used by SQL Spreads)
     @AddChangeTracking      1 = add created/modified on/by columns.
     @ChangeTrackingFromMds  1 = fill them with the history from MDS (when and by whom each member was created and
                             last changed). 0 = fill them with the time of the migration and the current user.
     Column names can be changed to match your conventions.
     Data types: datetimeoffset(3) for times, nvarchar(128) for users. datetimeoffset stores the exact moment
     including the UTC offset. SQL Spreads writes the Excel user's local time plus the PC's offset, and the MDS
     history is written as UTC (+00:00), so times from users in different time zones and from MDS never get mixed up.
     The columns allow NULL and get defaults for new rows (SYSDATETIMEOFFSET() and SUSER_SNAME()).
   ================================================================================================================== */

-- General
DECLARE @SourceDb      sysname      = N'MDS';         -- name of the MDS database
DECLARE @TargetDb      sysname      = N'MasterData';  -- target database (created if missing)
DECLARE @TargetSchema  sysname      = N'dbo';         -- target schema, used in 'Prefix' mode
DECLARE @NamingMode    nvarchar(20) = N'Prefix';      -- 'Prefix' or 'SchemaPerModel'
DECLARE @SpaceHandling nvarchar(20) = N'Remove';      -- 'Keep', 'Remove' or 'Underscore'
DECLARE @DryRun        bit          = 0;              -- 0 = execute, 1 = only print SQL
DECLARE @OverwriteExistingTables bit = 0;             -- 1 = drop and recreate tables that already exist

-- Keys
DECLARE @IdColumn      sysname      = N'ID';          -- identity / primary key column
DECLARE @LookupSuffix  sysname      = N'ID';          -- suffix for lookup columns
DECLARE @IncludeMuid   bit          = 0;              -- 1 = keep the MDS MUID column
DECLARE @MuidColumn    sysname      = N'MUID';        -- name of the MUID column

-- Change tracking
DECLARE @AddChangeTracking      bit     = 1;
DECLARE @ChangeTrackingFromMds  bit     = 1;
DECLARE @CreatedOnColumn        sysname = N'CreatedOn';
DECLARE @CreatedByColumn        sysname = N'CreatedBy';
DECLARE @ModifiedOnColumn       sysname = N'ModifiedOn';
DECLARE @ModifiedByColumn       sysname = N'ModifiedBy';


/* ==================================================================================================================
   Internal variables (do not change)
   ================================================================================================================== */
DECLARE @NL           nchar(2)      = CHAR(13) + CHAR(10),   -- line break in generated SQL
        @Src          nvarchar(260) = QUOTENAME(@SourceDb),
        @Proc         nvarchar(400) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql',  -- runs SQL in the target db
        @Sql          nvarchar(max),
        @Inner        nvarchar(max),
        @DropSql      nvarchar(max),          -- drop of one target table, run as its own batch
        @Output       nvarchar(max) = N'',   -- generated SQL collected in dry-run mode
        @Pos          int,
        @Next         int,
        @Len          int,
        @NowExpr      nvarchar(100) = N'CAST(SYSDATETIMEOFFSET() AS datetimeoffset(3))',
        @ColDefs      nvarchar(max),          -- attribute column definitions for CREATE TABLE
        @InsCols      nvarchar(max),          -- attribute column names for INSERT
        @SelCols      nvarchar(max),          -- attribute source columns for SELECT
        @CtDefs       nvarchar(max) = N'',    -- change tracking column definitions
        @CtInsCols    nvarchar(max) = N'',    -- change tracking column names for INSERT
        @CtSelCols    nvarchar(max) = N'',    -- change tracking values for SELECT
        @CtJoins      nvarchar(max) = N'',    -- joins to mdm.tblUser
        @IdType       nvarchar(200),
        @MuidType     nvarchar(200),
        @MuidDef      nvarchar(max),          -- MUID column definition (empty if not included)
        @MuidIns      nvarchar(max),          -- MUID column name for INSERT
        @MuidSel      nvarchar(max),          -- MUID source column for SELECT
        @CodeType     nvarchar(200),
        @NameType     nvarchar(200),
        @FullTarget   nvarchar(600),
        @EntityId     int,
        @ModelName    nvarchar(128),
        @EntityName   nvarchar(128),
        @EntityTable  nvarchar(128),
        @VersionId    int,
        @SchemaName   nvarchar(300),
        @TableName    nvarchar(300),
        @EntityCount  int,
        @ErrorList    nvarchar(max),
        @Rows         nvarchar(max),          -- VALUES rows for the mapping tables
        @Tdb          nvarchar(260) = QUOTENAME(@TargetDb),                            -- [MasterData]
        @TdbLit       nvarchar(520) = REPLACE(QUOTENAME(@TargetDb), N'''', N''''''),    -- the same, inside N'...'
        @DbIdExpr     nvarchar(600) = N'DB_ID(N''' + REPLACE(@TargetDb, N'''', N'''''') + N''')';


/* ==================================================================================================================
   SECTION 2: VALIDATE SETTINGS
   ================================================================================================================== */
IF DB_ID(@SourceDb) IS NULL
BEGIN
    RAISERROR(N'Source database %s does not exist.', 16, 1, @SourceDb);
    RETURN;
END;

IF @NamingMode NOT IN (N'Prefix', N'SchemaPerModel')
BEGIN
    RAISERROR(N'Invalid @NamingMode: %s. Use ''Prefix'' or ''SchemaPerModel''.', 16, 1, @NamingMode);
    RETURN;
END;

IF @SpaceHandling NOT IN (N'Keep', N'Remove', N'Underscore')
BEGIN
    RAISERROR(N'Invalid @SpaceHandling: %s. Use ''Keep'', ''Remove'' or ''Underscore''.', 16, 1, @SpaceHandling);
    RETURN;
END;


/* ==================================================================================================================
   SECTION 3: READ MDS METADATA AND WORK OUT TARGET NAMES
   ------------------------------------------------------------------------------------------------------------------
   Loads entities (with the latest model version), user-defined leaf attributes and the data types of the MDS entity
   tables into temp tables, then computes the target schema, table and column names. The names are stored in the
   temp tables so later scripts (e.g. step 2) can use exactly the same naming logic.
   ================================================================================================================== */
CREATE TABLE #Entities (
    EntityId     int           NOT NULL PRIMARY KEY,
    ModelName    nvarchar(128) NOT NULL,
    EntityName   nvarchar(128) NOT NULL,
    EntityTable  nvarchar(128) NOT NULL,
    VersionId    int           NOT NULL,
    TargetSchema nvarchar(300) NULL,
    TargetTable  nvarchar(300) NULL
);

CREATE TABLE #Attributes (
    EntityId        int           NOT NULL,
    AttributeName   nvarchar(128) NOT NULL,
    TableColumn     nvarchar(128) NOT NULL,
    AttributeTypeId int           NOT NULL,   -- 1 = free-form, 2 = domain-based (lookup), 4 = file
    DomainEntityId  int           NULL,       -- for lookups: the entity the attribute points to
    SortOrder       int           NULL,
    TargetColumn    nvarchar(300) NULL
);

CREATE TABLE #Columns (
    TableName  nvarchar(128) NOT NULL,
    ColumnName nvarchar(128) NOT NULL,
    TypeDef    nvarchar(200) NOT NULL,       -- e.g. nvarchar(250), decimal(38,2)
    PRIMARY KEY (TableName, ColumnName)
);

-- 3a. Entities and the latest version of their model
SET @Sql = N'
SELECT e.ID, m.Name, e.Name, e.EntityTable, v.ID, NULL, NULL
FROM ' + @Src + N'.mdm.tblModel  AS m
JOIN ' + @Src + N'.mdm.tblEntity AS e ON e.Model_ID = m.ID
CROSS APPLY (SELECT TOP (1) mv.ID
             FROM ' + @Src + N'.mdm.tblModelVersion AS mv
             WHERE mv.Model_ID = m.ID
             ORDER BY mv.ID DESC) AS v
WHERE e.EntityTable IS NOT NULL;';
INSERT INTO #Entities EXEC sys.sp_executesql @Sql;

-- 3b. User-defined leaf attributes (system columns, Code and Name excluded)
SET @Sql = N'
SELECT a.Entity_ID, a.Name, a.TableColumn, a.AttributeType_ID, a.DomainEntity_ID, a.SortOrder, NULL
FROM ' + @Src + N'.mdm.tblAttribute AS a
WHERE a.MemberType_ID = 1
  AND a.IsSystem      = 0
  AND a.TableColumn NOT IN (N''Code'', N''Name'');';
INSERT INTO #Attributes EXEC sys.sp_executesql @Sql;

-- 3c. Data types of all columns in the MDS entity tables
SET @Sql = N'
SELECT tb.name, c.name,
       CASE
           WHEN ty.name IN (N''nvarchar'', N''nchar'')
               THEN ty.name + N''('' + CASE WHEN c.max_length = -1 THEN N''max''
                                            ELSE CAST(c.max_length / 2 AS nvarchar(10)) END + N'')''
           WHEN ty.name IN (N''varchar'', N''char'', N''varbinary'', N''binary'')
               THEN ty.name + N''('' + CASE WHEN c.max_length = -1 THEN N''max''
                                            ELSE CAST(c.max_length AS nvarchar(10)) END + N'')''
           WHEN ty.name IN (N''decimal'', N''numeric'')
               THEN ty.name + N''('' + CAST(c.precision AS nvarchar(10)) + N'',''
                            + CAST(c.scale AS nvarchar(10)) + N'')''
           WHEN ty.name IN (N''datetime2'', N''time'', N''datetimeoffset'')
               THEN ty.name + N''('' + CAST(c.scale AS nvarchar(10)) + N'')''
           ELSE ty.name
       END
FROM ' + @Src + N'.sys.tables  AS tb
JOIN ' + @Src + N'.sys.schemas AS s  ON s.schema_id = tb.schema_id AND s.name = N''mdm''
JOIN ' + @Src + N'.sys.columns AS c  ON c.object_id = tb.object_id
JOIN ' + @Src + N'.sys.types   AS ty ON ty.user_type_id = c.system_type_id
WHERE tb.name LIKE N''tbl[_]%[_]EN'';';
INSERT INTO #Columns EXEC sys.sp_executesql @Sql;

-- 3d. Work out target schema and table names
UPDATE e
SET TargetSchema = CASE @NamingMode
                       WHEN N'SchemaPerModel' THEN n.CleanModel
                       ELSE @TargetSchema
                   END,
    TargetTable  = CASE
                       WHEN @NamingMode = N'SchemaPerModel' THEN n.CleanEntity
                       WHEN n.CleanEntity = n.CleanModel    THEN n.CleanEntity
                       ELSE n.CleanModel + N'_' + n.CleanEntity
                   END
FROM #Entities AS e
CROSS APPLY (SELECT CleanModel  = CASE @SpaceHandling
                                      WHEN N'Remove'     THEN REPLACE(e.ModelName, N' ', N'')
                                      WHEN N'Underscore' THEN REPLACE(e.ModelName, N' ', N'_')
                                      ELSE e.ModelName
                                  END,
                    CleanEntity = CASE @SpaceHandling
                                      WHEN N'Remove'     THEN REPLACE(e.EntityName, N' ', N'')
                                      WHEN N'Underscore' THEN REPLACE(e.EntityName, N' ', N'_')
                                      ELSE e.EntityName
                                  END) AS n;

-- 3e. Work out target column names (lookups get @LookupSuffix)
UPDATE #Attributes
SET TargetColumn = AttributeName + CASE WHEN AttributeTypeId = 2 THEN @LookupSuffix ELSE N'' END;

-- 3f. Check for duplicate target table names
SET @ErrorList = (
    SELECT @NL + N'  ' + TargetSchema + N'.' + TargetTable
    FROM #Entities
    GROUP BY TargetSchema, TargetTable
    HAVING COUNT(*) > 1
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Duplicate target names:' + @ErrorList;
    RAISERROR(N'Two or more entities map to the same target name. Change @NamingMode or @SpaceHandling.', 16, 1);
    RETURN;
END;

-- 3g. Check that no name is longer than SQL Server allows (128 characters)
SET @ErrorList = (
    SELECT @NL + N'  ' + TargetSchema + N'.' + TargetTable
    FROM #Entities
    WHERE LEN(TargetSchema) > 128 OR LEN(TargetTable) > 128
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Names longer than 128 characters:' + @ErrorList;
    RAISERROR(N'One or more target names are too long. Try @NamingMode = ''SchemaPerModel''.', 16, 1);
    RETURN;
END;

-- 3h. Check that no entity table collides with the mapping tables in the schema "migration"
SET @ErrorList = (
    SELECT @NL + N'  ' + ModelName + N' / ' + EntityName + N' -> ' + TargetSchema + N'.' + TargetTable
    FROM #Entities
    WHERE TargetSchema = N'migration' AND TargetTable IN (N'Settings', N'Entities', N'Attributes')
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Tables that collide with the mapping tables:' + @ErrorList;
    RAISERROR(N'Use @NamingMode = ''Prefix'' or rename the model "migration" in MDS.', 16, 1);
    RETURN;
END;

-- 3i. Check that no column name collides with another column in the same table
SET @ErrorList = (
    SELECT @NL + N'  ' + e.ModelName + N' / ' + e.EntityName + N': ' + a.TargetColumn
    FROM #Attributes AS a
    JOIN #Entities   AS e ON e.EntityId = a.EntityId
    WHERE a.TargetColumn IN (@IdColumn, N'Code', N'Name')
       OR (@IncludeMuid = 1 AND a.TargetColumn = @MuidColumn)
       OR (@AddChangeTracking = 1
           AND a.TargetColumn IN (@CreatedOnColumn, @CreatedByColumn, @ModifiedOnColumn, @ModifiedByColumn))
       OR EXISTS (SELECT 1 FROM #Attributes AS a2
                  WHERE a2.EntityId = a.EntityId
                    AND a2.TargetColumn = a.TargetColumn
                    AND a2.TableColumn <> a.TableColumn)
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Column names that collide:' + @ErrorList;
    RAISERROR(N'Change @IdColumn, @LookupSuffix, @MuidColumn or the change tracking column names in section 1.', 16, 1);
    RETURN;
END;

-- 3j. Check that the data type was found for every column that is copied
SET @ErrorList = (
    SELECT @NL + N'  ' + e.ModelName + N' / ' + e.EntityName + N': ' + k.ColumnName
    FROM #Entities AS e
    CROSS APPLY (SELECT N'ID' UNION ALL SELECT N'Code' UNION ALL SELECT N'Name'
                 UNION ALL SELECT N'MUID' WHERE @IncludeMuid = 1
                 UNION ALL SELECT a.TableColumn FROM #Attributes AS a WHERE a.EntityId = e.EntityId) AS k(ColumnName)
    WHERE NOT EXISTS (SELECT 1 FROM #Columns AS c
                      WHERE c.TableName = e.EntityTable AND c.ColumnName = k.ColumnName)
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Columns not found in the MDS entity tables:' + @ErrorList;
    RAISERROR(N'The MDS metadata does not match the entity tables.', 16, 1);
    RETURN;
END;

-- 3k. Protect existing tables: stop if any target table already exists, unless @OverwriteExistingTables = 1
IF DB_ID(@TargetDb) IS NOT NULL AND @OverwriteExistingTables = 0
BEGIN
    EXEC @Proc N'
SELECT @cnt = COUNT(*)
FROM #Entities AS e
WHERE OBJECT_ID(QUOTENAME(e.TargetSchema) + N''.'' + QUOTENAME(e.TargetTable), N''U'') IS NOT NULL;',
        N'@cnt int OUTPUT', @cnt = @EntityCount OUTPUT;

    IF @EntityCount > 0
    BEGIN
        PRINT N'-- STOPPED: The database ' + QUOTENAME(@TargetDb) + N' already contains data.';
        PRINT N'-- To overwrite the existing tables in ' + QUOTENAME(@TargetDb) + N', set @OverwriteExistingTables = 1'
            + N' in the Settings section in this script, or change @TargetDb to a new database.';
        RAISERROR(N'Tables already exist in %s. See the message above.', 16, 1, @TargetDb);
        RETURN;
    END;
END;

SET @EntityCount = (SELECT COUNT(*) FROM #Entities);
PRINT N'-- Entities found: ' + CAST(@EntityCount AS nvarchar(10)) + @NL;


/* ==================================================================================================================
   SECTION 4: PREPARE CHANGE TRACKING FRAGMENTS
   ------------------------------------------------------------------------------------------------------------------
   Builds the SQL fragments used for every table. The column definitions include defaults for new rows. With
   @ChangeTrackingFromMds = 1 the history is copied from MDS; with 0 the columns are left out of the INSERT so the
   defaults fill them with the time of the migration and the current user.
   MDS stores who created/changed a member as a user ID in EnterUserID / LastChgUserID (names in mdm.tblUser), and
   the times in EnterDTM / LastChgDTM. MDS fills the times with GETUTCDATE(), so they are written with offset +00:00.
   ================================================================================================================== */
IF @AddChangeTracking = 1
BEGIN
    -- 4a. Column definitions (the constraint names are completed per table with {table})
    SET @CtDefs =
          N',' + @NL + N'    ' + QUOTENAME(@CreatedOnColumn) + N' datetimeoffset(3) NULL'
            + N' CONSTRAINT [DF_{table}_' + REPLACE(@CreatedOnColumn, N']', N']]') + N'] DEFAULT (' + @NowExpr + N')'
        + N',' + @NL + N'    ' + QUOTENAME(@CreatedByColumn) + N' nvarchar(128) NULL'
            + N' CONSTRAINT [DF_{table}_' + REPLACE(@CreatedByColumn, N']', N']]') + N'] DEFAULT (SUSER_SNAME())'
        + N',' + @NL + N'    ' + QUOTENAME(@ModifiedOnColumn) + N' datetimeoffset(3) NULL'
            + N' CONSTRAINT [DF_{table}_' + REPLACE(@ModifiedOnColumn, N']', N']]') + N'] DEFAULT (' + @NowExpr + N')'
        + N',' + @NL + N'    ' + QUOTENAME(@ModifiedByColumn) + N' nvarchar(128) NULL'
            + N' CONSTRAINT [DF_{table}_' + REPLACE(@ModifiedByColumn, N']', N']]') + N'] DEFAULT (SUSER_SNAME())';

    -- 4b. Values from the MDS history
    IF @ChangeTrackingFromMds = 1
    BEGIN
        SET @CtInsCols =
              N',' + @NL + N'    ' + QUOTENAME(@CreatedOnColumn)
            + N',' + @NL + N'    ' + QUOTENAME(@CreatedByColumn)
            + N',' + @NL + N'    ' + QUOTENAME(@ModifiedOnColumn)
            + N',' + @NL + N'    ' + QUOTENAME(@ModifiedByColumn);

        SET @CtSelCols =
              N',' + @NL + N'    CAST(TODATETIMEOFFSET(src.EnterDTM, ''+00:00'') AS datetimeoffset(3))'
            + N',' + @NL + N'    CAST(uc.UserName AS nvarchar(128))'
            + N',' + @NL + N'    CAST(TODATETIMEOFFSET(src.LastChgDTM, ''+00:00'') AS datetimeoffset(3))'
            + N',' + @NL + N'    CAST(um.UserName AS nvarchar(128))';

        SET @CtJoins =
              @NL + N'    LEFT JOIN ' + @Src + N'.mdm.tblUser AS uc ON uc.ID = src.EnterUserID'
            + @NL + N'    LEFT JOIN ' + @Src + N'.mdm.tblUser AS um ON um.ID = src.LastChgUserID';
    END;
END;


/* ==================================================================================================================
   SECTION 5: CREATE TARGET DATABASE AND SCHEMAS
   ------------------------------------------------------------------------------------------------------------------
   The database is created with the server's default file locations and settings. One schema is created per
   distinct target schema (one in 'Prefix' mode, one per model in 'SchemaPerModel' mode).
   ================================================================================================================== */

-- 5a. Database
SET @Sql = N'IF DB_ID(N''' + REPLACE(@TargetDb, N'''', N'''''') + N''') IS NULL' + @NL
         + N'    CREATE DATABASE ' + QUOTENAME(@TargetDb) + N';';

IF @DryRun = 1
    SET @Output += @Sql + @NL + N'GO' + @NL + @NL;
ELSE
BEGIN
    EXEC sys.sp_executesql @Sql;
    PRINT N'Database ' + @TargetDb + N' ready.';
END;

-- 5b. Schemas. CREATE SCHEMA must run in the target database and in its own batch, so it is wrapped in
--     the target database's sp_executesql and EXEC().
DECLARE schema_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT TargetSchema FROM #Entities UNION SELECT N'migration' ORDER BY 1;   -- "migration" holds the mapping

OPEN schema_cur;
FETCH NEXT FROM schema_cur INTO @SchemaName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Inner = N'IF SCHEMA_ID(N''' + REPLACE(@SchemaName, N'''', N'''''') + N''') IS NULL'
               + N' EXEC(N''CREATE SCHEMA ' + REPLACE(QUOTENAME(@SchemaName), N'''', N'''''') + N''');';

    SET @Sql = N'EXEC ' + QUOTENAME(@TargetDb) + N'.sys.sp_executesql' + @NL
             + N'    N''' + REPLACE(@Inner, N'''', N'''''') + N''';';

    IF @DryRun = 1
        SET @Output += @Sql + @NL;
    ELSE
        EXEC sys.sp_executesql @Sql;

    FETCH NEXT FROM schema_cur INTO @SchemaName;
END;

CLOSE schema_cur;
DEALLOCATE schema_cur;

IF @DryRun = 1
    SET @Output += N'GO' + @NL + @NL;


/* ==================================================================================================================
   SECTION 6: WRITE MAPPING TABLES AND DROP FOREIGN KEYS
   ------------------------------------------------------------------------------------------------------------------
   Writes the settings and the naming (MDS entity -> table, MDS attribute -> column) to the schema "migration" in the
   target database. Later steps read these tables, so they always use exactly the same names as this run. The tables
   are dropped and re-created on every run. The data is written as literal values, so the dry-run output can be run
   on its own.
   Then drops all foreign keys that point to the tables re-created in section 7, so this step can be re-run after
   step 2. Run step 2 (and the later steps) again afterwards.
   ================================================================================================================== */

-- 6a. Drop and create the mapping tables. The drop is a separate batch, so the INSERTs below are never checked
--     against an older definition of the tables.
SET @DropSql =
      N'-- ' + REPLICATE(N'-', 100) + @NL
    + N'-- Mapping tables used by later steps' + @NL
    + N'-- ' + REPLICATE(N'-', 100) + @NL
    + N'IF OBJECT_ID(N''' + @TdbLit + N'.migration.Settings'')   IS NOT NULL DROP TABLE '
          + @Tdb + N'.migration.Settings;' + @NL
    + N'IF OBJECT_ID(N''' + @TdbLit + N'.migration.Entities'')   IS NOT NULL DROP TABLE '
          + @Tdb + N'.migration.Entities;' + @NL
    + N'IF OBJECT_ID(N''' + @TdbLit + N'.migration.Attributes'') IS NOT NULL DROP TABLE '
          + @Tdb + N'.migration.Attributes;';

SET @Sql =
      N'CREATE TABLE ' + @Tdb + N'.migration.Settings (' + @NL
    + N'    Name  nvarchar(128) NOT NULL PRIMARY KEY,' + @NL
    + N'    Value nvarchar(400) NULL' + @NL
    + N');' + @NL
    + @NL
    + N'CREATE TABLE ' + @Tdb + N'.migration.Entities (' + @NL
    + N'    EntityId     int           NOT NULL PRIMARY KEY,   -- MDS entity ID' + @NL
    + N'    ModelName    nvarchar(128) NOT NULL,' + @NL
    + N'    EntityName   nvarchar(128) NOT NULL,' + @NL
    + N'    EntityTable  nvarchar(128) NOT NULL,               -- MDS table, e.g. tbl_3_32_EN' + @NL
    + N'    VersionId    int           NOT NULL,               -- MDS version that was copied' + @NL
    + N'    TargetSchema nvarchar(128) NOT NULL,' + @NL
    + N'    TargetTable  nvarchar(128) NOT NULL' + @NL
    + N');' + @NL
    + @NL
    + N'CREATE TABLE ' + @Tdb + N'.migration.Attributes (' + @NL
    + N'    EntityId        int           NOT NULL,' + @NL
    + N'    AttributeName   nvarchar(128) NOT NULL,' + @NL
    + N'    TableColumn     nvarchar(128) NOT NULL,            -- MDS column, e.g. uda_33_712' + @NL
    + N'    AttributeTypeId int           NOT NULL,            -- 1 = free-form, 2 = lookup, 4 = file' + @NL
    + N'    DomainEntityId  int           NULL,                -- lookups: the entity the attribute points to' + @NL
    + N'    SortOrder       int           NULL,' + @NL
    + N'    TargetColumn    nvarchar(300) NOT NULL,' + @NL
    + N'    PRIMARY KEY (EntityId, TableColumn)' + @NL
    + N');' + @NL;

-- 6b. Settings rows
SET @Rows = STUFF((
    SELECT N',' + @NL + N'    (N''' + REPLACE(v.Name, N'''', N'''''') + N''', '
         + ISNULL(N'N''' + REPLACE(v.Value, N'''', N'''''') + N'''', N'NULL') + N')'
    FROM (VALUES (N'ScriptVersion',         N'1.0'),
                 (N'RunAt',                 CONVERT(nvarchar(40), SYSDATETIMEOFFSET(), 127)),
                 (N'SourceDb',              @SourceDb),
                 (N'TargetDb',              @TargetDb),
                 (N'NamingMode',            @NamingMode),
                 (N'SpaceHandling',         @SpaceHandling),
                 (N'TargetSchema',          @TargetSchema),
                 (N'IdColumn',              @IdColumn),
                 (N'LookupSuffix',          @LookupSuffix),
                 (N'IncludeMuid',           CAST(@IncludeMuid AS nvarchar(1))),
                 (N'MuidColumn',            @MuidColumn),
                 (N'AddChangeTracking',     CAST(@AddChangeTracking AS nvarchar(1))),
                 (N'ChangeTrackingFromMds', CAST(@ChangeTrackingFromMds AS nvarchar(1))),
                 (N'CreatedOnColumn',       @CreatedOnColumn),
                 (N'CreatedByColumn',       @CreatedByColumn),
                 (N'ModifiedOnColumn',      @ModifiedOnColumn),
                 (N'ModifiedByColumn',      @ModifiedByColumn)) AS v(Name, Value)
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

SET @Sql += @NL
    + N'INSERT INTO ' + @Tdb + N'.migration.Settings (Name, Value)' + @NL
    + N'SELECT Name, Value FROM (VALUES' + @NL + @Rows + @NL
    + N') AS v(Name, Value);' + @NL;

-- 6c. Entity rows
SET @Rows = STUFF((
    SELECT N',' + @NL + N'    (' + CAST(EntityId AS nvarchar(10))
         + N', N''' + REPLACE(ModelName,    N'''', N'''''') + N''''
         + N', N''' + REPLACE(EntityName,   N'''', N'''''') + N''''
         + N', N''' + REPLACE(EntityTable,  N'''', N'''''') + N''''
         + N', '    + CAST(VersionId AS nvarchar(10))
         + N', N''' + REPLACE(TargetSchema, N'''', N'''''') + N''''
         + N', N''' + REPLACE(TargetTable,  N'''', N'''''') + N''')'
    FROM #Entities
    ORDER BY EntityId
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

SET @Sql += @NL
    + N'INSERT INTO ' + @Tdb + N'.migration.Entities' + @NL
    + N'    (EntityId, ModelName, EntityName, EntityTable, VersionId, TargetSchema, TargetTable)' + @NL
    + N'SELECT * FROM (VALUES' + @NL + @Rows + @NL
    + N') AS v(EntityId, ModelName, EntityName, EntityTable, VersionId, TargetSchema, TargetTable);' + @NL;

-- 6d. Attribute rows (skipped if no entity has attributes)
SET @Rows = STUFF((
    SELECT N',' + @NL + N'    (' + CAST(EntityId AS nvarchar(10))
         + N', N''' + REPLACE(AttributeName, N'''', N'''''') + N''''
         + N', N''' + REPLACE(TableColumn,   N'''', N'''''') + N''''
         + N', '    + CAST(AttributeTypeId AS nvarchar(10))
         + N', '    + ISNULL(CAST(DomainEntityId AS nvarchar(10)), N'NULL')
         + N', '    + ISNULL(CAST(SortOrder AS nvarchar(10)), N'NULL')
         + N', N''' + REPLACE(TargetColumn,  N'''', N'''''') + N''')'
    FROM #Attributes
    ORDER BY EntityId, SortOrder
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

IF @Rows IS NOT NULL
    SET @Sql += @NL
        + N'INSERT INTO ' + @Tdb + N'.migration.Attributes' + @NL
        + N'    (EntityId, AttributeName, TableColumn, AttributeTypeId, DomainEntityId, SortOrder, TargetColumn)' + @NL
        + N'SELECT * FROM (VALUES' + @NL + @Rows + @NL
        + N') AS v(EntityId, AttributeName, TableColumn, AttributeTypeId, DomainEntityId, SortOrder, TargetColumn);'
        + @NL;

-- 6e. Drop foreign keys that point to the tables re-created in section 7
SET @Sql += @NL
    + N'-- Drop foreign keys that point to the tables re-created below (step 2 re-creates them)' + @NL
    + N'DECLARE @DropFk nvarchar(max) = N'''';' + @NL
    + N'SELECT @DropFk += N''ALTER TABLE ' + @TdbLit + N'.''' + @NL
    + N'                + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id, ' + @DbIdExpr + N')) + N''.''' + @NL
    + N'                + QUOTENAME(OBJECT_NAME(fk.parent_object_id, ' + @DbIdExpr + N'))' + @NL
    + N'                + N'' DROP CONSTRAINT '' + QUOTENAME(fk.name) + N'';'' + CHAR(13) + CHAR(10)' + @NL
    + N'FROM ' + @Tdb + N'.sys.foreign_keys AS fk' + @NL
    + N'JOIN ' + @Tdb + N'.migration.Entities AS e' + @NL
    + N'  ON fk.referenced_object_id = OBJECT_ID(N''' + @TdbLit
          + N'.'' + QUOTENAME(e.TargetSchema) + N''.'' + QUOTENAME(e.TargetTable));' + @NL
    + N'IF @DropFk <> N''''' + @NL
    + N'BEGIN' + @NL
    + N'    PRINT N''Dropping foreign keys that point to re-created tables (step 2 re-creates them).'';' + @NL
    + N'    EXEC sys.sp_executesql @DropFk;' + @NL
    + N'END;';

-- 6f. Collect (dry run) or execute
IF @DryRun = 1
    SET @Output += @DropSql + @NL + N'GO' + @NL + @NL + @Sql + @NL + N'GO' + @NL + @NL;
ELSE
BEGIN
    EXEC sys.sp_executesql @DropSql;
    EXEC sys.sp_executesql @Sql;
    PRINT N'Mapping tables written to ' + @TargetDb + N'.migration.';
END;


/* ==================================================================================================================
   SECTION 7: CREATE TABLES AND COPY DATA
   ------------------------------------------------------------------------------------------------------------------
   For each entity: drop the target table if it exists, create it with an identity primary key, a unique Code and
   the attribute columns with the same data types as in MDS, then copy the data. IDENTITY_INSERT is used to keep the
   MDS ID values; afterwards the identity continues from the highest ID. Only active members (Status_ID = 1) in the
   selected version are copied.
   ================================================================================================================== */
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT EntityId, ModelName, EntityName, EntityTable, VersionId, TargetSchema, TargetTable
    FROM #Entities
    ORDER BY TargetSchema, TargetTable;

OPEN cur;
FETCH NEXT FROM cur INTO @EntityId, @ModelName, @EntityName, @EntityTable,
                         @VersionId, @SchemaName, @TableName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- 7a. Data types of the key columns
    SET @IdType   = (SELECT TypeDef FROM #Columns WHERE TableName = @EntityTable AND ColumnName = N'ID');
    SET @MuidType = (SELECT TypeDef FROM #Columns WHERE TableName = @EntityTable AND ColumnName = N'MUID');

    -- MUID column (optional), placed right after ID
    SELECT @MuidDef = N'', @MuidIns = N'', @MuidSel = N'';
    IF @IncludeMuid = 1
        SELECT @MuidDef = N'    ' + QUOTENAME(@MuidColumn) + N' ' + @MuidType + N' NOT NULL'
                        + N' CONSTRAINT ' + QUOTENAME(LEFT(N'DF_' + @TableName + N'_' + @MuidColumn, 128))
                        + N' DEFAULT (NEWID())'
                        + N' CONSTRAINT ' + QUOTENAME(LEFT(N'UQ_' + @TableName + N'_' + @MuidColumn, 128))
                        + N' UNIQUE,' + @NL,
               @MuidIns = N'    ' + QUOTENAME(@MuidColumn) + N',' + @NL,
               @MuidSel = N'    src.MUID,' + @NL;
    SET @CodeType = (SELECT TypeDef FROM #Columns WHERE TableName = @EntityTable AND ColumnName = N'Code');
    SET @NameType = (SELECT TypeDef FROM #Columns WHERE TableName = @EntityTable AND ColumnName = N'Name');

    -- 7b. Attribute columns: definitions, INSERT list and SELECT list, one column per line
    SELECT @ColDefs = N'', @InsCols = N'', @SelCols = N'';

    SELECT @ColDefs = (
               SELECT N',' + @NL + N'    ' + QUOTENAME(a.TargetColumn) + N' ' + c.TypeDef + N' NULL'
               FROM #Attributes AS a
               JOIN #Columns    AS c ON c.TableName = @EntityTable AND c.ColumnName = a.TableColumn
               WHERE a.EntityId = @EntityId
               ORDER BY a.SortOrder
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'),
           @InsCols = (
               SELECT N',' + @NL + N'    ' + QUOTENAME(a.TargetColumn)
               FROM #Attributes AS a
               WHERE a.EntityId = @EntityId
               ORDER BY a.SortOrder
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'),
           @SelCols = (
               SELECT N',' + @NL + N'    src.' + QUOTENAME(a.TableColumn)
               FROM #Attributes AS a
               WHERE a.EntityId = @EntityId
               ORDER BY a.SortOrder
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

    SET @FullTarget = QUOTENAME(@TargetDb) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);

    -- 7c. Drop, then create and copy, formatted for readability. The drop runs as a separate batch: if the old
    --     table still exists when the create-and-copy batch is compiled, SQL Server checks the INSERT against the
    --     old columns and fails when a column is new (e.g. after switching @IncludeMuid on).
    SET @DropSql =
          N'-- ' + REPLICATE(N'-', 100) + @NL
        + N'-- ' + @ModelName + N' / ' + @EntityName
                 + N'  ->  ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) + @NL
        + N'-- ' + REPLICATE(N'-', 100) + @NL
        + N'IF OBJECT_ID(N''' + REPLACE(@FullTarget, N'''', N'''''') + N''') IS NOT NULL' + @NL
        + N'    DROP TABLE ' + @FullTarget + N';';

    SET @Sql =
          N'CREATE TABLE ' + @FullTarget + N' (' + @NL
        + N'    ' + QUOTENAME(@IdColumn) + N' ' + @IdType + N' IDENTITY(1,1) NOT NULL'
              + N' CONSTRAINT ' + QUOTENAME(LEFT(N'PK_' + @TableName, 128)) + N' PRIMARY KEY,' + @NL
        + @MuidDef
        + N'    [Code] ' + @CodeType + N' NOT NULL'
              + N' CONSTRAINT ' + QUOTENAME(LEFT(N'UQ_' + @TableName + N'_Code', 128)) + N' UNIQUE,' + @NL
        + N'    [Name] ' + @NameType + N' NULL'
        + ISNULL(@ColDefs, N'')
        + REPLACE(@CtDefs, N'{table}', REPLACE(@TableName, N']', N']]')) + @NL
        + N');' + @NL
        + @NL
        + N'SET IDENTITY_INSERT ' + @FullTarget + N' ON;' + @NL
        + @NL
        + N'INSERT INTO ' + @FullTarget + N' (' + @NL
        + N'    ' + QUOTENAME(@IdColumn) + N',' + @NL
        + @MuidIns
        + N'    [Code],' + @NL
        + N'    [Name]' + ISNULL(@InsCols, N'') + @CtInsCols + @NL
        + N')' + @NL
        + N'SELECT' + @NL
        + N'    src.ID,' + @NL
        + @MuidSel
        + N'    src.Code,' + @NL
        + N'    src.Name' + ISNULL(@SelCols, N'') + @CtSelCols + @NL
        + N'FROM ' + @Src + N'.mdm.' + QUOTENAME(@EntityTable) + N' AS src' + @CtJoins + @NL
        + N'WHERE src.Version_ID = ' + CAST(@VersionId AS nvarchar(10)) + @NL
        + N'  AND src.Status_ID = 1;' + @NL
        + @NL
        + N'SET IDENTITY_INSERT ' + @FullTarget + N' OFF;';

    -- 7d. Collect (dry run) or execute
    IF @DryRun = 1
        SET @Output += @DropSql + @NL + N'GO' + @NL + @NL + @Sql + @NL + N'GO' + @NL + @NL;
    ELSE
    BEGIN
        PRINT N'Exporting ' + @ModelName + N' / ' + @EntityName
            + N' -> ' + @SchemaName + N'.' + @TableName;
        EXEC sys.sp_executesql @DropSql;
        EXEC sys.sp_executesql @Sql;
    END;

    FETCH NEXT FROM cur INTO @EntityId, @ModelName, @EntityName, @EntityTable,
                             @VersionId, @SchemaName, @TableName;
END;

CLOSE cur;
DEALLOCATE cur;


/* ==================================================================================================================
   SECTION 8: PRINT GENERATED SQL (dry-run mode only)
   ------------------------------------------------------------------------------------------------------------------
   PRINT cuts text off at 4000 characters, so the collected SQL is printed line by line instead.
   ================================================================================================================== */
IF @DryRun = 1
BEGIN
    SET @Output = REPLACE(@Output, CHAR(13), N'');
    SET @Len    = LEN(@Output + N'.') - 1;
    SET @Pos    = 1;

    WHILE @Pos <= @Len
    BEGIN
        SET @Next = CHARINDEX(CHAR(10), @Output, @Pos);
        IF @Next = 0 SET @Next = @Len + 1;
        PRINT SUBSTRING(@Output, @Pos, @Next - @Pos);
        SET @Pos = @Next + 1;
    END;
END;

PRINT N'-- Done.';
