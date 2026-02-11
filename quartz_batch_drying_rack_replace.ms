/*
    Quartz Workstation Batch Drying Rack Replacer
    ---------------------------------------------
    Production-safe MaxScript to recursively process .max files,
    back up each file, replace DR1713 rack hierarchy with a new FBX,
    align replacement to old rack center/transform, and assign rack
    material from a drying-rack material library using finish token.
*/

global ROOT_DIR = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt"
global BACKUP_DIR = @"C:\Users\AHealy\Desktop\Backup"

global DRYING_RACK_FBX_PATH = @"C:\Users\AHealy\Desktop\Accessories\Drying_Rack.fbx"
global DRYING_RACK_MATLIB_PATH = @"R:\Creative\3D Library\3D Library\Material Library\Drying Racks.mat"

global FINISH_TO_RACK_MAT = #(
    #("BI", "Bisque"),
    #("BL", "Black"),
    #("BR", "Light brown"),
    #("CN", "Light Grey #1"),
    #("GR", "Dark Grey"),
    #("WH", "White_Rubber")
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
    if (doesDirectoryExist rootPath) == false then return found

    local dirQueue = #(rootPath)
    local idx = 1

    while idx <= dirQueue.count do
    (
        local dir = dirQueue[idx]
        idx += 1

        local maxFiles = getFiles (dir + "\\*.max")
        for f in maxFiles do append found f

        local subDirs = getDirectories (dir + "\\*")
        for d in subDirs do append dirQueue d
    )

    found
)

