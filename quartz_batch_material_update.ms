/*
    Quartz Workstation Sink Batch Material Updater
    ------------------------------------------------
    Production-safe MaxScript for recursively processing .max files,
    replacing sink-related materials from a material library based on
    finish token in filename, with backup + logging + summary.
*/

global ROOT_DIR   = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt"
global MATLIB_PATH = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
global BACKUP_DIR = @"C:\Users\AHealy\Desktop\Backup"

/* Token => Material Name mapping (exact names from Quartz.mat) */
global FINISH_TO_MAT = #(
    #("BI", "Bisque_Quartz_02"),
    #("BL", "Black_Quartz"),
    #("BR", "Brown_Quartz_02"),
    #("CN", "Concrete_Quartz_02"),
    #("GR", "Grey_Quartz_02"),
    #("WH", "White_Quartz")
)

/* ------------------------------- Logging ------------------------------- */
fn logInfo msg = format "[%] [INFO] %\n" (localTime as string) msg
fn logWarn msg = format "[%] [WARN] %\n" (localTime as string) msg
fn logError msg = format "[%] [ERROR] %\n" (localTime as string) msg

/* --------------------------- Filesystem Utils -------------------------- */
fn ensureDir dirPath =
(
    if doesFileExist dirPath then return true
    if doesDirectoryExist dirPath then return true
    makeDir dirPath
    doesDirectoryExist dirPath
)

fn collectMaxFilesRecursive rootPath =
(
    local found = #()

    fn walk dir acc =
    (
        local maxFiles = getFiles (dir + "\\*.max")
        for f in maxFiles do append acc f

        local subDirs = getDirectories (dir + "\\*")
        for d in subDirs do walk d acc
    )

    if doesDirectoryExist rootPath then walk rootPath found
    found
)

fn sortStringArray arr =
(
    qsort arr (fn a b = (toLower a) < (toLower b))
    arr
)

fn getRelativePathAbs fullPath rootPath =
(
    local p = pathConfig.convertPathToUnc fullPath
    local r = pathConfig.convertPathToUnc rootPath

    if matchPattern (toLower p) pattern:((toLower r) + "\\*") then
    (
        substring p (r.count + 2) (p.count - r.count - 1)
    )
    else undefined
)

fn timestampString =
(
    local t = localTime
    (formattedPrint t.year format:"04d") +
    (formattedPrint t.month format:"02d") +
    (formattedPrint t.day format:"02d") + "_" +
    (formattedPrint t.hour format:"02d") +
    (formattedPrint t.minute format:"02d") +
    (formattedPrint t.second format:"02d")
)

fn makeBackupSourceToRoot srcFile rootDir backupRoot =
(
    local rel = getRelativePathAbs srcFile rootDir
    if rel == undefined then
    (
        logWarn ("Could not compute relative path for backup: " + srcFile)
        return undefined
    )

    local relDir = getFilenamePath rel
    local baseName = getFilenameFile rel
    local ext = getFilenameType rel

    local backupFolder = backupRoot + "\\" + relDir
    if (ensureDir backupRoot) == false then
    (
        logError ("Failed to ensure backup root: " + backupRoot)
        return undefined
    )

    if relDir != "" do
    (
        if (ensureDir backupFolder) == false then
        (
            logError ("Failed to ensure backup folder: " + backupFolder)
            return undefined
        )
    )

    local backupFile = backupFolder + baseName + "_bak_" + (timestampString()) + ext
    local copyOk = copyFile srcFile backupFile
    if copyOk then backupFile else undefined
)

/* --------------------------- Material Mapping -------------------------- */
fn getFinishTokenFromFilePath filePath =
(
    local nameOnly = getFilenameFile filePath
    local parts = filterString nameOnly "-"
    if parts.count >= 3 then (toUpper parts[3]) else undefined
)

fn materialNameForToken token =
(
    if token == undefined then return undefined
    local lookup = toUpper token
    for pair in FINISH_TO_MAT where pair.count == 2 do
    (
        if (toUpper pair[1]) == lookup then return pair[2]
    )
    undefined
)

fn loadQuartzMaterialLibrary matlibPath =
(
    if doesFileExist matlibPath then
    (
        local lib = loadTempMaterialLibrary matlibPath
        if lib != undefined and lib.count > 0 then lib else undefined
    )
    else undefined
)

fn getMaterialByNameFromLibrary lib materialName =
(
    if lib == undefined or materialName == undefined then return undefined
    for i = 1 to lib.count do
    (
        local m = lib[i]
        if m != undefined and (toLower m.name) == (toLower materialName) then return m
    )
    undefined
)

/* ---------------------------- Node Detection --------------------------- */
fn nodeNameStartsWithAny nodeName prefixes =
(
    local n = toUpper nodeName
    for p in prefixes do
    (
        local pu = toUpper p
        if n.count >= pu.count and (substring n 1 pu.count) == pu then return true
    )
    false
)

fn isSinkRootNode node =
(
    if node == undefined then return false
    nodeNameStartsWithAny node.name #("QARWS", "COL", "QBS")
)

fn hasSinkRootAncestor node =
(
    local p = node.parent
    while p != undefined do
    (
        if isSinkRootNode p then return true
        p = p.parent
    )
    false
)

fn collectSinkRootNodes =
(
    local roots = #()
    for n in objects do
    (
        if isSinkRootNode n and (not hasSinkRootAncestor n) then append roots n
    )
    roots
)

