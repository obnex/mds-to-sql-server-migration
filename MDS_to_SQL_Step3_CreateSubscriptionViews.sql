/* ==================================================================================================================
   MDS to SQL migration, step 3: create subscription views
   Version: 1.0 (https://github.com/obnex/mds-to-sql-server-migration)
   Steps:   1 CreateTablesAndCopyData, 2 CreateLookups, 3 CreateSubscriptionViews
   ------------------------------------------------------------------------------------------------------------------
   What the script does:
   - Reads the subscription views defined in MDS (mdm.tblSubscriptionView) and the exact columns and data types of
     each view, and the mapping that step 1 wrote to the schema "migration" in the target database.
   - Creates a view with the same name, the same columns and the same data types in the target database, on top of
     the migrated tables. Downstream systems that read the MDS views only need to point to the new database.
   - Column mapping:
       ID, Code, Name, attributes             -> the migrated columns
       MUID                                   -> the MUID column if step 1 kept it, else NULL
       <Attribute>_ID / _Code / _Name         -> the lookup column / Code / Name of the referenced row
       EnterDateTime / EnterUserName          -> the change tracking columns (created on / by), as UTC
       LastChgDateTime / LastChgUserName      -> the change tracking columns (modified on / by), as UTC
       VersionName, VersionNumber, Version_ID,
       VersionFlag, Enter/LastChgVersionNumber -> the value MDS had for the copied version (fixed)
       ChangeTrackingMask                     -> 0
       ValidationStatus                       -> 'Validation Succeeded'
       State                                  -> 'Active' (only active members are migrated)
       anything else                          -> NULL, listed in the report
   - Formats created:
       1      leaf attributes: one row per member, mapped as above
       7      derived hierarchy, parent-child: one row per member with its parent in the hierarchy
       8      derived hierarchy, levels: one row per bottom member with a column group per level
     Derived hierarchies are read from mdm.tblDerivedHierarchy / tblDerivedHierarchyDetail. Hierarchies that are
     recursive, use a many-to-many level or include an explicit hierarchy are listed in the report.
   - Formats not created (listed in the report):
       9, 12  history and SCD type 2 views: need the MDS change history, which is not migrated
       other  explicit hierarchies, collections, consolidated members: not migrated yet
   - After creating the views, compares the row count of every new view with the MDS view.
   - Ends with a report: the views created, the row counts, the views not created and any columns without a source.

   How to use:
   - Run steps 1 and 2 first. Re-run this step every time step 1 has been run.
   - Set @DryRun = 1 to only print the generated SQL.
   - The script can be run from any database on the instance and can be re-run any number of times.
   ================================================================================================================== */

-- Remove temp tables left over from an earlier run in the same session. Must be a separate batch,
-- otherwise SQL Server validates the main script against the old temp table definitions.
IF OBJECT_ID(N'tempdb..#Ent')      IS NOT NULL DROP TABLE #Ent;
IF OBJECT_ID(N'tempdb..#Attr')     IS NOT NULL DROP TABLE #Attr;
IF OBJECT_ID(N'tempdb..#Views')    IS NOT NULL DROP TABLE #Views;
IF OBJECT_ID(N'tempdb..#ViewCols') IS NOT NULL DROP TABLE #ViewCols;
IF OBJECT_ID(N'tempdb..#Hier')        IS NOT NULL DROP TABLE #Hier;
IF OBJECT_ID(N'tempdb..#HierLevels')  IS NOT NULL DROP TABLE #HierLevels;
GO

SET NOCOUNT ON;

/* ==================================================================================================================
   SECTION 1: SETTINGS
   ------------------------------------------------------------------------------------------------------------------
   @ViewSchema  Schema for the views in the target database. 'mdm' gives the same two-part names as in MDS
                (mdm.<view>), so downstream systems only change the database name in their connection.
   ================================================================================================================== */
DECLARE @TargetDb   sysname = N'MasterData';  -- database created by step 1
DECLARE @ViewSchema sysname = N'mdm';         -- schema for the views
DECLARE @DryRun     bit     = 0;              -- 0 = execute, 1 = only print SQL


/* ==================================================================================================================
   Internal variables (do not change)
   ================================================================================================================== */
DECLARE @NL           nchar(2)      = CHAR(13) + CHAR(10),   -- line break in generated SQL
        @Proc         nvarchar(400) = QUOTENAME(@TargetDb) + N'.sys.sp_executesql',  -- runs SQL in the target db
        @Sql          nvarchar(max),
        @Inner        nvarchar(max),
        @Output       nvarchar(max) = N'',   -- generated SQL collected in dry-run mode
        @Pos          int,
        @Next         int,
        @Len          int,
        @SourceDb     sysname,
        @Src          nvarchar(260),
        @IdColumn     sysname,
        @IncludeMuid  bit,
        @MuidColumn   sysname,
        @AddCt        bit,
        @CreatedOn    sysname,
        @CreatedBy    sysname,
        @ModifiedOn   sysname,
        @ModifiedBy   sysname,
        @ViewName     nvarchar(128),
        @ColumnName   nvarchar(128),
        @Value        nvarchar(400),
        @Table        nvarchar(400),
        @FullView     nvarchar(400),
        @Select       nvarchar(max),
        @Joins        nvarchar(max),
        @ObjType      nvarchar(10),
        @CountMds     bigint,
        @CountNew     bigint,
        @ErrorList    nvarchar(max),
        @CntViews     int = 0,
        @RptCreated   nvarchar(max) = N'',   -- report: views created
        @RptNotCreated nvarchar(max) = N'',  -- report: views not created
        @RptUnmapped  nvarchar(max),          -- report: columns without a source
        @RptVersion   nvarchar(max),          -- report: views bound to another version
        @RptCounts    nvarchar(max) = N'',   -- report: row counts
        @Report       nvarchar(max),
        @HasHierMeta  bit = 0,
        @Format       int,
        @HierId       int,
        @Depth        int,
        @Lvl          int,
        @ChildEnt     int,
        @ChildEntName nvarchar(128),
        @ParEnt       int,
        @ParEntName   nvarchar(128),
        @C            nvarchar(20),           -- child alias in a parent-child branch
        @P            nvarchar(20),           -- parent alias in a parent-child branch
        @Branch       nvarchar(max),
        @Union        nvarchar(max);