fn sortStringArray arr =
(
    sort arr
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

fn makeBackupSourceToRoot srcFile rootDir backupRoot =
(
    local rel = getRelativePathAbs srcFile rootDir
    if rel == undefined then
    (
        logWarn ("Could not compute relative path for backup: " + srcFile)
        return undefined
    )

    local relDir = getFilenamePath rel
    local relFileName = getFilenameFile rel + getFilenameType rel

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

    local backupFile = backupFolder + relFileName
    if doesFileExist backupFile do
    (
        logWarn ("Backup file already exists and will be overwritten: " + backupFile)
        deleteFile backupFile
    )

    local copyOk = copyFile srcFile backupFile
    if copyOk then backupFile else undefined
)

/* ------------------------------ Scene Utils ---------------------------- */
fn collectAllSceneNodes =
(
    local allNodes = #()
    local queue = #()

    for topNode in rootNode.children do append queue topNode

    local idx = 1
    while idx <= queue.count do
    (
        local n = queue[idx]
        idx += 1
        append allNodes n

        for c in n.children do append queue c
    )

    allNodes
)

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

fn getFinishTokenFromFilePath filePath =
(
    local nameOnly = getFilenameFile filePath
    local parts = filterString nameOnly "-"
    if parts.count >= 3 then (toUpper parts[3]) else undefined
)

fn rackMaterialNameForFinish token =
(
    if token == undefined then return undefined
    local lookup = toUpper token

    for pair in FINISH_TO_RACK_MAT where pair.count == 2 do
    (
        if (toUpper pair[1]) == lookup then return pair[2]
    )

    undefined
)

fn loadRackMaterialLibrary matlibPath =
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

fn collectRackRootNodes =
(
    local roots = #()
    local allNodes = collectAllSceneNodes()

    for n in allNodes do
    (
        if (toUpper n.name) == "DR1713" then append roots n
    )

    roots
)

fn getNodesBoundsCenter nodes =
(
    if nodes.count == 0 then return [0,0,0]

    local minP = [1e9,1e9,1e9]
    local maxP = [-1e9,-1e9,-1e9]

    for n in nodes do
    (
        local bb = nodeGetBoundingBox n n.transform
        if bb != undefined and bb.count == 2 do
        (
            local bmin = bb[1]
            local bmax = bb[2]

            if bmin.x < minP.x then minP.x = bmin.x
            if bmin.y < minP.y then minP.y = bmin.y
            if bmin.z < minP.z then minP.z = bmin.z

            if bmax.x > maxP.x then maxP.x = bmax.x
            if bmax.y > maxP.y then maxP.y = bmax.y
            if bmax.z > maxP.z then maxP.z = bmax.z
        )
    )

    (minP + maxP) / 2.0
)

fn buildHandleArray nodes =
(
    local handles = #()
    for n in nodes where n != undefined do append handles (getHandleByAnim n)
    handles
)

fn isHandleInArray handleVal handles =
(
    findItem handles handleVal > 0
)

fn collectTopRootsFromSet nodes =
(
    local roots = #()
    local handles = buildHandleArray nodes

    for n in nodes do
    (
        local p = n.parent
        local parentInSet = false
        if p != undefined do parentInSet = isHandleInArray (getHandleByAnim p) handles
        if not parentInSet then append roots n
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

fn replaceRackHierarchyWithFbx rackRoot rackFbxPath rackMaterial =
(
    local result = #(false, 0, 0, "") -- #(ok, importedCount, matAssignedCount, message)

    if rackRoot == undefined then
    (
        result[4] = "Rack root undefined."
        return result
    )

    local oldTransform = rackRoot.transform
    local oldCenter = getNodesBoundsCenter #(rackRoot)

    local beforeNodes = collectAllSceneNodes()
    local beforeHandles = buildHandleArray beforeNodes

    try
    (
        delete rackRoot
    )
    catch
    (
        result[4] = "Failed deleting existing DR1713 hierarchy."
        return result
    )

    try
    (
        importFile rackFbxPath #noPrompt using:FBXIMP
    )
    catch
    (
        result[4] = "Failed importing FBX replacement."
        return result
    )

    local afterNodes = collectAllSceneNodes()
    local importedNodes = #()

    for n in afterNodes do
    (
        local h = getHandleByAnim n
        if (not isHandleInArray h beforeHandles) then append importedNodes n
    )

    if importedNodes.count == 0 then
    (
        result[4] = "No imported nodes detected after FBX import."
        return result
    )

    local importedRoots = collectTopRootsFromSet importedNodes
    local importedCenter = getNodesBoundsCenter importedRoots
    local delta = oldCenter - importedCenter

    for r in importedRoots do r.pos += delta

    if importedRoots.count == 1 do
    (
        importedRoots[1].rotation = oldTransform.rotation
    )

    local matStats = #(0, 0)
    if rackMaterial != undefined then
    (
        local replacementMat = copy rackMaterial
        replacementMat.name = rackMaterial.name
        for r in importedRoots do assignMaterialRecursive r replacementMat matStats
    )

    result[1] = true
    result[2] = importedNodes.count
    result[3] = matStats[1]
    result[4] = "Replacement imported and aligned."
    result
)

/* ------------------------------ Processing ----------------------------- */
fn processMaxFile filePath rackMatLib =
(
    local result = #("failed", "") -- #(status, message)

    local finishToken = getFinishTokenFromFilePath filePath
    if finishToken == undefined then
    (
        result[1] = "skipped"
        result[2] = "Missing finish token (expected 3rd '-' token)."
        return result
    )

    local rackMatName = rackMaterialNameForFinish finishToken
    if rackMatName == undefined then
    (
        result[1] = "skipped"
        result[2] = "No drying rack material mapping for token: " + finishToken
        return result
    )

    local rackMat = getMaterialByNameFromLibrary rackMatLib rackMatName
    if rackMat == undefined then
    (
        result[1] = "skipped"
        result[2] = "Rack material not found in library: " + rackMatName
        return result
    )

    local backupFile = makeBackupSourceToRoot filePath ROOT_DIR BACKUP_DIR
    if backupFile == undefined then
    (
        result[1] = "failed"
        result[2] = "Backup failed. File not modified."
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
            result[2] = "Could not load file."
            resetMaxFile #noPrompt
            return result
        )

        local rackRoots = collectRackRootNodes()
        if rackRoots.count == 0 then
        (
            result[1] = "skipped"
            result[2] = "No DR1713 root nodes found."
            resetMaxFile #noPrompt
            return result
        )

        local replacedCount = 0
        local importedTotal = 0
        local matAssignedTotal = 0
        local failures = 0

        for rr in rackRoots do
        (
            local rrResult = replaceRackHierarchyWithFbx rr DRYING_RACK_FBX_PATH rackMat
            if rrResult[1] then
            (
                replacedCount += 1
                importedTotal += rrResult[2]
                matAssignedTotal += rrResult[3]
            )
            else
            (
                failures += 1
                logWarn ("Rack replacement failed for one root: " + rrResult[4])
            )
        )

        if replacedCount == 0 then
        (
            result[1] = "failed"
            result[2] = "No DR1713 roots were replaced successfully."
            resetMaxFile #noPrompt
            return result
        )

        local saved = saveMaxFile filePath quiet:true
        if not saved then
        (
            result[1] = "failed"
            result[2] = "Save failed after replacement."
            resetMaxFile #noPrompt
            return result
        )

        result[1] = if failures > 0 then "failed" else "success"
        result[2] = "Finish=" + finishToken + ", Mat=" + rackMatName + ", Replaced=" + (replacedCount as string) + ", ImportNodes=" + (importedTotal as string) + ", MatAssigned=" + (matAssignedTotal as string) + ", ReplaceFailures=" + (failures as string)

        resetMaxFile #noPrompt
        result
    )
    catch
    (
        result[1] = "failed"
        result[2] = "Unhandled exception while processing file."
        try (resetMaxFile #noPrompt) catch()
        result
    )
)

/* --------------------------------- Main -------------------------------- */
fn runQuartzBatchRackReplacement =
(
    logInfo "================ Quartz Batch DR1713 Replacement: START ================"
    logInfo ("ROOT_DIR             : " + ROOT_DIR)
    logInfo ("BACKUP_DIR           : " + BACKUP_DIR)
    logInfo ("DRYING_RACK_FBX_PATH : " + DRYING_RACK_FBX_PATH)
    logInfo ("RACK_MATLIB_PATH     : " + DRYING_RACK_MATLIB_PATH)

    if (doesDirectoryExist ROOT_DIR) == false then
    (
        logError ("ROOT_DIR does not exist: " + ROOT_DIR)
        return false
    )

    if (doesFileExist DRYING_RACK_FBX_PATH) == false then
    (
        logError ("DRYING_RACK_FBX_PATH does not exist: " + DRYING_RACK_FBX_PATH)
        return false
    )

    if (doesFileExist DRYING_RACK_MATLIB_PATH) == false then
    (
        logError ("DRYING_RACK_MATLIB_PATH does not exist: " + DRYING_RACK_MATLIB_PATH)
        return false
    )

    if (ensureDir BACKUP_DIR) == false then
    (
        logError ("Unable to create/access BACKUP_DIR: " + BACKUP_DIR)
        return false
    )

    local rackMatLib = loadRackMaterialLibrary DRYING_RACK_MATLIB_PATH
    if rackMatLib == undefined then
    (
        logError ("Failed to load drying rack material library: " + DRYING_RACK_MATLIB_PATH)
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

        local r = processMaxFile f rackMatLib

        case r[1] of
        (
            "success":
            (
                successCount += 1
                logInfo ("SUCCESS | " + r[2])
            )
            "skipped":
            (
                skippedCount += 1
                logWarn ("SKIPPED | " + r[2])
            )
            default:
            (
                failedCount += 1
                logError ("FAILED  | " + r[2])
            )
        )

        gc light:true
    )

    logInfo "================ Quartz Batch DR1713 Replacement: SUMMARY ================"
    logInfo ("Total Files: " + (files.count as string))
    logInfo ("Succeeded  : " + (successCount as string))
    logInfo ("Skipped    : " + (skippedCount as string))
    logInfo ("Failed     : " + (failedCount as string))
    logInfo "================ Quartz Batch DR1713 Replacement: END ====================="

    (failedCount == 0)
)

runQuartzBatchRackReplacement()