fn assignMaterialRecursive node newMat stats =
(
    if node == undefined or newMat == undefined then return false

    local assigned = true
    try
    (
        node.material = newMat
        stats[1] += 1
    )
    catch
    (
        assigned = false
        stats[2] += 1
        logWarn ("Failed material assignment on node: " + node.name)
    )

    for c in node.children do assignMaterialRecursive c newMat stats
    assigned
)

/* ------------------------------ Processing ----------------------------- */
fn processMaxFile filePath matLib =
(
    local result = #("failed", 0, 0, "")
    local finishToken = getFinishTokenFromFilePath filePath
    if finishToken == undefined then
    (
        result[1] = "skipped"
        result[4] = "Missing finish token (expected 3rd '-' token)."
        return result
    )

    local matName = materialNameForToken finishToken
    if matName == undefined then
    (
        result[1] = "skipped"
        result[4] = "No material mapping for token: " + finishToken
        return result
    )

    local sourceMat = getMaterialByNameFromLibrary matLib matName
    if sourceMat == undefined then
    (
        result[1] = "skipped"
        result[4] = "Material not found in library: " + matName
        return result
    )

    local backupFile = makeBackupSourceToRoot filePath ROOT_DIR BACKUP_DIR
    if backupFile == undefined then
    (
        result[1] = "failed"
        result[4] = "Backup failed. File not modified."
        return result
    )

    logInfo ("Backup created: " + backupFile)

    try
    (
        resetMaxFile #noPrompt

        local loaded = loadMaxFile filePath useFileUnits:true quiet:true
        if not loaded then
        (
            result[1] = "failed"
            result[4] = "Could not load file."
            resetMaxFile #noPrompt
            return result
        )

        local replacementMat = copy sourceMat
        replacementMat.name = sourceMat.name

        local roots = collectSinkRootNodes()
        if roots.count == 0 then
        (
            result[1] = "skipped"
            result[4] = "No sink root nodes found (QARWS/COL/QBS)."
            resetMaxFile #noPrompt
            return result
        )

        local stats = #(0, 0) -- #(assignedCount, assignmentErrors)
        for r in roots do assignMaterialRecursive r replacementMat stats

        local saved = saveMaxFile filePath quiet:true
        if not saved then
        (
            result[1] = "failed"
            result[4] = "Save failed after assignment."
            resetMaxFile #noPrompt
            return result
        )

        result[1] = "success"
        result[2] = stats[1]
        result[3] = stats[2]
        result[4] = "Token=" + finishToken + ", Material=" + matName + ", Roots=" + (roots.count as string)

        resetMaxFile #noPrompt
        result
    )
    catch
    (
        result[1] = "failed"
        result[4] = "Unhandled exception while processing file."
        try (resetMaxFile #noPrompt) catch()
        result
    )
)

/* --------------------------------- Main -------------------------------- */
fn runQuartzBatchUpdate =
(
    logInfo "================ Quartz Batch Material Update: START ================"
    logInfo ("ROOT_DIR   : " + ROOT_DIR)
    logInfo ("MATLIB_PATH: " + MATLIB_PATH)
    logInfo ("BACKUP_DIR : " + BACKUP_DIR)

    if (doesDirectoryExist ROOT_DIR) == false then
    (
        logError ("ROOT_DIR does not exist: " + ROOT_DIR)
        return false
    )

    if (doesFileExist MATLIB_PATH) == false then
    (
        logError ("MATLIB_PATH does not exist: " + MATLIB_PATH)
        return false
    )

    if (ensureDir BACKUP_DIR) == false then
    (
        logError ("Unable to create/access BACKUP_DIR: " + BACKUP_DIR)
        return false
    )

    local matLib = loadQuartzMaterialLibrary MATLIB_PATH
    if matLib == undefined then
    (
        logError ("Failed to load material library: " + MATLIB_PATH)
        return false
    )

    local files = collectMaxFilesRecursive ROOT_DIR
    sortStringArray files

    if files.count == 0 then
    (
        logWarn "No .max files found under ROOT_DIR."
        return true
    )

    logInfo ((files.count as string) + " file(s) discovered.")

    local successCount = 0
    local skippedCount = 0
    local failedCount = 0

    for i = 1 to files.count do
    (
        local f = files[i]
        logInfo ("---------------------------------------------------------------")
        logInfo ((i as string) + "/" + (files.count as string) + " Processing: " + f)

        local r = processMaxFile f matLib
        local status = r[1]

        case status of
        (
            "success":
            (
                successCount += 1
                logInfo ("SUCCESS | " + r[4] + " | Assigned=" + (r[2] as string) + " | AssignErrors=" + (r[3] as string))
            )
            "skipped":
            (
                skippedCount += 1
                logWarn ("SKIPPED | " + r[4])
            )
            default:
            (
                failedCount += 1
                logError ("FAILED  | " + r[4])
            )
        )

        gc light:true
    )

    logInfo "================ Quartz Batch Material Update: SUMMARY ================"
    logInfo ("Total Files: " + (files.count as string))
    logInfo ("Succeeded  : " + (successCount as string))
    logInfo ("Skipped    : " + (skippedCount as string))
    logInfo ("Failed     : " + (failedCount as string))
    logInfo "================ Quartz Batch Material Update: END ===================="

    (failedCount == 0)
)

/* Execute */
runQuartzBatchUpdate()
