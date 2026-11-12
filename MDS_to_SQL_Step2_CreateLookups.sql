/* ==================================================================================================================
   MDS to SQL migration, step 2: create lookups (foreign keys and indexes)
   Version: 1.0 (https://github.com/obnex/mds-to-sql-server-migration)
   Steps:   1 CreateTablesAndCopyData, 2 CreateLookups, 3 CreateSubscriptionViews
   ------------------------------------------------------------------------------------------------------------------
   What the script does:
   - Reads the mapping tables that step 1 wrote to the schema "migration" in the target database, so it uses exactly
     the same table and column names as step 1. No connection to the MDS database is needed.
   - Finds orphaned lookups: values in a lookup column that point to an ID that does not exist in the referenced
     table, usually because the referenced member is deactivated in MDS and was not copied.
   - Creates an index on every lookup column and a foreign key from every lookup column to the referenced table's ID.
     Orphaned lookups are handled according to @OrphanHandling.
   - Derived hierarchies, recursive hierarchies (a lookup to the same entity) and many-to-many mapping entities are
     covered automatically, since they are all lookups.

   How to use:
   - Run step 1 first. Re-run this step every time step 1 has been run, since step 1 drops the foreign keys.
   - Adjust the settings in section 1.
   - Set @DryRun = 1 to only print the generated SQL. Orphans are still counted, since that only reads data.
   - The script can be run from any database on the instance and can be re-run any number of times: it drops and
     re-creates its own foreign keys and indexes.
   ================================================================================================================== */

-- Remove temp tables left over from an earlier run in the same session. Must be a separate batch,
-- otherwise SQL Server validates the main script against the old temp table definitions.
IF OBJECT_ID(N'tempdb..#Lookups') IS NOT NULL DROP TABLE #Lookups;
GO

SET NOCOUNT ON;

/* ==================================================================================================================
   SECTION 1: SETTINGS
   ------------------------------------------------------------------------------------------------------------------
   @OrphanHandling  What to do with a lookup column that has orphaned values:
     'Skip'         Default. No foreign key for that column; the data is left as it is and the column is listed in
                    the report. Fix the data and re-run, or choose another option.
     'SetNull'      Set the orphaned values to NULL, then create the foreign key. Changes data.
     'NoCheck'      Create the foreign key WITH NOCHECK: existing values are kept and not checked, new and changed
                    values are checked. The key is marked as not trusted, so the optimizer cannot rely on it.

   @CreateIndexes   1 = create a nonclustered index on every lookup column. Recommended: joins and the foreign key
                    checks on delete use them.
   ================================================================================================================== */
DECLARE @TargetDb       sysname      = N'MasterData';  -- database created by step 1
DECLARE @OrphanHandling nvarchar(20) = N'Skip';        -- 'Skip', 'SetNull' or 'NoCheck'
DECLARE @CreateIndexes  bit          = 1;              -- 1 = index every lookup column
DECLARE @DryRun         bit          = 0;              -- 0 = execute, 1 = only print SQL


/* ==================================================================================================================
   Internal variables (do not change)
   ================================================================================================================== */
DECLARE @NL           nchar(2)      = CHAR(13) + CHAR(10),   -- line break in generated SQL
        @Proc         nvarchar(400) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql',  -- runs SQL in the target db
        @Sql          nvarchar(max),
        @Output       nvarchar(max) = N'',   -- generated SQL collected in dry-run mode
        @Pos          int,
        @Next         int,
        @Len          int,
        @IdColumn     sysname,
        @LookupId     int,
        @ModelName    nvarchar(128),
        @EntityName   nvarchar(128),
        @AttrName     nvarchar(128),
        @Child        nvarchar(400),          -- [schema].[table] with the lookup column
        @ChildTable   nvarchar(128),
        @Column       nvarchar(300),
        @Parent       nvarchar(400),          -- [schema].[table] the lookup points to
        @Orphans      int,
        @OrphanWhere  nvarchar(max),
        @IndexName    nvarchar(260),
        @FkName       nvarchar(260),
        @ErrorList    nvarchar(max),
        @CntFk        int = 0,
        @CntNoCheck   int = 0,
        @CntSkipped   int = 0,
        @CntSetNull   int = 0;


/* ==================================================================================================================
   SECTION 2: VALIDATE SETTINGS
   ================================================================================================================== */
IF DB_ID(@TargetDb) IS NULL
BEGIN
    RAISERROR(N'Target database %s does not exist. Run step 1 first.', 16, 1, @TargetDb);
    RETURN;
END;

IF OBJECT_ID(QUOTENAME(@TargetDb) + N'.migration.Entities') IS NULL
   OR OBJECT_ID(QUOTENAME(@TargetDb) + N'.migration.Attributes') IS NULL
   OR OBJECT_ID(QUOTENAME(@TargetDb) + N'.migration.Settings') IS NULL
