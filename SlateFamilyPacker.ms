/*
    Slate Material Library Organizer
    Version: 2.0.0
    Author: <Your Name / Studio>

    Goal:
    - Convert a chaotic Slate Material Editor (SME) view into a consistent, card-based library layout.
    - Build top-level material "cards" with deterministic internal relayout.
    - Place cards into category sections (Prefix / Type / None).
    - Provide navigator/search/focus workflow and undo layout restore.

    Safety:
    - Presentation-only tool: moves SME nodes; does not delete materials/maps.
    - Defensive wrappers used for API variability between 3ds Max versions.

    API notes:
    - SME annotation/frame APIs vary heavily by version/plugin. This script uses safe optional
      wrappers for note/frame creation; if unavailable, layout still works without annotations.
*/

-- ============================================================
-- Global state
-- ============================================================

global SFPO_State
if SFPO_State == undefined do
(
    struct SFPOStateStruct
    (
        lastNodes = #(),
        lastPositions = #(),
        materialCards = #(),
        cardNames = #(),
        currentIndex = 0,
        lastView = undefined,
        lastSummary = ""
    )
    SFPO_State = SFPOStateStruct()
)

struct SFPOCard
(
    name,
    section,
    rootNode,
    rootRef,
    nodes,
    nodeRefs,
    bounds,
    nodeCount,
    mapCount
)

-- ============================================================
-- Core safe helpers
-- ============================================================

fn sfpo_log msg = (try(format "[SFPO] %\n" msg)catch())

fn sfpo_safeNameFromRef r =
(
    local nm = "<unnamed>"
    if r == undefined then return nm
    try if r.name != undefined and r.name != "" do nm = r.name catch()
    nm
)

fn sfpo_getNodeRef n =
(
    local r = undefined
    try(r = n.reference)catch(r = undefined)
    r
)

fn sfpo_getNodeName n =
(
    local nm = "<node>"
    try if n.name != undefined and n.name != "" do nm = n.name catch()
    if nm == "<node>" do
    (
        local r = sfpo_getNodeRef n
        if r != undefined do nm = sfpo_safeNameFromRef r
    )
    nm
)

fn sfpo_getNodePos n = (local p=[0,0]; try(p=n.position)catch(); p)
fn sfpo_setNodePos n p = (try(n.position = p)catch())

fn sfpo_getNodeSize n =
(
    local w = 180
    local h = 95
    try if n.width != undefined do w = amax 60 n.width catch()
    try if n.height != undefined do h = amax 45 n.height catch()
    try
    (
        if n.size != undefined do
        (
            if n.size.x != undefined do w = amax 60 n.size.x
            if n.size.y != undefined do h = amax 45 n.size.y
        )
    )
    catch()
    [w,h]
)

fn sfpo_getActiveView =
(
    local v = undefined
    try
    (
        if sme == undefined then return undefined
        local idx = undefined
        try(idx = sme.activeView)catch()
        if idx == undefined then return undefined
        try(v = sme.GetView idx)catch(v = undefined)
    )
    catch(v = undefined)
    v
)

fn sfpo_collectAllNodes v =
(
    local outNodes = #()
    if v == undefined then return outNodes

    local ct = 0
    try(ct = v.numNodes)catch()
    if ct == 0 do try(ct = v.GetNumNodes())catch()

    if ct > 0 do
    (
        for i=1 to ct do
        (
            local n = undefined
            try(n = v.GetNode i)catch(n = undefined)
            if n != undefined and (findItem outNodes n) == 0 do append outNodes n
        )

        if outNodes.count == 0 do
        (
            for i=0 to (ct-1) do
            (
                local n = undefined
                try(n = v.GetNode i)catch(n = undefined)
                if n != undefined and (findItem outNodes n) == 0 do append outNodes n
            )
        )
    )
    outNodes
)

