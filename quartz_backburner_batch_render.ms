/*
    Quartz Workstation Batch Backburner Submitter
    --------------------------------------------
    Loads each source .max sink file into a lighting/camera sample scene,
    prepares per-camera variants, and submits render jobs to Backburner.

    Cameras:
      - IPS01
      - IPS02
      - IPS03 (hides CB/DR/COL content)
      - IPS04

    Output name format:
      KCL_144_IPS#_Quartz-Workstation-Refresh_SKUFINISH

    IMPORTANT:
      - Uses cmdjob + 3dsmaxcmd submission pattern.
      - Verify executable paths and command-line flags in your environment.
*/

global ROOT_DIR = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt"
global SAMPLE_SCENE_PATH = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt\_Render_Template\Quartz_Sample_Lighting.max"
global OUTPUT_DIR = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt\_Renders"
global TEMP_SCENE_DIR = @"C:\Users\AHealy\Desktop\Quartz_Workstation_Opt\_TempRenderScenes"

global BACKBURNER_MANAGER_IP = "10.10.0.59"
global CMDJOB_EXE = @"C:\Program Files (x86)\Autodesk\Backburner\cmdjob.exe"
global MAXCMD_EXE = @"C:\Program Files\Autodesk\3ds Max 2024\3dsmaxcmd.exe"

global RENDER_CAMERAS = #("IPS01", "IPS02", "IPS03", "IPS04")
global IPS03_HIDE_PREFIXES = #("CB", "DR", "COL")

global FINISH_LABEL_MAP = #(
    #("BI", "Bisque"),
    #("BL", "Black"),
    #("BR", "Brown"),
    #("CN", "Concrete"),
    #("GR", "Grey"),
    #("WH", "White")
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

fn sanitizeLabel rawText =
(
    if rawText == undefined then return "Unknown"
    local s = rawText as string
    s = substituteString s " " ""
    s = substituteString s "-" ""
    s = substituteString s "_" ""
    s = substituteString s "." ""
    s
)

/* ------------------------- Naming/Token Helpers ------------------------ */
fn getNameTokens filePath =
(
    local nameOnly = getFilenameFile filePath
    filterString nameOnly "-"
)

fn getSinkPrefixFromFilePath filePath =
(
    local parts = getNameTokens filePath
    if parts.count >= 1 then toUpper parts[1] else undefined
)

fn getFinishTokenFromFilePath filePath =
(
    local parts = getNameTokens filePath
    if parts.count >= 3 then toUpper parts[3] else undefined
)

fn finishLabelForToken token =
(
    if token == undefined then return "UnknownFinish"
    local lookup = toUpper token

    for pair in FINISH_LABEL_MAP where pair.count == 2 do
    (
        if (toUpper pair[1]) == lookup then return pair[2]
    )

    token
)

fn getSkuFinishLabel filePath =
(
    local baseName = getFilenameFile filePath
    local finishToken = getFinishTokenFromFilePath filePath
    local finishLabel = finishLabelForToken finishToken

    local compactBase = sanitizeLabel baseName
    local compactFinish = sanitizeLabel finishLabel

    -- preferred label by your convention family
    compactBase + compactFinish
)

fn buildRenderName cameraName skuFinishLabel =
(
    "KCL_144_" + cameraName + "_Quartz-Workstation-Refresh_" + skuFinishLabel
)

/* ---------------------------- Scene Helpers ---------------------------- */
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

fn setAllNodesVisibleByPrefix prefixes visibleState =
(
    local allNodes = collectAllSceneNodes()
    local countChanged = 0

    for n in allNodes do
    (
        if nodeNameStartsWithAny n.name prefixes then
        (
            try
            (
                n.isHidden = not visibleState
                countChanged += 1
            )
            catch
            (
                logWarn ("Failed visibility update on node: " + n.name)
            )
        )
    )

    countChanged
)

fn setIps03VisibilityRules =
(
    local hiddenCount = setAllNodesVisibleByPrefix IPS03_HIDE_PREFIXES false
    logInfo ("IPS03 visibility rule applied. Hidden nodes matched by CB/DR/COL prefixes: " + (hiddenCount as string))
)

fn setNonIps03VisibilityRules =
(
    local shownCount = setAllNodesVisibleByPrefix IPS03_HIDE_PREFIXES true
    logInfo ("Standard visibility rule applied. Restored CB/DR/COL nodes: " + (shownCount as string))
)

fn getCameraNodeByName camName =
(
    local n = getNodeByName camName exact:true ignoreCase:true all:false
    n
)

/* -------------------------- Backburner Submit -------------------------- */
fn quoteArg txt = ("\"" + txt + "\"")

fn buildCmdJobSubmissionCommand jobName sceneFile cameraName outputFile =
(
    local cmd = ""
    cmd += quoteArg CMDJOB_EXE
    cmd += " -manager " + BACKBURNER_MANAGER_IP
    cmd += " -jobName " + quoteArg jobName
    cmd += " " + quoteArg MAXCMD_EXE
    cmd += " " + quoteArg sceneFile
    cmd += " -camera " + quoteArg cameraName
    cmd += " -o " + quoteArg outputFile
    cmd += " -frames 0"
    cmd
)

fn submitSceneToBackburner jobName sceneFile cameraName outputFile =
(
    if (doesFileExist CMDJOB_EXE) == false then
    (
        logError ("cmdjob.exe not found: " + CMDJOB_EXE)
        return false
    )

    if (doesFileExist MAXCMD_EXE) == false then
    (
        logError ("3dsmaxcmd.exe not found: " + MAXCMD_EXE)
        return false
    )

    local submitCmd = buildCmdJobSubmissionCommand jobName sceneFile cameraName outputFile
    logInfo ("Submitting Backburner job: " + submitCmd)

    local exitCode = -1
    try
    (
        exitCode = hiddenDOSCommand submitCmd startpath:(getFilenamePath CMDJOB_EXE)
    )
    catch
    (
        logError ("Failed executing submission command for: " + jobName)
        return false
    )

    if exitCode == 0 then
    (
        logInfo ("Backburner submission succeeded: " + jobName)
        true
    )
    else
    (
        logError ("Backburner submission failed (exit code " + (exitCode as string) + "): " + jobName)
        false
    )
)