/* ==================================================================================================================
   SECTION 2: VALIDATE AND READ THE SETTINGS FROM STEP 1
   ================================================================================================================== */
IF DB_ID(@TargetDb) IS NULL
BEGIN
    RAISERROR(N'Target database %s does not exist. Run step 1 first.', 16, 1, @TargetDb);
    RETURN;
END;

IF OBJECT_ID(QUOTENAME(@TargetDb) + N'.migration.Settings') IS NULL
BEGIN
    RAISERROR(N'The mapping tables in %s.migration are missing. Run step 1 first.', 16, 1, @TargetDb);
    RETURN;
END;

EXEC @Proc N'
SELECT @src = (SELECT Value FROM migration.Settings WHERE Name = N''SourceDb''),
       @id  = (SELECT Value FROM migration.Settings WHERE Name = N''IdColumn''),
       @im  = (SELECT Value FROM migration.Settings WHERE Name = N''IncludeMuid''),
       @mc  = (SELECT Value FROM migration.Settings WHERE Name = N''MuidColumn''),
       @ct  = (SELECT Value FROM migration.Settings WHERE Name = N''AddChangeTracking''),
       @con = (SELECT Value FROM migration.Settings WHERE Name = N''CreatedOnColumn''),
       @cby = (SELECT Value FROM migration.Settings WHERE Name = N''CreatedByColumn''),
       @mon = (SELECT Value FROM migration.Settings WHERE Name = N''ModifiedOnColumn''),
       @mby = (SELECT Value FROM migration.Settings WHERE Name = N''ModifiedByColumn'');',
    N'@src sysname OUTPUT, @id sysname OUTPUT, @im bit OUTPUT, @mc sysname OUTPUT, @ct bit OUTPUT,
      @con sysname OUTPUT, @cby sysname OUTPUT, @mon sysname OUTPUT, @mby sysname OUTPUT',
    @src = @SourceDb OUTPUT, @id = @IdColumn OUTPUT, @im = @IncludeMuid OUTPUT, @mc = @MuidColumn OUTPUT,
    @ct = @AddCt OUTPUT, @con = @CreatedOn OUTPUT, @cby = @CreatedBy OUTPUT, @mon = @ModifiedOn OUTPUT,
    @mby = @ModifiedBy OUTPUT;

SELECT @IdColumn = ISNULL(@IdColumn, N'ID'), @IncludeMuid = ISNULL(@IncludeMuid, 0), @AddCt = ISNULL(@AddCt, 0),
       @Src = QUOTENAME(@SourceDb);

IF @SourceDb IS NULL OR DB_ID(@SourceDb) IS NULL
BEGIN
    RAISERROR(N'The MDS database from step 1 (%s) is not available on this instance.', 16, 1, @SourceDb);
    RETURN;
END;

IF OBJECT_ID(@Src + N'.mdm.tblSubscriptionView') IS NULL
BEGIN
    RAISERROR(N'mdm.tblSubscriptionView was not found in %s. This MDS version is not supported.', 16, 1, @SourceDb);
    RETURN;
END;


/* ==================================================================================================================
   SECTION 3: READ THE MAPPING, THE SUBSCRIPTION VIEWS AND THEIR COLUMNS
   ================================================================================================================== */
CREATE TABLE #Ent (
    EntityId     int           NOT NULL PRIMARY KEY,
    ModelName    nvarchar(128) NOT NULL,
    EntityName   nvarchar(128) NOT NULL,
    VersionId    int           NOT NULL,
    TargetSchema nvarchar(128) NOT NULL,
    TargetTable  nvarchar(128) NOT NULL
);

CREATE TABLE #Attr (
    EntityId        int           NOT NULL,
    AttributeName   nvarchar(128) NOT NULL,
    TableColumn     nvarchar(128) NOT NULL,
    AttributeTypeId int           NOT NULL,
    DomainEntityId  int           NULL,
    TargetColumn    nvarchar(300) NOT NULL
);

CREATE TABLE #Views (
    ViewName  nvarchar(128) NOT NULL PRIMARY KEY,
    EntityId  int           NULL,
    FormatId  int           NULL,       -- 1 = leaf attributes, 7 = parent-child, 8 = levels
    HierarchyId int         NULL,       -- derived hierarchy for formats 7 and 8
    Levels    int           NULL,       -- number of levels in a levels view
    Supported bit           NOT NULL DEFAULT 0,
    Note      nvarchar(400) NULL
);

CREATE TABLE #ViewCols (
    ViewName   nvarchar(128)  NOT NULL,
    ColumnId   int            NOT NULL,
    ColumnName nvarchar(128)  NOT NULL,
    TypeDef    nvarchar(200)  NOT NULL,
    Expr       nvarchar(max)  NULL,     -- source expression in the new view; NULL = not mapped
    JoinSql    nvarchar(1000) NULL,     -- join to the referenced table for _Code / _Name columns
    IsConstant bit            NOT NULL DEFAULT 0,
    Mapped     bit            NOT NULL DEFAULT 0,
    PRIMARY KEY (ViewName, ColumnId)
);

-- 3a. Mapping from step 1
INSERT INTO #Ent
EXEC @Proc N'SELECT EntityId, ModelName, EntityName, VersionId, TargetSchema, TargetTable FROM migration.Entities;';

INSERT INTO #Attr
EXEC @Proc N'SELECT EntityId, AttributeName, TableColumn, AttributeTypeId, DomainEntityId, TargetColumn
             FROM migration.Attributes;';

-- 3b. Subscription views that exist in MDS
SET @Sql = N'
SELECT sv.Name, sv.Entity_ID, sv.ViewFormat_ID, '
    + CASE WHEN COL_LENGTH(@Src + N'.mdm.tblSubscriptionView', N'DerivedHierarchy_ID') IS NOT NULL
           THEN N'sv.DerivedHierarchy_ID' ELSE N'NULL' END + N', '
    + CASE WHEN COL_LENGTH(@Src + N'.mdm.tblSubscriptionView', N'Levels') IS NOT NULL
           THEN N'sv.Levels' ELSE N'NULL' END + N', 0, NULL