fn sfpo_collectSelectedNodes v =
(
    local outNodes = #()
    if v == undefined then return outNodes

    try
    (
        local apiSel = v.GetSelectedNodes()
        if apiSel != undefined do
        (
            for n in apiSel where n != undefined do append outNodes n
            if outNodes.count > 0 then return outNodes
        )
    )
    catch()

    local allNodes = sfpo_collectAllNodes v
    for n in allNodes do
    (
        local isSel = false
        try(isSel = n.selected)catch()
        if isSel do append outNodes n
    )
    outNodes
)

fn sfpo_collectTargetNodes v selectedOnly:false =
(
    if selectedOnly then sfpo_collectSelectedNodes v else sfpo_collectAllNodes v
)

fn sfpo_nodeIndexByRef refs target =
(
    if target == undefined then return 0
    for i=1 to refs.count do if refs[i] == target do return i
    0
)

fn sfpo_isMapOrMaterial obj =
(
    local ok = false
    try(ok = (isKindOf obj Material) or (isKindOf obj TextureMap))catch(ok = false)
    ok
)

fn sfpo_relatedRefs refObj =
(
    local out = #()
    if refObj == undefined then return out

    try
    (
        local d = refs.dependsOn refObj
        if d != undefined do join out d
    )
    catch()
    try
    (
        local d2 = refs.dependents refObj
        if d2 != undefined do join out d2
    )
    catch()

    local uniq = #()
    for r in out where r != undefined do if (findItem uniq r) == 0 do append uniq r
    uniq
)

fn sfpo_getInputRefsFromSubAnims refObj candidateRefs =
(
    -- Directed graph helper: returns map/material inputs referenced by refObj via subAnims.
    local out = #()
    if refObj == undefined then return out

    local saCount = 0
    try(saCount = refObj.numSubs)catch(saCount = 0)
    for i=1 to saCount do
    (
        local subObj = undefined
        try(subObj = getSubAnim refObj i)catch(subObj = undefined)
        if subObj != undefined and sfpo_isMapOrMaterial subObj do
        (
            if (findItem candidateRefs subObj) > 0 and (findItem out subObj) == 0 do append out subObj
        )
    )
    out
)

fn sfpo_boundsFromNodes nodes =
(
    local minX = 1e9
    local minY = 1e9
    local maxX = -1e9
    local maxY = -1e9

    for n in nodes do
    (
        local p = sfpo_getNodePos n
        local s = sfpo_getNodeSize n
        minX = amin minX p.x
        minY = amin minY p.y
        maxX = amax maxX (p.x + s.x)
        maxY = amax maxY (p.y + s.y)
    )

    if nodes.count == 0 do (minX = 0; minY = 0; maxX = 0; maxY = 0)
    #([minX,minY],[maxX,maxY],(maxX-minX),(maxY-minY))
)

fn sfpo_sortStringsInPlace arr =
(
    if arr == undefined then return arr
    local ct = arr.count
    if ct < 2 then return arr
    for i=1 to (ct-1) do
    (
        for j=(i+1) to ct do
        (
            if (toLower (arr[j] as string)) < (toLower (arr[i] as string)) do
            (
                local t = arr[i]; arr[i] = arr[j]; arr[j] = t
            )
        )
    )
    arr
)

-- ============================================================
-- Top-level material detection
-- ============================================================

fn sfpo_collectMaterialNodes nodes =
(
    local out = #()
    for n in nodes do
    (
        local r = sfpo_getNodeRef n
        local isMat = false
        try(isMat = isKindOf r Material)catch()
        if isMat do append out n
    )
    out
)