BEGIN
    RAISERROR(N'The mapping tables in %s.migration are missing. Run step 1 first.', 16, 1, @TargetDb);
    RETURN;
END;

IF @OrphanHandling NOT IN (N'Skip', N'SetNull', N'NoCheck')
BEGIN
    RAISERROR(N'Invalid @OrphanHandling: %s. Use ''Skip'', ''SetNull'' or ''NoCheck''.', 16, 1, @OrphanHandling);
    RETURN;
END;


/* ==================================================================================================================
   SECTION 3: READ THE MAPPING FROM STEP 1
   ------------------------------------------------------------------------------------------------------------------
   Loads every lookup (domain-based attribute) with the table and column it lives in and the table it points to,
   and checks that the tables and columns exist.
   ================================================================================================================== */
CREATE TABLE #Lookups (
    LookupId     int IDENTITY(1,1) PRIMARY KEY,
    ModelName    nvarchar(128) NOT NULL,
    EntityName   nvarchar(128) NOT NULL,
    AttrName     nvarchar(128) NOT NULL,
    ChildSchema  nvarchar(128) NOT NULL,
    ChildTable   nvarchar(128) NOT NULL,
    ChildColumn  nvarchar(300) NOT NULL,
    ParentSchema nvarchar(128) NULL,       -- NULL = the referenced entity is not in the mapping
    ParentTable  nvarchar(128) NULL,
    ChildExists  bit           NOT NULL,   -- the lookup column exists in the target table
    ParentExists bit           NOT NULL,   -- the referenced table exists
    Orphans      int           NULL
);

-- 3a. ID column name used by step 1
EXEC @Proc N'SELECT @id = Value FROM migration.Settings WHERE Name = N''IdColumn'';',
           N'@id sysname OUTPUT', @id = @IdColumn OUTPUT;
SET @IdColumn = ISNULL(@IdColumn, N'ID');

-- 3b. Lookups
SET @Sql = N'
SELECT ce.ModelName, ce.EntityName, a.AttributeName,
       ce.TargetSchema, ce.TargetTable, a.TargetColumn,
       pe.TargetSchema, pe.TargetTable,
       CASE WHEN COL_LENGTH(QUOTENAME(ce.TargetSchema) + N''.'' + QUOTENAME(ce.TargetTable), a.TargetColumn) IS NULL
            THEN 0 ELSE 1 END,
       CASE WHEN OBJECT_ID(QUOTENAME(pe.TargetSchema) + N''.'' + QUOTENAME(pe.TargetTable)) IS NULL
            THEN 0 ELSE 1 END,
       NULL
FROM migration.Attributes    AS a
JOIN migration.Entities      AS ce ON ce.EntityId = a.EntityId
LEFT JOIN migration.Entities AS pe ON pe.EntityId = a.DomainEntityId
WHERE a.AttributeTypeId = 2;';
INSERT INTO #Lookups (ModelName, EntityName, AttrName, ChildSchema, ChildTable, ChildColumn,
                      ParentSchema, ParentTable, ChildExists, ParentExists, Orphans)
EXEC @Proc @Sql;