FROM ' + @Src + N'.mdm.tblSubscriptionView AS sv
WHERE OBJECT_ID(N''' + REPLACE(@Src, N'''', N'''''') + N'.mdm.'' + QUOTENAME(sv.Name)) IS NOT NULL;';
INSERT INTO #Views EXEC sys.sp_executesql @Sql;

-- 3c. Derived hierarchies and their levels (level 1 = the bottom entity, each higher level is reached through a lookup)
CREATE TABLE #Hier (
    HierarchyId int           NOT NULL PRIMARY KEY,
    HierName    nvarchar(128) NOT NULL,
    Depth       int           NULL,
    Supported   bit           NOT NULL DEFAULT 0,
    Note        nvarchar(400) NULL
);

CREATE TABLE #HierLevels (
    HierarchyId     int           NOT NULL,
    LevelId         int           NOT NULL,   -- 1 = bottom level
    DisplayName     nvarchar(128) NOT NULL,   -- used in the column names of a levels view
    ForeignTypeId   int           NOT NULL,   -- 0 = entity (bottom level), 1 = lookup, other = not supported
    EntityId        int           NULL,       -- entity of this level
    OwnerEntityId   int           NULL,       -- entity that has the lookup to this level (the level below)
    LinkTableColumn nvarchar(128) NULL,       -- MDS column of that lookup
    LinkColumn      nvarchar(300) NULL,       -- migrated column of that lookup
    PRIMARY KEY (HierarchyId, LevelId)
);

SET @HasHierMeta = CASE WHEN OBJECT_ID(@Src + N'.mdm.tblDerivedHierarchy') IS NOT NULL
                         AND OBJECT_ID(@Src + N'.mdm.tblDerivedHierarchyDetail') IS NOT NULL
                         AND OBJECT_ID(@Src + N'.mdm.tblAttribute') IS NOT NULL
                         AND COL_LENGTH(@Src + N'.mdm.tblSubscriptionView', N'DerivedHierarchy_ID') IS NOT NULL
                        THEN 1 ELSE 0 END;

IF @HasHierMeta = 1
BEGIN
    SET @Sql = N'SELECT h.ID, h.Name, NULL, 0, NULL FROM ' + @Src + N'.mdm.tblDerivedHierarchy AS h;';
    INSERT INTO #Hier EXEC sys.sp_executesql @Sql;

    SET @Sql = N'
SELECT d.DerivedHierarchy_ID, d.Level_ID, d.DisplayName, d.ForeignType_ID,
       CASE WHEN d.ForeignType_ID = 0 THEN d.Foreign_ID ELSE a.DomainEntity_ID END,
       a.Entity_ID, a.TableColumn, NULL
FROM ' + @Src + N'.mdm.tblDerivedHierarchyDetail AS d
LEFT JOIN ' + @Src + N'.mdm.tblAttribute AS a ON d.ForeignType_ID = 1 AND a.ID = d.Foreign_ID;';
    INSERT INTO #HierLevels EXEC sys.sp_executesql @Sql;

    UPDATE hl SET LinkColumn = a.TargetColumn
    FROM #HierLevels AS hl
    JOIN #Attr       AS a ON a.EntityId = hl.OwnerEntityId AND a.TableColumn = hl.LinkTableColumn;

    UPDATE h SET Depth = (SELECT MAX(hl.LevelId) FROM #HierLevels AS hl WHERE hl.HierarchyId = h.HierarchyId)
    FROM #Hier AS h;

    -- Check that each hierarchy is a plain chain of lookups between migrated entities
    UPDATE h
    SET Note = CASE
        WHEN EXISTS (SELECT 1 FROM #HierLevels AS hl
                     WHERE hl.HierarchyId = h.HierarchyId AND hl.ForeignTypeId NOT IN (0, 1))
            THEN N'a level type is not supported (many-to-many or explicit hierarchy)'
        WHEN h.Depth IS NULL
          OR (SELECT COUNT(*) FROM #HierLevels AS hl WHERE hl.HierarchyId = h.HierarchyId) <> h.Depth
          OR NOT EXISTS (SELECT 1 FROM #HierLevels AS hl
                         WHERE hl.HierarchyId = h.HierarchyId AND hl.LevelId = 1 AND hl.ForeignTypeId = 0)
            THEN N'unexpected level structure'
        WHEN EXISTS (SELECT 1 FROM #HierLevels AS hl
                     WHERE hl.HierarchyId = h.HierarchyId AND hl.LevelId > 1 AND hl.EntityId = hl.OwnerEntityId)
            THEN N'recursive hierarchy, not supported yet'
        WHEN EXISTS (SELECT 1 FROM #HierLevels AS hl
                     JOIN #HierLevels AS below ON below.HierarchyId = hl.HierarchyId
                                              AND below.LevelId = hl.LevelId - 1
                     WHERE hl.HierarchyId = h.HierarchyId AND hl.LevelId > 1
                       AND ISNULL(hl.OwnerEntityId, -1) <> ISNULL(below.EntityId, -2))
            THEN N'unexpected level structure'
        WHEN EXISTS (SELECT 1 FROM #HierLevels AS hl
                     WHERE hl.HierarchyId = h.HierarchyId
                       AND NOT EXISTS (SELECT 1 FROM #Ent AS e WHERE e.EntityId = hl.EntityId))
            THEN N'an entity in the hierarchy was not migrated'
        WHEN EXISTS (SELECT 1 FROM #HierLevels AS hl
                     WHERE hl.HierarchyId = h.HierarchyId AND hl.LevelId > 1 AND hl.LinkColumn IS NULL)
            THEN N'a lookup in the hierarchy is not in the mapping'
        END
    FROM #Hier AS h;

    UPDATE #Hier SET Supported = CASE WHEN Note IS NULL THEN 1 ELSE 0 END;
END;

-- 3d. Which views can be created
UPDATE v
SET Supported = CASE WHEN v.FormatId = 1 AND e.EntityId IS NOT NULL                          THEN 1
                     WHEN v.FormatId = 7 AND h.Supported = 1                                 THEN 1
                     WHEN v.FormatId = 8 AND h.Supported = 1 AND ISNULL(v.Levels, h.Depth) = h.Depth THEN 1
                     ELSE 0 END
FROM #Views AS v
LEFT JOIN #Ent  AS e ON e.EntityId = v.EntityId
LEFT JOIN #Hier AS h ON h.HierarchyId = v.HierarchyId;

UPDATE v
SET Note = CASE
               WHEN v.FormatId IN (7, 8) AND @HasHierMeta = 0
                   THEN N'derived hierarchy view, but the hierarchy metadata was not found in this MDS version'
               WHEN v.FormatId IN (7, 8) AND h.HierarchyId IS NULL
                   THEN N'derived hierarchy view, but the hierarchy was not found'
               WHEN v.FormatId IN (7, 8) AND h.Supported = 0
                   THEN N'derived hierarchy ' + h.HierName + N': ' + h.Note
               WHEN v.FormatId = 8
                   THEN N'levels view with ' + CAST(v.Levels AS nvarchar(10)) + N' of '
                        + CAST(h.Depth AS nvarchar(10)) + N' levels, not supported yet'
               WHEN v.FormatId IN (9, 12)
                   THEN N'history view (format ' + CAST(v.FormatId AS nvarchar(10))
                        + N'), needs the MDS change history, which is not migrated'
               WHEN v.FormatId <> 1 OR v.FormatId IS NULL
                   THEN N'format ' + ISNULL(CAST(v.FormatId AS nvarchar(10)), N'?')
                        + N' (explicit hierarchy, collection or consolidated members), not migrated yet'
               ELSE N'entity not in the mapping from step 1'
           END
FROM #Views AS v
LEFT JOIN #Hier AS h ON h.HierarchyId = v.HierarchyId
WHERE v.Supported = 0;

-- 3e. Columns and data types of the views in MDS
SET @Sql = N'
SELECT vw.name, c.column_id, c.name,
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
       END,
       NULL, NULL, 0, 0
FROM ' + @Src + N'.sys.views   AS vw
JOIN ' + @Src + N'.sys.schemas AS s  ON s.schema_id = vw.schema_id AND s.name = N''mdm''
JOIN ' + @Src + N'.sys.columns AS c  ON c.object_id = vw.object_id
JOIN ' + @Src + N'.sys.types   AS ty ON ty.user_type_id = c.system_type_id;';
INSERT INTO #ViewCols EXEC sys.sp_executesql @Sql;

DELETE vc FROM #ViewCols AS vc
WHERE NOT EXISTS (SELECT 1 FROM #Views AS v WHERE v.ViewName = vc.ViewName AND v.Supported = 1);


/* ==================================================================================================================
   SECTION 4: MAP EVERY VIEW COLUMN TO THE MIGRATED TABLES
   ------------------------------------------------------------------------------------------------------------------
   In leaf views the table is aliased t and a referenced table for a lookup l_<MDS column>.
   ================================================================================================================== */

-- 4a. System columns
UPDATE #ViewCols SET Mapped = 1, Expr = N't.' + QUOTENAME(@IdColumn) WHERE ColumnName = N'ID';
UPDATE #ViewCols SET Mapped = 1, Expr = N't.[Code]'                 WHERE ColumnName = N'Code';
UPDATE #ViewCols SET Mapped = 1, Expr = N't.[Name]'                 WHERE ColumnName = N'Name';
UPDATE #ViewCols SET Mapped = 1, Expr = N't.' + QUOTENAME(@MuidColumn)
WHERE ColumnName = N'MUID' AND @IncludeMuid = 1;
UPDATE #ViewCols SET Mapped = 1, Expr = N'0'                        WHERE ColumnName = N'ChangeTrackingMask';
UPDATE #ViewCols SET Mapped = 1, Expr = N'N''Validation Succeeded''' WHERE ColumnName = N'ValidationStatus';
UPDATE #ViewCols SET Mapped = 1, Expr = N'N''Active'''               WHERE ColumnName = N'State';
UPDATE #ViewCols SET IsConstant = 1
WHERE ColumnName IN (N'VersionName', N'VersionNumber', N'Version_ID', N'VersionFlag',
                     N'EnterVersionNumber', N'LastChgVersionNumber');

-- 4b. Change tracking columns (stored as datetimeoffset; MDS views show UTC as datetime2)
IF @AddCt = 1
BEGIN
    UPDATE #ViewCols SET Mapped = 1, Expr = N'SWITCHOFFSET(t.' + QUOTENAME(@CreatedOn) + N', ''+00:00'')'
    WHERE ColumnName = N'EnterDateTime';
    UPDATE #ViewCols SET Mapped = 1, Expr = N't.' + QUOTENAME(@CreatedBy)  WHERE ColumnName = N'EnterUserName';
    UPDATE #ViewCols SET Mapped = 1, Expr = N'SWITCHOFFSET(t.' + QUOTENAME(@ModifiedOn) + N', ''+00:00'')'
    WHERE ColumnName = N'LastChgDateTime';
    UPDATE #ViewCols SET Mapped = 1, Expr = N't.' + QUOTENAME(@ModifiedBy) WHERE ColumnName = N'LastChgUserName';
END;

-- 4c. Free-form and file attributes
UPDATE vc SET Mapped = 1, Expr = N't.' + QUOTENAME(a.TargetColumn)
FROM #ViewCols AS vc
JOIN #Views    AS v ON v.ViewName = vc.ViewName
JOIN #Attr     AS a ON a.EntityId = v.EntityId AND a.AttributeName = vc.ColumnName AND a.AttributeTypeId <> 2
WHERE vc.Mapped = 0 AND vc.IsConstant = 0;

-- 4d. Lookups: <Attribute>_ID, <Attribute>_Code, <Attribute>_Name (and <Attribute> alone = Code)
UPDATE vc
SET Mapped  = 1,
    Expr    = CASE WHEN vc.ColumnName = a.AttributeName + N'_ID' THEN N't.' + QUOTENAME(a.TargetColumn)
                   WHEN vc.ColumnName = a.AttributeName + N'_Name' THEN QUOTENAME(N'l_' + a.TableColumn) + N'.[Name]'
                   ELSE QUOTENAME(N'l_' + a.TableColumn) + N'.[Code]' END,
    JoinSql = CASE WHEN vc.ColumnName = a.AttributeName + N'_ID' THEN NULL
                   ELSE N'    LEFT JOIN ' + QUOTENAME(pe.TargetSchema) + N'.' + QUOTENAME(pe.TargetTable)
                        + N' AS ' + QUOTENAME(N'l_' + a.TableColumn)
                        + N' ON ' + QUOTENAME(N'l_' + a.TableColumn) + N'.' + QUOTENAME(@IdColumn)
                        + N' = t.' + QUOTENAME(a.TargetColumn) END
FROM #ViewCols AS vc
JOIN #Views    AS v  ON v.ViewName = vc.ViewName
JOIN #Attr     AS a  ON a.EntityId = v.EntityId AND a.AttributeTypeId = 2
                    AND vc.ColumnName IN (a.AttributeName + N'_ID', a.AttributeName + N'_Code',
                                          a.AttributeName + N'_Name', a.AttributeName)
JOIN #Ent      AS pe ON pe.EntityId = a.DomainEntityId
WHERE vc.Mapped = 0 AND vc.IsConstant = 0;

-- 4e. Fixed values: read the value MDS shows for the copied version
DECLARE const_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ViewName, ColumnName FROM #ViewCols WHERE IsConstant = 1;

OPEN const_cur;
FETCH NEXT FROM const_cur INTO @ViewName, @ColumnName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Value = NULL;
    SET @Sql = N'SELECT TOP (1) @v = CONVERT(nvarchar(400), ' + QUOTENAME(@ColumnName) + N')'
             + N' FROM ' + @Src + N'.mdm.' + QUOTENAME(@ViewName) + N';';
    EXEC sys.sp_executesql @Sql, N'@v nvarchar(400) OUTPUT', @v = @Value OUTPUT;

    UPDATE #ViewCols
    SET Mapped = 1, Expr = ISNULL(N'N''' + REPLACE(@Value, N'''', N'''''') + N'''', N'NULL')
    WHERE ViewName = @ViewName AND ColumnName = @ColumnName;

    FETCH NEXT FROM const_cur INTO @ViewName, @ColumnName;
END;

CLOSE const_cur;
DEALLOCATE const_cur;

-- 4f. Derived hierarchy views: the hierarchy name, ROOT, and the level columns <Level>_ID / _Code / _Name.
--     In a levels view the bottom level is aliased L1, the next L2 and so on. Parent-child columns are filled in
--     per level when the view is created (section 7).
UPDATE vc SET Mapped = 1, Expr = N'N''' + REPLACE(h.HierName, N'''', N'''''') + N''''
FROM #ViewCols AS vc
JOIN #Views    AS v ON v.ViewName = vc.ViewName
JOIN #Hier     AS h ON h.HierarchyId = v.HierarchyId
WHERE v.FormatId IN (7, 8) AND vc.ColumnName = N'Hierarchy';

UPDATE vc SET Mapped = 1, Expr = N'N''ROOT'''
FROM #ViewCols AS vc
JOIN #Views    AS v ON v.ViewName = vc.ViewName
WHERE v.FormatId = 8 AND vc.ColumnName = N'ROOT';

UPDATE vc
SET Mapped = 1,
    Expr   = QUOTENAME(N'L' + CAST(hl.LevelId AS nvarchar(10)))
           + CASE WHEN vc.ColumnName = hl.DisplayName + N'_ID'   THEN N'.' + QUOTENAME(@IdColumn)
                  WHEN vc.ColumnName = hl.DisplayName + N'_Code' THEN N'.[Code]'
                  ELSE N'.[Name]' END
FROM #ViewCols   AS vc
JOIN #Views      AS v  ON v.ViewName = vc.ViewName
JOIN #HierLevels AS hl ON hl.HierarchyId = v.HierarchyId
                      AND vc.ColumnName IN (hl.DisplayName + N'_ID', hl.DisplayName + N'_Code',
                                            hl.DisplayName + N'_Name')
WHERE v.FormatId = 8 AND vc.Mapped = 0;

UPDATE vc SET Mapped = 1
FROM #ViewCols AS vc
JOIN #Views    AS v ON v.ViewName = vc.ViewName
WHERE v.FormatId = 7
  AND vc.ColumnName IN (N'ChildType_ID', N'Child_ID', N'ChildCode', N'ChildName', N'Child_Entity_ID',
                        N'Child_EntityName', N'ParentType_ID', N'Parent_ID', N'ParentCode', N'ParentName',
                        N'Parent_Entity_ID', N'Parent_EntityName');

-- 4g. Collect for the report: views not created, columns that become NULL, views bound to another version
SET @ErrorList = (
    SELECT @NL + N'--   ' + ViewName + N': ' + Note
    FROM #Views WHERE Supported = 0 ORDER BY ViewName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');
SET @RptNotCreated = ISNULL(@ErrorList, N'');

SET @ErrorList = (
    SELECT @NL + N'--   ' + ViewName + N'.' + ColumnName
    FROM #ViewCols WHERE Mapped = 0 ORDER BY ViewName, ColumnId
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');
SET @RptUnmapped = @ErrorList;

SET @ErrorList = (
    SELECT @NL + N'--   ' + vc.ViewName + N' shows version ' + REPLACE(REPLACE(vc.Expr, N'N''', N''), N'''', N'')
         + N', step 1 copied version ' + CAST(e.VersionId AS nvarchar(10))
    FROM #ViewCols AS vc
    JOIN #Views    AS v ON v.ViewName = vc.ViewName
    JOIN #Ent      AS e ON e.EntityId = v.EntityId
    WHERE vc.ColumnName = N'Version_ID' AND vc.Expr <> N'N''' + CAST(e.VersionId AS nvarchar(10)) + N''''
    ORDER BY vc.ViewName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');
SET @RptVersion = @ErrorList;


/* ==================================================================================================================
   SECTION 5: CREATE THE VIEW SCHEMA
   ================================================================================================================== */
SET @Inner = N'IF SCHEMA_ID(N''' + REPLACE(@ViewSchema, N'''', N'''''') + N''') IS NULL'
           + N' EXEC(N''CREATE SCHEMA ' + REPLACE(QUOTENAME(@ViewSchema), N'''', N'''''') + N''');';

IF @DryRun = 1
    SET @Output += N'USE ' + QUOTENAME(@TargetDb) + N';' + @NL + N'GO' + @NL + @NL
                 + @Inner + @NL + N'GO' + @NL + @NL;
ELSE
    EXEC @Proc @Inner;


/* ==================================================================================================================
   SECTION 6: CREATE THE LEAF ATTRIBUTE VIEWS
   ------------------------------------------------------------------------------------------------------------------
   Every column is cast to the data type it has in MDS, so downstream systems see exactly the same types. CREATE
   VIEW must be alone in its batch, so the drop and the create are run (and printed) separately.
   ================================================================================================================== */
DECLARE view_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.ViewName, QUOTENAME(e.TargetSchema) + N'.' + QUOTENAME(e.TargetTable)
    FROM #Views AS v
    JOIN #Ent   AS e ON e.EntityId = v.EntityId
    WHERE v.Supported = 1 AND v.FormatId = 1
    ORDER BY v.ViewName;

OPEN view_cur;
FETCH NEXT FROM view_cur INTO @ViewName, @Table;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @FullView = QUOTENAME(@ViewSchema) + N'.' + QUOTENAME(@ViewName);

    -- 6a. Make sure the name is not used by a table or another object
    SET @ObjType = NULL;
    EXEC @Proc N'SELECT @t = RTRIM(type) FROM sys.objects WHERE object_id = OBJECT_ID(@n);',
               N'@n nvarchar(400), @t nvarchar(10) OUTPUT', @n = @FullView, @t = @ObjType OUTPUT;

    IF @ObjType IS NOT NULL AND @ObjType <> N'V'
        SET @RptNotCreated += @NL + N'--   ' + @ViewName + N': the name ' + @FullView
                            + N' is already used by another object (type ' + @ObjType + N')';
    ELSE
    BEGIN
        -- 6b. Column list and joins
        SET @Select = STUFF((
            SELECT N',' + @NL + N'    CAST(' + ISNULL(Expr, N'NULL') + N' AS ' + TypeDef + N')'
                 + N' AS ' + QUOTENAME(ColumnName)
            FROM #ViewCols
            WHERE ViewName = @ViewName
            ORDER BY ColumnId
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

        SET @Joins = (
            SELECT @NL + JoinSql
            FROM #ViewCols
            WHERE ViewName = @ViewName AND JoinSql IS NOT NULL
            GROUP BY JoinSql
            ORDER BY JoinSql
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

        -- 6c. Drop and create
        SET @Inner = N'IF OBJECT_ID(N''' + REPLACE(@FullView, N'''', N'''''') + N''', N''V'') IS NOT NULL'
                   + N' DROP VIEW ' + @FullView + N';';

        SET @Sql = N'CREATE VIEW ' + @FullView + N'' + @NL
                 + N'AS' + @NL
                 + N'SELECT' + @NL
                 + @Select + @NL
                 + N'FROM ' + @Table + N' AS t' + ISNULL(@Joins, N'') + N';';

        IF @DryRun = 1
            SET @Output += N'-- ' + REPLICATE(N'-', 100) + @NL
                         + N'-- ' + @ViewName + N'  ->  ' + @Table + @NL
                         + N'-- ' + REPLICATE(N'-', 100) + @NL
                         + @Inner + @NL + N'GO' + @NL
                         + @Sql + @NL + N'GO' + @NL + @NL;
        ELSE
        BEGIN
            EXEC @Proc @Inner;
            EXEC @Proc @Sql;
        END;

        SET @RptCreated += @NL + N'--   ' + @FullView + N' on ' + @Table;
        SET @CntViews   += 1;
    END;

    FETCH NEXT FROM view_cur INTO @ViewName, @Table;
END;

CLOSE view_cur;
DEALLOCATE view_cur;


/* ==================================================================================================================
   SECTION 7: CREATE THE DERIVED HIERARCHY VIEWS
   ------------------------------------------------------------------------------------------------------------------
   A derived hierarchy is a chain of lookups, e.g. Product -> Sub-Category -> Category -> Product Group, so both
   formats are built from the migrated tables and the lookup columns:
   - Levels (format 8): one row per member of the bottom level, joined upwards level by level (L1 = bottom).
   - Parent-child (format 7): one SELECT per level, combined with UNION ALL. Each member is a child row with its
     parent from the level above; the top level gets the parent ROOT.
   As in MDS, a member is only included when it has a complete path to the top level: a member whose lookup to
   the level above is empty (and everything below it) is left out of both formats.
   ================================================================================================================== */
DECLARE hier_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.ViewName, v.FormatId, h.HierarchyId, h.Depth
    FROM #Views AS v
    JOIN #Hier  AS h ON h.HierarchyId = v.HierarchyId
    WHERE v.Supported = 1 AND v.FormatId IN (7, 8)
    ORDER BY v.ViewName;

OPEN hier_cur;
FETCH NEXT FROM hier_cur INTO @ViewName, @Format, @HierId, @Depth;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @FullView = QUOTENAME(@ViewSchema) + N'.' + QUOTENAME(@ViewName);

    -- 7a. Make sure the name is not used by a table or another object
    SET @ObjType = NULL;
    EXEC @Proc N'SELECT @t = RTRIM(type) FROM sys.objects WHERE object_id = OBJECT_ID(@n);',
               N'@n nvarchar(400), @t nvarchar(10) OUTPUT', @n = @FullView, @t = @ObjType OUTPUT;

    IF @ObjType IS NOT NULL AND @ObjType <> N'V'
        SET @RptNotCreated += @NL + N'--   ' + @ViewName + N': the name ' + @FullView
                            + N' is already used by another object (type ' + @ObjType + N')';
    ELSE
    BEGIN
        -- Bottom level table
        SELECT @Table = QUOTENAME(e.TargetSchema) + N'.' + QUOTENAME(e.TargetTable)
        FROM #HierLevels AS hl
        JOIN #Ent        AS e ON e.EntityId = hl.EntityId
        WHERE hl.HierarchyId = @HierId AND hl.LevelId = 1;

        IF @Format = 8
        BEGIN
            -- 7b. Levels: one row per bottom member with a complete path, joined upwards
            SET @Select = STUFF((
                SELECT N',' + @NL + N'    CAST(' + ISNULL(Expr, N'NULL') + N' AS ' + TypeDef + N')'
                     + N' AS ' + QUOTENAME(ColumnName)
                FROM #ViewCols
                WHERE ViewName = @ViewName
                ORDER BY ColumnId
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

            SET @Joins = (
                SELECT @NL + N'    JOIN ' + QUOTENAME(e.TargetSchema) + N'.' + QUOTENAME(e.TargetTable)
                     + N' AS ' + QUOTENAME(N'L' + CAST(hl.LevelId AS nvarchar(10)))
                     + N' ON ' + QUOTENAME(N'L' + CAST(hl.LevelId AS nvarchar(10))) + N'.' + QUOTENAME(@IdColumn)
                     + N' = ' + QUOTENAME(N'L' + CAST(hl.LevelId - 1 AS nvarchar(10))) + N'.'
                     + QUOTENAME(hl.LinkColumn)
                FROM #HierLevels AS hl
                JOIN #Ent        AS e ON e.EntityId = hl.EntityId
                WHERE hl.HierarchyId = @HierId AND hl.LevelId > 1
                ORDER BY hl.LevelId
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

            SET @Sql = N'CREATE VIEW ' + @FullView + @NL
                     + N'AS' + @NL
                     + N'SELECT' + @NL
                     + @Select + @NL
                     + N'FROM ' + @Table + N' AS [L1]' + ISNULL(@Joins, N'') + N';';
        END
        ELSE
        BEGIN
            -- 7c. Parent-child: one SELECT per level, from the top level down. Each level is joined upwards to the
            --     top level (as in 7b), so only members with a complete path to the top are included.
            SET @Union = N'';
            SET @Lvl   = @Depth;

            WHILE @Lvl >= 1
            BEGIN
                SELECT @Table = QUOTENAME(e.TargetSchema) + N'.' + QUOTENAME(e.TargetTable),
                       @ChildEnt = e.EntityId, @ChildEntName = e.EntityName
                FROM #HierLevels AS hl
                JOIN #Ent        AS e ON e.EntityId = hl.EntityId
                WHERE hl.HierarchyId = @HierId AND hl.LevelId = @Lvl;

                SELECT @ParEnt = NULL, @ParEntName = NULL;
                SELECT @ParEnt = e.EntityId, @ParEntName = e.EntityName
                FROM #HierLevels AS hl
                JOIN #Ent        AS e ON e.EntityId = hl.EntityId
                WHERE hl.HierarchyId = @HierId AND hl.LevelId = @Lvl + 1;

                SET @C = QUOTENAME(N'L' + CAST(@Lvl AS nvarchar(10)));       -- child alias
                SET @P = QUOTENAME(N'L' + CAST(@Lvl + 1 AS nvarchar(10)));   -- parent alias

                SET @Branch = STUFF((
                    SELECT N',' + @NL + N'    CAST('
                         + CASE vc.ColumnName
                               WHEN N'ChildType_ID'      THEN N'1'
                               WHEN N'Child_ID'          THEN @C + N'.' + QUOTENAME(@IdColumn)
                               WHEN N'ChildCode'         THEN @C + N'.[Code]'
                               WHEN N'ChildName'         THEN @C + N'.[Name]'
                               WHEN N'Child_Entity_ID'   THEN CAST(@ChildEnt AS nvarchar(10))
                               WHEN N'Child_EntityName'  THEN N'N''' + REPLACE(@ChildEntName, N'''', N'''''') + N''''
                               WHEN N'ParentType_ID'     THEN CASE WHEN @Lvl = @Depth THEN N'2' ELSE N'1' END
                               WHEN N'Parent_ID'         THEN CASE WHEN @Lvl = @Depth THEN N'0'
                                                                   ELSE @P + N'.' + QUOTENAME(@IdColumn) END
                               WHEN N'ParentCode'        THEN CASE WHEN @Lvl = @Depth THEN N'N''ROOT'''
                                                                   ELSE @P + N'.[Code]' END
                               WHEN N'ParentName'        THEN CASE WHEN @Lvl = @Depth THEN N'N'''''
                                                                   ELSE @P + N'.[Name]' END
                               WHEN N'Parent_Entity_ID'  THEN CASE WHEN @Lvl = @Depth THEN N'NULL'
                                                                   ELSE CAST(@ParEnt AS nvarchar(10)) END
                               WHEN N'Parent_EntityName' THEN CASE WHEN @Lvl = @Depth THEN N'NULL'
                                                                   ELSE N'N''' + REPLACE(@ParEntName, N'''', N'''''')
                                                                        + N'''' END
                               ELSE ISNULL(vc.Expr, N'NULL')
                           END
                         + N' AS ' + vc.TypeDef + N') AS ' + QUOTENAME(vc.ColumnName)
                    FROM #ViewCols AS vc
                    WHERE vc.ViewName = @ViewName
                    ORDER BY vc.ColumnId
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'');

                -- Joins from this level up to the top level
                SET @Joins = (
                    SELECT @NL + N'    JOIN ' + QUOTENAME(e.TargetSchema) + N'.' + QUOTENAME(e.TargetTable)
                         + N' AS ' + QUOTENAME(N'L' + CAST(hl.LevelId AS nvarchar(10)))
                         + N' ON ' + QUOTENAME(N'L' + CAST(hl.LevelId AS nvarchar(10))) + N'.' + QUOTENAME(@IdColumn)
                         + N' = ' + QUOTENAME(N'L' + CAST(hl.LevelId - 1 AS nvarchar(10))) + N'.'
                         + QUOTENAME(hl.LinkColumn)
                    FROM #HierLevels AS hl
                    JOIN #Ent        AS e ON e.EntityId = hl.EntityId
                    WHERE hl.HierarchyId = @HierId AND hl.LevelId > @Lvl
                    ORDER BY hl.LevelId
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)');

                SET @Union += CASE WHEN @Union = N'' THEN N'' ELSE @NL + N'UNION ALL' + @NL END
                            + N'-- Level ' + CAST(@Lvl AS nvarchar(10)) + N': ' + @ChildEntName + @NL
                            + N'SELECT' + @NL + @Branch + @NL
                            + N'FROM ' + @Table + N' AS ' + @C + ISNULL(@Joins, N'');

                SET @Lvl -= 1;
            END;

            SET @Sql = N'CREATE VIEW ' + @FullView + @NL
                     + N'AS' + @NL
                     + @Union + N';';
        END;

        -- 7d. Drop and create
        SET @Inner = N'IF OBJECT_ID(N''' + REPLACE(@FullView, N'''', N'''''') + N''', N''V'') IS NOT NULL'
                   + N' DROP VIEW ' + @FullView + N';';

        IF @DryRun = 1
            SET @Output += N'-- ' + REPLICATE(N'-', 100) + @NL
                         + N'-- ' + @ViewName + N'  ->  derived hierarchy, '
                         + CASE @Format WHEN 8 THEN N'levels' ELSE N'parent-child' END + @NL
                         + N'-- ' + REPLICATE(N'-', 100) + @NL
                         + @Inner + @NL + N'GO' + @NL
                         + @Sql + @NL + N'GO' + @NL + @NL;
        ELSE
        BEGIN
            EXEC @Proc @Inner;
            EXEC @Proc @Sql;
        END;

        SET @RptCreated += @NL + N'--   ' + @FullView + N' (derived hierarchy, '
                         + CASE @Format WHEN 8 THEN N'levels' ELSE N'parent-child' END + N')';
        SET @CntViews   += 1;
    END;

    FETCH NEXT FROM hier_cur INTO @ViewName, @Format, @HierId, @Depth;
END;

CLOSE hier_cur;
DEALLOCATE hier_cur;


/* ==================================================================================================================
   SECTION 8: COMPARE ROW COUNTS WITH MDS (execute mode only)
   ------------------------------------------------------------------------------------------------------------------
   Differences are expected when a view is bound to another version than the one migrated, or when data has been
   changed in either database since step 1 was run.
   ================================================================================================================== */
IF @DryRun = 0
BEGIN
    SET @ErrorList = N'';

    DECLARE cmp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ViewName FROM #Views WHERE Supported = 1 ORDER BY ViewName;

    OPEN cmp_cur;
    FETCH NEXT FROM cmp_cur INTO @ViewName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @CountMds = NULL, @CountNew = NULL;
        SET @Sql = N'SELECT @c = COUNT_BIG(*) FROM ' + @Src + N'.mdm.' + QUOTENAME(@ViewName) + N';';
        EXEC sys.sp_executesql @Sql, N'@c bigint OUTPUT', @c = @CountMds OUTPUT;

        IF OBJECT_ID(QUOTENAME(@TargetDb) + N'.' + QUOTENAME(@ViewSchema) + N'.' + QUOTENAME(@ViewName)) IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @c = COUNT_BIG(*) FROM ' + QUOTENAME(@TargetDb) + N'.' + QUOTENAME(@ViewSchema)
                     + N'.' + QUOTENAME(@ViewName) + N';';
            EXEC sys.sp_executesql @Sql, N'@c bigint OUTPUT', @c = @CountNew OUTPUT;
        END;

        SET @ErrorList += @NL + N'--   ' + LEFT(@ViewName + REPLICATE(N' ', 50), 50)
                        + N' MDS: ' + LEFT(ISNULL(CAST(@CountMds AS nvarchar(20)), N'-') + REPLICATE(N' ', 10), 10)
                        + N' new: ' + ISNULL(CAST(@CountNew AS nvarchar(20)), N'-')
                        + CASE WHEN ISNULL(@CountMds, -1) = ISNULL(@CountNew, -2) THEN N'' ELSE N'   <-- differs' END;

        FETCH NEXT FROM cmp_cur INTO @ViewName;
    END;

    CLOSE cmp_cur;
    DEALLOCATE cmp_cur;

    SET @RptCounts = @ErrorList;
END;


/* ==================================================================================================================
   SECTION 9: PRINT THE GENERATED SQL (dry-run mode only) AND THE REPORT
   ------------------------------------------------------------------------------------------------------------------
   PRINT cuts text off at 4000 characters, so everything is printed line by line instead.
   ================================================================================================================== */
SET @Report =
      N'-- ' + CAST(@CntViews AS nvarchar(10))
    + CASE WHEN @DryRun = 1 THEN N' Views Generated (dry run, nothing created):' ELSE N' Views Created:' END
    + @RptCreated + @NL
    + CASE WHEN @RptCounts <> N'' THEN @NL + N'-- Row counts:' + @RptCounts + @NL ELSE N'' END
    + CASE WHEN @RptNotCreated <> N'' THEN @NL + N'-- Views not created:' + @RptNotCreated + @NL ELSE N'' END
    + ISNULL(@NL + N'-- Columns without a source (returned as NULL):' + @RptUnmapped + @NL, N'')
    + ISNULL(@NL + N'-- WARNING: views bound to another version than the one migrated (the data will differ):'
             + @RptVersion + @NL, N'')
    + @NL + N'-- Done.';

SET @Output = CASE WHEN @DryRun = 1 THEN @Output ELSE N'' END + @Report;
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