fn sfpo_isSubMaterialOfOther candidateMat allMatRefs =
(
    if candidateMat == undefined then return false
    local dep = #()
    try(dep = refs.dependents candidateMat)catch(dep = #())

    for d in dep do
    (
        if d != undefined and d != candidateMat and (findItem allMatRefs d) > 0 do
        (
            local saCt = 0
            try(saCt = d.numSubs)catch(saCt = 0)
            for si=1 to saCt do
            (
                local subObj = undefined
                try(subObj = getSubAnim d si)catch(subObj = undefined)
                if subObj == candidateMat do return true
            )
        )
    )
    false
)

fn sfpo_findTopLevelMaterialNodes targetNodes includeSceneAssigned:false =
(
    local materialNodes = sfpo_collectMaterialNodes targetNodes
    if materialNodes.count == 0 then return #()

    local matRefs = for n in materialNodes collect (sfpo_getNodeRef n)
    local roots = #()

    for n in materialNodes do
    (
        local r = sfpo_getNodeRef n
        if r == undefined then continue

        local isSub = sfpo_isSubMaterialOfOther r matRefs
        local keep = not isSub

        if (not keep) and includeSceneAssigned do
        (
            try
            (
                if (findItem (for sm in scenematerials collect sm) r) > 0 do keep = true
            )
            catch()
        )

        if keep do append roots n
    )

    if roots.count == 0 do
    (
        -- Fallback: use alphabetically first material node to avoid empty result.
        roots = materialNodes
    )

    roots
)

-- ============================================================
-- Card graph + deterministic relayout
-- ============================================================

fn sfpo_roleScore n =
(
    local nm = toLower (sfpo_getNodeName n)
    if (matchPattern nm pattern:"*base*" ignoreCase:true) or (matchPattern nm pattern:"*albedo*" ignoreCase:true) then return 10
    if (matchPattern nm pattern:"*rough*" ignoreCase:true) then return 20
    if (matchPattern nm pattern:"*metal*" ignoreCase:true) then return 30
    if (matchPattern nm pattern:"*normal*" ignoreCase:true) or (matchPattern nm pattern:"*bump*" ignoreCase:true) then return 40
    if (matchPattern nm pattern:"*disp*" ignoreCase:true) or (matchPattern nm pattern:"*height*" ignoreCase:true) then return 50
    if (matchPattern nm pattern:"*opacity*" ignoreCase:true) or (matchPattern nm pattern:"*alpha*" ignoreCase:true) then return 60
    if (matchPattern nm pattern:"*emis*" ignoreCase:true) then return 70
    500
)

fn sfpo_sortNodesByRoleAndName nodeArr =
(
    if nodeArr == undefined then return nodeArr
    local ct = nodeArr.count
    if ct < 2 then return nodeArr

    for i=1 to (ct-1) do
    (
        for j=(i+1) to ct do
        (
            local ai = nodeArr[i]
            local aj = nodeArr[j]
            local ri = sfpo_roleScore ai
            local rj = sfpo_roleScore aj
            local swapNeeded = false

            if rj < ri then swapNeeded = true
            if (not swapNeeded) and (rj == ri) do
            (
                local ni = toLower (sfpo_getNodeName ai)
                local nj = toLower (sfpo_getNodeName aj)
                if nj < ni do swapNeeded = true
            )

            if swapNeeded do
            (
                local t = nodeArr[i]
                nodeArr[i] = nodeArr[j]
                nodeArr[j] = t
            )
        )
    )
    nodeArr
)

fn sfpo_getConnectedFamilyFromRoot rootNode allNodes allRefs =
(
    -- Undirected connectivity for family membership (robust), then directed depths for relayout.
    local fam = #()
    local q = #()
    append q rootNode

    while q.count > 0 do
    (
        local n = q[1]
        deleteItem q 1
        if (findItem fam n) > 0 do continue
        append fam n

        local r = sfpo_getNodeRef n
        if r == undefined then continue
        local rel = sfpo_relatedRefs r

        for rr in rel do
        (
            local idx = sfpo_nodeIndexByRef allRefs rr
            if idx > 0 do
            (
                local nn = allNodes[idx]
                if (findItem fam nn) == 0 and (findItem q nn) == 0 do append q nn
            )
        )
    )
    fam
)

fn sfpo_buildDepths rootNode familyNodes =
(
    -- Returns #(nodesArray, depthArray) parallel arrays.
    local nodeRefs = for n in familyNodes collect (sfpo_getNodeRef n)
    local depths = for i=1 to familyNodes.count collect -1

    local rootIdx = findItem familyNodes rootNode
    if rootIdx == 0 then rootIdx = 1
    depths[rootIdx] = 0

    local frontier = #(rootIdx)

    while frontier.count > 0 do
    (
        local nextF = #()
        for fi in frontier do
        (
            local curNode = familyNodes[fi]
            local curRef = nodeRefs[fi]
            if curRef == undefined then continue

            local inputRefs = sfpo_getInputRefsFromSubAnims curRef nodeRefs
            for ir in inputRefs do
            (
                local ni = sfpo_nodeIndexByRef nodeRefs ir
                if ni > 0 do
                (
                    local proposed = depths[fi] + 1
                    if depths[ni] < proposed do
                    (
                        depths[ni] = proposed
                        if (findItem nextF ni) == 0 do append nextF ni
                    )
                )
            )
        )
        frontier = nextF
    )

    -- Any disconnected leftovers in family get pushed to far-left utility lane.
    local maxD = 0
    for d in depths do if d > maxD do maxD = d
    for i=1 to depths.count do if depths[i] < 0 do depths[i] = maxD + 1

    #(familyNodes, depths)
)

fn sfpo_layoutCardNodes rootNode familyNodes frameLeft frameTop frameWidth framePadding laneGap rowGap =
(
    local depthData = sfpo_buildDepths rootNode familyNodes
    local nodesArr = depthData[1]
    local depths = depthData[2]

    local maxDepth = 0
    for d in depths do if d > maxDepth do maxDepth = d

    local rootX = frameLeft + frameWidth - framePadding - 220
    local startY = frameTop + framePadding + 36

    -- Place depth lanes left -> right toward root (depth 0 at right).
    for d = 0 to maxDepth do
    (
        local laneNodes = #()
        for i=1 to nodesArr.count do if depths[i] == d do append laneNodes nodesArr[i]
        sfpo_sortNodesByRoleAndName laneNodes

        local laneX = rootX - (d * laneGap)
        local y = startY

        for n in laneNodes do
        (
            sfpo_setNodePos n [laneX, y]
            local sz = sfpo_getNodeSize n
            y += (sz.y + rowGap)
        )
    )

    sfpo_boundsFromNodes familyNodes
)

-- ============================================================
-- Categorization / sectioning
-- ============================================================

fn sfpo_parseCSV textVal =
(
    local out = #()
    if textVal == undefined then return out
    local parts = filterString textVal ",;|"
    for p in parts do
    (
        local t = trimRight (trimLeft p)
        if t != "" do append out t
    )
    out
)

fn sfpo_matchPrefixSection name prefixArr =
(
    local n = toLower name
    for p in prefixArr do
    (
        local pp = toLower p
        if (matchPattern n pattern:(pp + "*") ignoreCase:true) do return p
    )
    "MISC"
)

fn sfpo_cardSectionName card categMode prefixArr =
(
    if categMode == 1 do return "ALL"
    if categMode == 2 do return (sfpo_matchPrefixSection card.name prefixArr)

    -- by type
    local tname = "MISC"
    try if card.rootRef != undefined do tname = (classOf card.rootRef as string) catch()
    tname
)

fn sfpo_sortCardsByName cards =
(
    local ct = cards.count
    if ct < 2 then return cards
    for i=1 to (ct-1) do
    (
        for j=(i+1) to ct do
        (
            if (toLower cards[j].name) < (toLower cards[i].name) do
            (
                local t = cards[i]
                cards[i] = cards[j]
                cards[j] = t
            )
        )
    )
    cards
)

fn sfpo_uniqueStrings arr =
(
    local out = #()
    for a in arr do if (findItem out a) == 0 do append out a
    out
)

-- ============================================================
-- Optional annotations (version-dependent)
-- ============================================================

fn sfpo_tryCreateSectionHeader viewObj title p =
(
    -- SME note/frame APIs differ by Max version. These are best-effort attempts.
    local made = false
    try(if isProperty viewObj #CreateNote do (viewObj.CreateNote title p; made = true))catch()
    if not made do try(if isProperty viewObj #CreateComment do (viewObj.CreateComment title p; made = true))catch()
    if not made do sfpo_log ("Section header fallback (no note API): " + title)
    made
)

-- ============================================================
-- Navigator + focus helpers
-- ============================================================

fn sfpo_zoomExtentsSafe v =
(
    local ok = false
    if v == undefined then return false
    try(v.ZoomExtents(); ok = true)catch()
    if not ok do try(sme.ZoomExtents(); ok = true)catch()
    ok
)

fn sfpo_focusCardByIndex idx =
(
    if idx < 1 or idx > SFPO_State.materialCards.count then return false
    local card = SFPO_State.materialCards[idx]
    if card == undefined then return false

    -- Best-effort focus: select family nodes then ZoomExtents.
    for n in card.nodes do try(n.selected = true)catch()
    sfpo_zoomExtentsSafe SFPO_State.lastView
)

fn sfpo_storeUndo nodes =
(
    SFPO_State.lastNodes = #()
    SFPO_State.lastPositions = #()
    for n in nodes do
    (
        append SFPO_State.lastNodes n
        append SFPO_State.lastPositions (sfpo_getNodePos n)
    )
)

fn sfpo_restoreUndo =
(
    if SFPO_State.lastNodes.count == 0 then return false
    for i=1 to SFPO_State.lastNodes.count do
    (
        local n = SFPO_State.lastNodes[i]
        local p = SFPO_State.lastPositions[i]
        if n != undefined and p != undefined do sfpo_setNodePos n p
    )
    if SFPO_State.lastView != undefined do sfpo_zoomExtentsSafe SFPO_State.lastView
    true
)

-- ============================================================
-- Main build / layout routine
-- ============================================================

fn sfpo_buildLayout \
    selectedOnly:false \
    previewOnly:false \
    layoutDir:1 \
    spacingPreset:2 \
    sharedMode:1 \
    categMode:2 \
    prefixRules:"WOOD_,METAL_,FABRIC_,GLASS_,WALL_,TRIM_,FX_" \
    pinnedCSV:"" \
    includeSceneAssigned:false \
    moveOrphans:true \
    =
(
    local v = sfpo_getActiveView()
    if v == undefined then
    (
        messageBox "No active Slate view found." title:"Slate Library Organizer"
        return false
    )

    local nodes = sfpo_collectTargetNodes v selectedOnly:selectedOnly
    if nodes.count == 0 then
    (
        messageBox "No nodes found in current mode." title:"Slate Library Organizer"
        return false
    )

    SFPO_State.lastView = v
    sfpo_storeUndo nodes

    local refs = for n in nodes collect (sfpo_getNodeRef n)

    local rootMaterials = sfpo_findTopLevelMaterialNodes nodes includeSceneAssigned:includeSceneAssigned
    if rootMaterials.count == 0 then
    (
        messageBox "No top-level materials detected." title:"Slate Library Organizer"
        return false
    )

    -- spacing presets
    local laneGap = 260
    local rowGap = 36
    local framePad = 50
    local cardW = 1300
    local cardHMin = 380
    local cardGapX = 220
    local cardGapY = 190
    case spacingPreset of
    (
        1: (laneGap = 220; rowGap = 24; framePad = 36; cardW = 1100; cardGapX = 170; cardGapY = 140)
        2: (laneGap = 260; rowGap = 36; framePad = 50; cardW = 1300; cardGapX = 220; cardGapY = 190)
        3: (laneGap = 320; rowGap = 52; framePad = 64; cardW = 1500; cardGapX = 280; cardGapY = 240)
    )

    local cards = #()
    local consumedRefs = #()

    for root in rootMaterials do
    (
        local famNodes = sfpo_getConnectedFamilyFromRoot root nodes refs
        local famRefs = for fnn in famNodes collect (sfpo_getNodeRef fnn)

        local rootRef = sfpo_getNodeRef root
        local nm = sfpo_safeNameFromRef rootRef

        local mapCount = 0
        for fr in famRefs do
        (
            local isMap = false
            try(isMap = isKindOf fr TextureMap)catch()
            if isMap do mapCount += 1
        )

        local c = SFPOCard name:nm section:"" rootNode:root rootRef:rootRef nodes:famNodes nodeRefs:famRefs bounds:#([0,0],[0,0],0,0) nodeCount:famNodes.count mapCount:mapCount
        append cards c

        for rr in famRefs where rr != undefined do if (findItem consumedRefs rr) == 0 do append consumedRefs rr
    )

    -- Orphans = nodes not part of any root card family
    local orphans = #()
    for n in nodes do
    (
        local rr = sfpo_getNodeRef n
        if rr != undefined and (findItem consumedRefs rr) == 0 do append orphans n
    )

    -- Shared map handling
    -- 1=Leave as is, 2=Shared frame, 3=Duplicate per material (fallback to shared frame if no safe node duplication API)
    local sharedNodes = #()
    if sharedMode != 1 do
    (
        local refUseCounts = #()
        local uniqRefs = #()
        for c in cards do
        (
            for rr in c.nodeRefs where rr != undefined do
            (
                local i = findItem uniqRefs rr
                if i == 0 then
                (
                    append uniqRefs rr
                    append refUseCounts 1
                )
                else
                (
                    refUseCounts[i] += 1
                )
            )
        )

        for i=1 to uniqRefs.count do
        (
            if refUseCounts[i] > 1 do
            (
                local ridx = sfpo_nodeIndexByRef refs uniqRefs[i]
                if ridx > 0 do
                (
                    local nn = nodes[ridx]
                    if (findItem sharedNodes nn) == 0 do append sharedNodes nn
                )
            )
        )

        if sharedMode == 3 do sfpo_log "Duplicate-per-material mode requested, but safe duplication API is version-dependent. Using Shared Frame strategy."
    )

    -- Categorization + pinned
    local prefixes = sfpo_parseCSV prefixRules
    local pinnedNames = sfpo_parseCSV pinnedCSV

    for i=1 to cards.count do
    (
        cards[i].section = sfpo_cardSectionName cards[i] categMode prefixes
    )

    -- sort cards by pinned first, then section, then name
    sfpo_sortCardsByName cards
    for i=1 to (cards.count-1) do
    (
        for j=(i+1) to cards.count do
        (
            local ci = cards[i]
            local cj = cards[j]
            local pi = (findItem pinnedNames ci.name) > 0
            local pj = (findItem pinnedNames cj.name) > 0
            local swapNeeded = false

            if (pj and not pi) then swapNeeded = true
            if (not swapNeeded) and (pi == pj) do
            (
                if (toLower cj.section) < (toLower ci.section) do swapNeeded = true
                else if (toLower cj.section) == (toLower ci.section) do
                (
                    if (toLower cj.name) < (toLower ci.name) do swapNeeded = true
                )
            )

            if swapNeeded do
            (
                local t = cards[i]
                cards[i] = cards[j]
                cards[j] = t
            )
        )
    )

    -- Layout cards in sections
    local sectionNames = sfpo_uniqueStrings (for c in cards collect c.section)
    sfpo_sortStringsInPlace sectionNames

    local indexX = -2600
    local sectionStartX = -1200
    local yCursor = -200

    -- optional preview: only attempt headers/index notes, no node movement
    if previewOnly do
    (
        sfpo_log "Preview mode: section headers only (no node movement)."
        local yy = -200
        for sn in sectionNames do
        (
            sfpo_tryCreateSectionHeader v ("[SECTION] " + sn) [sectionStartX, yy]
            yy += 280
        )

        if sharedMode != 1 and sharedNodes.count > 0 do sfpo_tryCreateSectionHeader v "[SECTION] SHARED MAPS" [sectionStartX, yy]

        SFPO_State.materialCards = cards
        SFPO_State.cardNames = for c in cards collect (c.name + "  [" + c.section + "]  (" + c.nodeCount as string + " nodes)")
        SFPO_State.currentIndex = if cards.count > 0 then 1 else 0
        return true
    )

    for sn in sectionNames do
    (
        sfpo_tryCreateSectionHeader v ("[SECTION] " + sn) [sectionStartX, yCursor - 80]

        local x = sectionStartX
        local rowMaxH = 0

        for c in cards where c.section == sn do
        (
            -- deterministic card internal relayout
            local b = sfpo_layoutCardNodes c.rootNode c.nodes x yCursor cardW framePad laneGap rowGap
            c.bounds = b

            local cardH = amax cardHMin b[4]
            rowMaxH = amax rowMaxH cardH

            -- index entry note (best-effort)
            sfpo_tryCreateSectionHeader v ("• " + c.name) [indexX, yCursor]

            if layoutDir == 1 then
            (
                x += (cardW + cardGapX)
            )
            else
            (
                yCursor += (cardH + cardGapY)
            )
        )

        if layoutDir == 1 then yCursor += (rowMaxH + cardGapY)
        yCursor += 120
    )

    -- Shared maps area
    if sharedMode != 1 and sharedNodes.count > 0 do
    (
        sfpo_tryCreateSectionHeader v "[SECTION] SHARED MAPS" [sectionStartX, yCursor - 80]
        local sx = sectionStartX
        local sy = yCursor
        for n in sharedNodes do
        (
            sfpo_setNodePos n [sx, sy]
            local sz = sfpo_getNodeSize n
            sy += (sz.y + 20)
        )
        yCursor = sy + 120
    )

    -- Orphans
    if moveOrphans and orphans.count > 0 do
    (
        sfpo_tryCreateSectionHeader v "[SECTION] ORPHANS" [sectionStartX, yCursor - 80]
        local ox = sectionStartX
        local oy = yCursor
        for n in orphans do
        (
            sfpo_setNodePos n [ox, oy]
            local sz = sfpo_getNodeSize n
            oy += (sz.y + 16)
        )
    )

    sfpo_zoomExtentsSafe v

    SFPO_State.materialCards = cards
    SFPO_State.cardNames = for c in cards collect (c.name + "  [" + c.section + "]  (" + c.nodeCount as string + " nodes, " + c.mapCount as string + " maps)")
    SFPO_State.currentIndex = if cards.count > 0 then 1 else 0
    SFPO_State.lastSummary = ("Cards: " + cards.count as string + " | Orphans: " + orphans.count as string + " | Shared: " + sharedNodes.count as string)

    sfpo_log SFPO_State.lastSummary
    true
)

-- ============================================================
-- Rollout UI
-- ============================================================

try(destroyDialog ::SlateLibraryOrganizerRollout)catch()

rollout SlateLibraryOrganizerRollout "Slate Library Organizer" width:460 height:760
(
    group "Scope"
    (
        radiobuttons rbScope "Target" labels:#("All Nodes", "Selected Nodes") columns:2 default:1
        checkbox chkPreview "Preview sections only (no node movement)" checked:false
    )

    group "Layout"
    (
        radiobuttons rbDirection "Layout direction" labels:#("Left -> Right cards", "Top -> Bottom cards") columns:1 default:1
        radiobuttons rbSpacing "Spacing preset" labels:#("Tight", "Medium", "Large") columns:3 default:2
        dropdownlist ddShared "Shared maps" items:#("Leave as is", "Shared Maps frame", "Duplicate per material (fallback to Shared)") selection:2
        dropdownlist ddCat "Categorization" items:#("None", "Prefix rules", "Material type") selection:2
        checkbox chkSceneAssigned "Use scene-assigned material hint" checked:false
    )

    group "Rules"
    (
        edittext edtPrefixes "Prefix rules:" text:"WOOD_,METAL_,FABRIC_,GLASS_,WALL_,TRIM_,FX_" width:430
        edittext edtPinned "Pinned materials (CSV):" text:"" width:430
    )

    group "Navigator"
    (
        edittext edtSearch "Search:" text:"" width:300
        button btnSearchFocus "Focus" width:120 align:#right
        listbox lbCards "Materials" height:14 width:430

        button btnBuild "Build Index / Rebuild Layout" width:210 align:#left
        button btnFocus "Focus Selected Material" width:210 align:#right

        button btnPrev "Prev Material" width:140 align:#left
        button btnNext "Next Material" width:140 align:#center
        button btnSolo "Show Only This Material (Focus)" width:170 align:#right

        button btnOrphans "Move Orphans to Orphans Frame" width:210 align:#left
        button btnSections "Create Sections from Prefix Rules" width:210 align:#right

        button btnUndo "Undo Layout" width:140 align:#left
        button btnZoom "Zoom Extents" width:140 align:#center
        button btnClose "Close" width:140 align:#right
    )

    label lblInfo "Status: Idle"

    fn uiRefreshCardList =
    (
        lbCards.items = SFPO_State.cardNames
        if SFPO_State.currentIndex > 0 and SFPO_State.currentIndex <= lbCards.items.count do lbCards.selection = SFPO_State.currentIndex
        lblInfo.text = ("Status: " + SFPO_State.lastSummary)
    )

    fn uiBuild runPreview:false =
    (
        local ok = sfpo_buildLayout \
            selectedOnly:(rbScope.state == 2) \
            previewOnly:runPreview \
            layoutDir:rbDirection.state \
            spacingPreset:rbSpacing.state \
            sharedMode:ddShared.selection \
            categMode:ddCat.selection \
            prefixRules:edtPrefixes.text \
            pinnedCSV:edtPinned.text \
            includeSceneAssigned:chkSceneAssigned.checked \
            moveOrphans:true

        if ok then uiRefreshCardList()
    )

    on btnBuild pressed do
    (
        uiBuild runPreview:chkPreview.checked
    )

    on btnFocus pressed do
    (
        if lbCards.selection > 0 do
        (
            SFPO_State.currentIndex = lbCards.selection
            sfpo_focusCardByIndex SFPO_State.currentIndex
        )
    )

    on btnPrev pressed do
    (
        if SFPO_State.materialCards.count > 0 do
        (
            SFPO_State.currentIndex -= 1
            if SFPO_State.currentIndex < 1 do SFPO_State.currentIndex = SFPO_State.materialCards.count
            lbCards.selection = SFPO_State.currentIndex
            sfpo_focusCardByIndex SFPO_State.currentIndex
        )
    )

    on btnNext pressed do
    (
        if SFPO_State.materialCards.count > 0 do
        (
            SFPO_State.currentIndex += 1
            if SFPO_State.currentIndex > SFPO_State.materialCards.count do SFPO_State.currentIndex = 1
            lbCards.selection = SFPO_State.currentIndex
            sfpo_focusCardByIndex SFPO_State.currentIndex
        )
    )

    on btnSolo pressed do
    (
        if lbCards.selection > 0 do
        (
            SFPO_State.currentIndex = lbCards.selection
            -- SME does not expose universal dim-all API across versions; focus selected card as practical equivalent.
            sfpo_focusCardByIndex SFPO_State.currentIndex
        )
    )

    on btnSearchFocus pressed do
    (
        local q = toLower edtSearch.text
        if q == "" then return()
        for i=1 to SFPO_State.materialCards.count do
        (
            if (findString (toLower SFPO_State.materialCards[i].name) q) != undefined do
            (
                SFPO_State.currentIndex = i
                lbCards.selection = i
                sfpo_focusCardByIndex i
                exit
            )
        )
    )

    on lbCards selected itm do
    (
        SFPO_State.currentIndex = itm
    )

    on btnOrphans pressed do
    (
        -- Rebuild with current options; orphan pass always runs in build.
        uiBuild runPreview:false
    )

    on btnSections pressed do
    (
        -- Force Prefix categorization and rebuild.
        ddCat.selection = 2
        uiBuild runPreview:chkPreview.checked
    )

    on btnUndo pressed do
    (
        if sfpo_restoreUndo() then lblInfo.text = "Status: Layout restored." else lblInfo.text = "Status: Nothing to undo."
    )

    on btnZoom pressed do
    (
        local v = sfpo_getActiveView()
        if not sfpo_zoomExtentsSafe v do messageBox "ZoomExtents unavailable for current SME view." title:"Slate Library Organizer"
    )

    on btnClose pressed do
    (
        try(destroyDialog SlateLibraryOrganizerRollout)catch()
    )
)

createDialog SlateLibraryOrganizerRollout style:#(#style_titlebar,#style_sysmenu,#style_toolwindow)