/* ------------------------------- Pipeline ------------------------------ */
fn prepareAndSubmitPerCamera sourceFile =
(
    local result = #(0, 0) -- #(submitted, failed)

    local sinkPrefix = getSinkPrefixFromFilePath sourceFile
    local finishToken = getFinishTokenFromFilePath sourceFile
    local skuFinishLabel = getSkuFinishLabel sourceFile

    if sinkPrefix == undefined then
    (
        logWarn ("Skipping (missing sink prefix token): " + sourceFile)
        return result
    )

    if finishToken == undefined then
    (
        logWarn ("Skipping (missing finish token): " + sourceFile)
        return result
    )

    if (doesFileExist SAMPLE_SCENE_PATH) == false then
    (
        logError ("Sample scene not found: " + SAMPLE_SCENE_PATH)
        return result
    )

    resetMaxFile #noPrompt

    local loadedSample = loadMaxFile SAMPLE_SCENE_PATH useFileUnits:true quiet:true
    if not loadedSample then
    (
        logError ("Could not load sample scene: " + SAMPLE_SCENE_PATH)
        return result
    )

    try
    (
        mergeMAXFile sourceFile #autoRenameDups #useSceneMtlDups #neverReparent
    )
    catch
    (
        logError ("Merge failed: " + sourceFile)
        return result
    )

    for camName in RENDER_CAMERAS do
    (
        local camNode = getCameraNodeByName camName
        if camNode == undefined then
        (
            logError ("Camera not found in sample scene: " + camName)
            result[2] += 1
            continue
        )

        if camName == "IPS03" then setIps03VisibilityRules() else setNonIps03VisibilityRules()

        local renderBaseName = buildRenderName camName skuFinishLabel
        local outputFile = OUTPUT_DIR + "\\" + renderBaseName + ".png"
        local tempSceneFile = TEMP_SCENE_DIR + "\\" + renderBaseName + ".max"

        viewport.setCamera camNode
        rendSaveFile = true
        rendOutputFilename = outputFile

        local saveOk = saveMaxFile tempSceneFile quiet:true
        if not saveOk then
        (
            logError ("Failed to save temp scene for submission: " + tempSceneFile)
            result[2] += 1
            continue
        )

        local submitOk = submitSceneToBackburner renderBaseName tempSceneFile camName outputFile
        if submitOk then result[1] += 1 else result[2] += 1
    )

    resetMaxFile #noPrompt
    result
)

fn runQuartzBackburnerBatch =
(
    logInfo "================ Quartz Backburner Batch Submit: START ================"
    logInfo ("ROOT_DIR            : " + ROOT_DIR)
    logInfo ("SAMPLE_SCENE_PATH   : " + SAMPLE_SCENE_PATH)
    logInfo ("OUTPUT_DIR          : " + OUTPUT_DIR)
    logInfo ("TEMP_SCENE_DIR      : " + TEMP_SCENE_DIR)
    logInfo ("BACKBURNER_MANAGER  : " + BACKBURNER_MANAGER_IP)

    if (doesDirectoryExist ROOT_DIR) == false then
    (
        logError ("ROOT_DIR does not exist: " + ROOT_DIR)
        return false
    )

    if (ensureDir OUTPUT_DIR) == false then
    (
        logError ("Failed to ensure OUTPUT_DIR: " + OUTPUT_DIR)
        return false
    )

    if (ensureDir TEMP_SCENE_DIR) == false then
    (
        logError ("Failed to ensure TEMP_SCENE_DIR: " + TEMP_SCENE_DIR)
        return false
    )

    local files = collectMaxFilesRecursive ROOT_DIR
    sortStringArray files

    if files.count == 0 then
    (
        logWarn "No source .max files found under ROOT_DIR."
        return true
    )

    local fileSuccess = 0
    local fileFailed = 0
    local totalSubmitted = 0
    local totalSubmitFailed = 0

    for i = 1 to files.count do
    (
        local src = files[i]
        logInfo ("---------------------------------------------------------------")
        logInfo ((i as string) + "/" + (files.count as string) + " Source: " + src)

        local fileResult = #(0, 0)
        try
        (
            fileResult = prepareAndSubmitPerCamera src
        )
        catch
        (
            logError ("Unhandled exception while preparing/submitting source: " + src)
            fileResult = #(0, 4)
        )

        totalSubmitted += fileResult[1]
        totalSubmitFailed += fileResult[2]

        if fileResult[2] > 0 then fileFailed += 1 else fileSuccess += 1

        logInfo ("Source result | Submitted=" + (fileResult[1] as string) + " | Failed=" + (fileResult[2] as string))
        gc light:true
    )

    logInfo "================ Quartz Backburner Batch Submit: SUMMARY ================"
    logInfo ("Source Files    : " + (files.count as string))
    logInfo ("Source Success  : " + (fileSuccess as string))
    logInfo ("Source Failed   : " + (fileFailed as string))
    logInfo ("Jobs Submitted  : " + (totalSubmitted as string))
    logInfo ("Jobs Failed     : " + (totalSubmitFailed as string))
    logInfo "================ Quartz Backburner Batch Submit: END ====================="

    (totalSubmitFailed == 0)
)

runQuartzBackburnerBatch()