-- 3c. Check that every lookup can be resolved
SET @ErrorList = (
    SELECT @NL + N'  ' + ModelName + N' / ' + EntityName + N': ' + AttrName
         + CASE WHEN ParentTable IS NULL THEN N' (referenced entity not in the mapping)'
                WHEN ChildExists = 0     THEN N' (column ' + ChildTable + N'.' + ChildColumn + N' not found)'
                ELSE N' (table ' + ParentSchema + N'.' + ParentTable + N' not found)' END
    FROM #Lookups
    WHERE ParentTable IS NULL OR ChildExists = 0 OR ParentExists = 0
    ORDER BY ModelName, EntityName, AttrName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NOT NULL
BEGIN
    PRINT N'Lookups that cannot be resolved:' + @ErrorList;
    RAISERROR(N'The tables do not match the mapping. Re-run step 1 and then this step.', 16, 1);
    RETURN;
END;

SET @Orphans = (SELECT COUNT(*) FROM #Lookups);   -- reused here as a plain counter
PRINT N'-- Lookups found: ' + CAST(@Orphans AS nvarchar(10));


/* ==================================================================================================================
   SECTION 4: COUNT ORPHANED LOOKUPS
   ------------------------------------------------------------------------------------------------------------------
   Counts, per lookup column, the values that do not exist in the referenced table. Runs in dry-run mode too.
   ================================================================================================================== */
DECLARE count_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT LookupId,
           QUOTENAME(ChildSchema) + N'.' + QUOTENAME(ChildTable),
           QUOTENAME(ChildColumn),
           QUOTENAME(ParentSchema) + N'.' + QUOTENAME(ParentTable)
    FROM #Lookups;

OPEN count_cur;
FETCH NEXT FROM count_cur INTO @LookupId, @Child, @Column, @Parent;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'SELECT @n = COUNT(*) FROM ' + @Child + N' AS c'
             + N' WHERE c.' + @Column + N' IS NOT NULL'
             + N' AND NOT EXISTS (SELECT 1 FROM ' + @Parent + N' AS p WHERE p.' + QUOTENAME(@IdColumn)
             + N' = c.' + @Column + N');';
    EXEC @Proc @Sql, N'@n int OUTPUT', @n = @Orphans OUTPUT;

    UPDATE #Lookups SET Orphans = @Orphans WHERE LookupId = @LookupId;

    FETCH NEXT FROM count_cur INTO @LookupId, @Child, @Column, @Parent;
END;

CLOSE count_cur;
DEALLOCATE count_cur;

-- 4a. Report
SET @ErrorList = (
    SELECT @NL + N'--   ' + ModelName + N' / ' + EntityName + N': ' + AttrName
         + N' -> ' + CAST(Orphans AS nvarchar(10)) + N' row(s)'
    FROM #Lookups
    WHERE Orphans > 0
    ORDER BY ModelName, EntityName, AttrName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

IF @ErrorList IS NULL
    PRINT N'-- Orphaned lookups: none' + @NL;
ELSE
    PRINT N'-- Orphaned lookups (handling: ' + @OrphanHandling + N'):' + @ErrorList + @NL;


/* ==================================================================================================================
   SECTION 5: DROP EXISTING FOREIGN KEYS
   ------------------------------------------------------------------------------------------------------------------
   Drops foreign keys between the migrated tables, so this step can be re-run. Foreign keys from other tables to the
   migrated tables are left alone.
   ================================================================================================================== */
SET @Sql =
      N'-- ' + REPLICATE(N'-', 100) + @NL
    + N'-- Drop foreign keys between the migrated tables' + @NL
    + N'-- ' + REPLICATE(N'-', 100) + @NL
    + N'DECLARE @DropFk nvarchar(max) = N'''';' + @NL
    + N'SELECT @DropFk += N''ALTER TABLE '' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id))' + @NL
    + N'                + N''.'' + QUOTENAME(OBJECT_NAME(fk.parent_object_id))' + @NL
    + N'                + N'' DROP CONSTRAINT '' + QUOTENAME(fk.name) + N'';'' + CHAR(13) + CHAR(10)' + @NL
    + N'FROM sys.foreign_keys AS fk' + @NL
    + N'JOIN migration.Entities AS pe' + @NL
    + N'  ON fk.referenced_object_id = OBJECT_ID(QUOTENAME(pe.TargetSchema) + N''.'' + QUOTENAME(pe.TargetTable))' + @NL
    + N'JOIN migration.Entities AS ce' + @NL
    + N'  ON fk.parent_object_id = OBJECT_ID(QUOTENAME(ce.TargetSchema) + N''.'' + QUOTENAME(ce.TargetTable));' + @NL
    + N'IF @DropFk <> N''''' + @NL
    + N'BEGIN' + @NL
    + N'    PRINT N''Dropping existing foreign keys:'';' + @NL
    + N'    PRINT @DropFk;' + @NL
    + N'    EXEC sys.sp_executesql @DropFk;' + @NL
    + N'END;';

IF @DryRun = 1
    SET @Output += N'USE ' + QUOTENAME(@TargetDb) + N';' + @NL + N'GO' + @NL + @NL
                 + @Sql + @NL + N'GO' + @NL + @NL;
ELSE
    EXEC @Proc @Sql;


/* ==================================================================================================================
   SECTION 6: CREATE INDEXES AND FOREIGN KEYS
   ------------------------------------------------------------------------------------------------------------------
   For each lookup column: handle orphans (SetNull), create the index and create the foreign key to the referenced
   table's ID. Foreign keys use the default ON DELETE NO ACTION: a row that is still referenced cannot be deleted.
   ================================================================================================================== */
DECLARE fk_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ModelName, EntityName, AttrName,
           QUOTENAME(ChildSchema) + N'.' + QUOTENAME(ChildTable), ChildTable, ChildColumn,
           QUOTENAME(ParentSchema) + N'.' + QUOTENAME(ParentTable), Orphans
    FROM #Lookups
    ORDER BY ChildSchema, ChildTable, ChildColumn;

OPEN fk_cur;
FETCH NEXT FROM fk_cur INTO @ModelName, @EntityName, @AttrName, @Child, @ChildTable, @Column, @Parent, @Orphans;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IndexName   = QUOTENAME(LEFT(N'IX_' + @ChildTable + N'_' + @Column, 128));
    SET @FkName      = QUOTENAME(LEFT(N'FK_' + @ChildTable + N'_' + @Column, 128));
    SET @OrphanWhere = N'c.' + QUOTENAME(@Column) + N' IS NOT NULL' + @NL
                     + N'  AND NOT EXISTS (SELECT 1 FROM ' + @Parent + N' AS p WHERE p.' + QUOTENAME(@IdColumn)
                     + N' = c.' + QUOTENAME(@Column) + N')';

    -- 6a. Header
    SET @Sql =
          N'-- ' + REPLICATE(N'-', 100) + @NL
        + N'-- ' + @ModelName + N' / ' + @EntityName + N': ' + @AttrName
                 + N'  ->  ' + @Child + N'.' + QUOTENAME(@Column) + N' references ' + @Parent + @NL
        + N'-- ' + REPLICATE(N'-', 100) + @NL;

    -- 6b. Orphans set to NULL
    IF @Orphans > 0 AND @OrphanHandling = N'SetNull'
    BEGIN
        SET @Sql += N'-- ' + CAST(@Orphans AS nvarchar(10)) + N' orphaned value(s) set to NULL' + @NL
                  + N'UPDATE c SET c.' + QUOTENAME(@Column) + N' = NULL' + @NL
                  + N'FROM ' + @Child + N' AS c' + @NL
                  + N'WHERE ' + @OrphanWhere + N';' + @NL + @NL;
        SET @CntSetNull += @Orphans;
    END;

    -- 6c. Index
    IF @CreateIndexes = 1
        SET @Sql += N'IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'''
                  + REPLACE(LEFT(N'IX_' + @ChildTable + N'_' + @Column, 128), N'''', N'''''')
                  + N''' AND object_id = OBJECT_ID(N''' + REPLACE(@Child, N'''', N'''''') + N'''))' + @NL
                  + N'    DROP INDEX ' + @IndexName + N' ON ' + @Child + N';' + @NL
                  + N'CREATE INDEX ' + @IndexName + N' ON ' + @Child + N' (' + QUOTENAME(@Column) + N');' + @NL + @NL;

    -- 6d. Foreign key
    IF @Orphans > 0 AND @OrphanHandling = N'Skip'
    BEGIN
        SET @Sql += N'-- No foreign key: ' + CAST(@Orphans AS nvarchar(10))
                  + N' orphaned value(s). Inspect them with:' + @NL
                  + N'-- SELECT c.* FROM ' + @Child + N' AS c WHERE ' + REPLACE(@OrphanWhere, @NL, N' ') + N';';
        SET @CntSkipped += 1;
    END
    ELSE
    BEGIN
        SET @Sql += N'ALTER TABLE ' + @Child
                  + CASE WHEN @Orphans > 0 AND @OrphanHandling = N'NoCheck'
                         THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
                  + N' ADD CONSTRAINT ' + @FkName + @NL
                  + N'    FOREIGN KEY (' + QUOTENAME(@Column) + N') REFERENCES ' + @Parent
                  + N' (' + QUOTENAME(@IdColumn) + N');';
        IF @Orphans > 0 AND @OrphanHandling = N'NoCheck'
            SET @CntNoCheck += 1;
        ELSE
            SET @CntFk += 1;
    END;

    -- 6e. Collect (dry run) or execute
    IF @DryRun = 1
        SET @Output += @Sql + @NL + N'GO' + @NL + @NL;
    ELSE
    BEGIN
        PRINT N'Relating ' + @ModelName + N' / ' + @EntityName + N': ' + @AttrName + N' -> ' + @Parent;
        EXEC @Proc @Sql;
    END;

    FETCH NEXT FROM fk_cur INTO @ModelName, @EntityName, @AttrName, @Child, @ChildTable, @Column, @Parent, @Orphans;
END;

CLOSE fk_cur;
DEALLOCATE fk_cur;


/* ==================================================================================================================
   SECTION 7: PRINT GENERATED SQL (dry-run mode only) AND SUMMARY
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

PRINT N'-- Summary' + CASE WHEN @DryRun = 1 THEN N' (dry run, nothing changed)' ELSE N'' END + N':';
PRINT N'--   Foreign keys created:            ' + CAST(@CntFk AS nvarchar(10));
PRINT N'--   Foreign keys WITH NOCHECK:       ' + CAST(@CntNoCheck AS nvarchar(10));
PRINT N'--   Skipped because of orphans:      ' + CAST(@CntSkipped AS nvarchar(10));
PRINT N'--   Orphaned values set to NULL:     ' + CAST(@CntSetNull AS nvarchar(10));
PRINT N'-- Done.';
