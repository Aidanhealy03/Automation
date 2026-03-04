/*
    Slate Family Packer (Level 1)
    Version: 1.0.0
    Author: <Your Name / Studio>

    Purpose:
    - Detect disconnected material/map families in the active Slate Material Editor view.
    - Keep each family together.
    - Repack families as blocks into a readable master grid.
    - Optionally apply very light cleanup inside each family.

    Notes:
    - Written defensively for production scenes with mixed plugin node types.
    - Some SME API members vary slightly by 3ds Max version; safe wrappers/fallbacks are used.
*/

-- ------------------------------------------------------------
-- Utility helpers
-- ------------------------------------------------------------

fn sfp_safeFormat msg =
(
    try (format "%\n" msg) catch()
)

fn sfp_getActiveNodeView =
(
    -- Returns active SME view object or undefined
    local v = undefined
    try
    (
        if sme == undefined then return undefined
        local activeIndex = undefined
        try (activeIndex = sme.activeView) catch (activeIndex = undefined)
        if activeIndex == undefined then return undefined
        try (v = sme.GetView activeIndex) catch (v = undefined)
    )
    catch (v = undefined)
    v
)

fn sfp_getNodeSafeReference node =
(
    local r = undefined
    try (r = node.reference) catch (r = undefined)
    r
)

fn sfp_getNodeSafeName node =
(
    local nm = "<unnamed>"
    try
    (
        if node != undefined do
        (
            if node.name != undefined and node.name != "" then nm = node.name
            else
            (
                local r = sfp_getNodeSafeReference node
                if r != undefined do
                (
                    try if r.name != undefined and r.name != "" then nm = r.name catch()
                )
            )
        )
    )
    catch()
    nm
)

fn sfp_getNodePos node =
(
    local p = [0,0]
    try (p = node.position) catch (p = [0,0])
    p
)

fn sfp_setNodePos node p =
(
    try (node.position = p) catch()
)

fn sfp_getNodeSize node =
(
    -- SME node dimensions are not fully consistent across versions/plugins.
    -- Use best-known properties with safe fallbacks.
    local w = 180
    local h = 90

    try if node.width  != undefined do w = amax 60 node.width catch()
    try if node.height != undefined do h = amax 40 node.height catch()

    try
    (
        if node.size != undefined do
        (
            if node.size.x != undefined then w = amax 60 node.size.x
            if node.size.y != undefined then h = amax 40 node.size.y
        )
    )
    catch()

    [w,h]
)

fn sfp_collectAllViewNodes nodeView =
(
    local outNodes = #()
    if nodeView == undefined then return outNodes

    local ct = 0
    try (ct = nodeView.numNodes) catch (ct = 0)

    for i = 1 to ct do
    (
        local n = undefined
        try (n = nodeView.GetNode i) catch (n = undefined)
        if n != undefined do append outNodes n
    )
    outNodes
)

fn sfp_collectSelectedViewNodes nodeView =
(
    local selectedNodes = #()
    if nodeView == undefined then return selectedNodes

    -- Preferred: API call (if available in this Max version)
    try
    (
        local apiSel = nodeView.GetSelectedNodes()
        if apiSel != undefined then
        (
            for n in apiSel where n != undefined do append selectedNodes n
            if selectedNodes.count > 0 then return selectedNodes
        )
    )
    catch()

    -- Fallback: scan all nodes and test per-node selected state
    local allNodes = sfp_collectAllViewNodes nodeView
    for n in allNodes do
    (
        local isSel = false
        try (isSel = n.selected) catch (isSel = false)
        if isSel do append selectedNodes n
    )

    selectedNodes
)

fn sfp_collectTargetNodes nodeView selectedOnly:false =
(
    if selectedOnly then sfp_collectSelectedViewNodes nodeView
    else sfp_collectAllViewNodes nodeView
)

fn sfp_findNodeIndexByRef nodeRefs targetRef =
(
    if targetRef == undefined then return 0
    for i = 1 to nodeRefs.count do if nodeRefs[i] == targetRef do return i
    0
)

fn sfp_sortStringArrayInPlace arr =
(
    -- Avoid qsort with inline comparator closures (can fail in some Max versions).
    if arr == undefined then return arr
    local ct = arr.count
    if ct < 2 then return arr

    for i = 1 to (ct - 1) do
    (
        for j = (i + 1) to ct do
        (
            if (arr[j] as string) < (arr[i] as string) do
            (
                local t = arr[i]
                arr[i] = arr[j]
                arr[j] = t
            )
        )
    )
    arr
)

fn sfp_sortIndicesByNodePosition idxArray familyNodes =
(
    -- Deterministic top-left ordering without closure comparators.
    if idxArray == undefined then return idxArray
    local ct = idxArray.count
    if ct < 2 then return idxArray

    for i = 1 to (ct - 1) do
    (
        for j = (i + 1) to ct do
        (
            local pi = sfp_getNodePos familyNodes[idxArray[i]]
            local pj = sfp_getNodePos familyNodes[idxArray[j]]

            local swapNeeded = false
            if pj.y < pi.y then swapNeeded = true
            else if (pj.y == pi.y and pj.x < pi.x) then swapNeeded = true

            if swapNeeded do
            (
                local t = idxArray[i]
                idxArray[i] = idxArray[j]
                idxArray[j] = t
            )
        )
    )
    idxArray
)

fn sfp_getRelatedRefs refObj =
(
    -- Build a conservative relation list from both dependsOn and dependents.
    -- This is used to infer graph connectivity where direct wire APIs are inconsistent.
    local rel = #()
    if refObj == undefined then return rel

    try
    (
        local d = refs.dependsOn refObj
        if d != undefined do join rel d
    )
    catch()

    try
    (
        local d2 = refs.dependents refObj
        if d2 != undefined do join rel d2
    )
    catch()

    -- Deduplicate
    local uniq = #()
    for r in rel where r != undefined do
    (
        if (findItem uniq r) == 0 do append uniq r
    )
    uniq
)

fn sfp_buildConnectivityFamilies nodes =
(
    -- Returns array of families. Each family is an array of SME nodes.
    local families = #()
    if nodes.count == 0 then return families

    -- Cache references parallel to nodes list
    local nodeRefs = for n in nodes collect (sfp_getNodeSafeReference n)

    -- Build undirected adjacency list by reference relationship
    local adjacency = for i = 1 to nodes.count collect #()

    for i = 1 to nodes.count do
    (
        local r = nodeRefs[i]
        if r == undefined then continue

        local rel = sfp_getRelatedRefs r
        for rr in rel do
        (
            local j = sfp_findNodeIndexByRef nodeRefs rr
            if j > 0 and j != i do
            (
                if (findItem adjacency[i] j) == 0 do append adjacency[i] j
                if (findItem adjacency[j] i) == 0 do append adjacency[j] i
            )
        )
    )

    -- BFS to extract connected components
    local visited = for i = 1 to nodes.count collect false

    for start = 1 to nodes.count do
    (
        if visited[start] then continue

        local fam = #()
        local queue = #(start)
        visited[start] = true

        while queue.count > 0 do
        (
            local cur = queue[1]
            deleteItem queue 1

            append fam nodes[cur]

            for nb in adjacency[cur] do
            (
                if not visited[nb] do
                (
                    visited[nb] = true
                    append queue nb
                )
            )
        )

        if fam.count > 0 do append families fam
    )

    families
)

fn sfp_getFamilyBounds familyNodes =
(
    local minX = 1e9
    local minY = 1e9
    local maxX = -1e9
    local maxY = -1e9

    for n in familyNodes do
    (
        local p = sfp_getNodePos n
        local s = sfp_getNodeSize n
        minX = amin minX p.x
        minY = amin minY p.y
        maxX = amax maxX (p.x + s.x)
        maxY = amax maxY (p.y + s.y)
    )

    if familyNodes.count == 0 do
    (
        minX = 0; minY = 0; maxX = 0; maxY = 0
    )

    #([minX,minY],[maxX,maxY], (maxX-minX), (maxY-minY))
)

fn sfp_getFamilyDisplayName familyNodes =
(
    -- Prefer a likely "main" material in this family.
    -- Heuristic: material reference not dependent on another family material/map.
    local familyRefs = #()
    for n in familyNodes do
    (
        local r = sfp_getNodeSafeReference n
        if r != undefined do append familyRefs r
    )

    local candidateNames = #()

    for r in familyRefs do
    (
        local isMat = false
        try (isMat = isKindOf r Material) catch (isMat = false)

        if isMat do
        (
            local hasParentInFamily = false
            try
            (
                local deps = refs.dependents r
                if deps != undefined do
                (
                    for d in deps while not hasParentInFamily do
                    (
                        if (findItem familyRefs d) > 0 and d != r do hasParentInFamily = true
                    )
                )
            )
            catch()

            if not hasParentInFamily do
            (
                local nm = ""
                try (nm = r.name) catch (nm = "")
                if nm != "" do append candidateNames nm
            )
        )
    )

    if candidateNames.count > 0 do
    (
        sfp_sortStringArrayInPlace candidateNames
        return candidateNames[1]
    )

    -- Fallback: alphabetically first safe node name
    local nodeNames = for n in familyNodes collect (sfp_getNodeSafeName n)
    if nodeNames.count > 0 do
    (
        sfp_sortStringArrayInPlace nodeNames
        return nodeNames[1]
    )

    "<family>"
)

fn sfp_snapValue v spacing =
(
    if spacing <= 0 then v else ((v as float / spacing as float) as integer) * spacing
)

fn sfp_lightCleanupFamily familyNodes snapSpacing:24 overlapPadding:24 =
(
    if familyNodes.count < 1 then return false

    -- Step 1: snap to grid (gentle, keeps rough shape)
    for n in familyNodes do
    (
        local p = sfp_getNodePos n
        local nx = sfp_snapValue p.x snapSpacing
        local ny = sfp_snapValue p.y snapSpacing
        sfp_setNodePos n [nx,ny]
    )

    -- Step 2: small overlap pass, deterministic by current top-left order
    local idx = for i = 1 to familyNodes.count collect i
    sfp_sortIndicesByNodePosition idx familyNodes

    for ia = 1 to idx.count do
    (
        local na = familyNodes[idx[ia]]
        local pa = sfp_getNodePos na
        local sa = sfp_getNodeSize na

        for ib = ia + 1 to idx.count do
        (
            local nb = familyNodes[idx[ib]]
            local pb = sfp_getNodePos nb
            local sb = sfp_getNodeSize nb

            local ax2 = pa.x + sa.x
            local ay2 = pa.y + sa.y
            local bx2 = pb.x + sb.x
            local by2 = pb.y + sb.y

            local overlapX = (pa.x < bx2) and (ax2 > pb.x)
            local overlapY = (pa.y < by2) and (ay2 > pb.y)

            if overlapX and overlapY do
            (
                local pushX = (ax2 - pb.x) + overlapPadding
                sfp_setNodePos nb [pb.x + pushX, pb.y]
                pb = sfp_getNodePos nb
            )
        )
    )

    true
)

fn sfp_normalizeFamilyOrigin familyNodes targetOrigin:[0,0] =
(
    local b = sfp_getFamilyBounds familyNodes
    local minPt = b[1]
    local off = [targetOrigin.x - minPt.x, targetOrigin.y - minPt.y]

    for n in familyNodes do
    (
        local p = sfp_getNodePos n
        sfp_setNodePos n [p.x + off.x, p.y + off.y]
    )
)

fn sfp_moveFamily familyNodes offset:[0,0] =
(
    for n in familyNodes do
    (
        local p = sfp_getNodePos n
        sfp_setNodePos n [p.x + offset.x, p.y + offset.y]
    )
)

fn sfp_sortFamilyData famDataA famDataB =
(
    local a = toLower famDataA.displayName
    local b = toLower famDataB.displayName
    a < b
)

fn sfp_packFamilies familyDataArray settings =
(
    -- settings fields:
    -- hGap, vGap, margin, maxRowWidth, colCount
    local x = settings.margin
    local y = settings.margin
    local rowHeight = 0
    local colIndex = 0

    for fd in familyDataArray do
    (
        local fw = fd.bounds[3]
        local fh = fd.bounds[4]

        local newRow = false

        if settings.colCount > 0 then
        (
            if colIndex >= settings.colCount do newRow = true
        )
        else
        (
            if (x > settings.margin) and ((x + fw) > settings.maxRowWidth) do newRow = true
        )

        if newRow do
        (
            x = settings.margin
            y += (rowHeight + settings.vGap)
            rowHeight = 0
            colIndex = 0
        )

        local curMin = fd.bounds[1]
        local off = [x - curMin.x, y - curMin.y]
        sfp_moveFamily fd.nodes offset:off

        -- Update current row cursor
        x += (fw + settings.hGap)
        rowHeight = amax rowHeight fh
        colIndex += 1
    )
)

fn sfp_zoomExtentsSafe nodeView =
(
    if nodeView == undefined then return false
    local ok = false
    try (nodeView.ZoomExtents(); ok = true) catch()
    if ok then return true

    -- Fallback: some versions expose it from sme interface
    try (sme.ZoomExtents(); ok = true) catch()
    ok
)

fn sfp_organizeSlateFamilies \
    selectedOnly:false \
    preserveInternal:true \
    lightRelayout:false \
    snapSpacing:24 \
    familyHGap:260 \
    familyVGap:180 \
    outerMargin:60 \
    maxRowWidth:2600 \
    colCount:0 \
    zoomAfter:true =
(
    local nodeView = sfp_getActiveNodeView()
    if nodeView == undefined then
    (
        messageBox "Slate Material Editor is not available or no active view was found." title:"Slate Family Packer"
        return false
    )

    local nodes = sfp_collectTargetNodes nodeView selectedOnly:selectedOnly

    -- Keep only nodes with valid reference objects for connectivity logic.
    local validNodes = #()
    for n in nodes do
    (
        local r = sfp_getNodeSafeReference n
        if r != undefined then append validNodes n
    )

    if validNodes.count == 0 then
    (
        messageBox "No valid nodes found for the selected mode.\nTry switching between All Nodes and Selected Nodes." title:"Slate Family Packer"
        return false
    )

    local families = sfp_buildConnectivityFamilies validNodes
    if families.count == 0 then
    (
        messageBox "No node families could be identified in this view." title:"Slate Family Packer"
        return false
    )

    -- Prepare mutable data records for each family
    local familyData = #()
    for fam in families do
    (
        if (not preserveInternal) do sfp_normalizeFamilyOrigin fam targetOrigin:[0,0]
        if lightRelayout do sfp_lightCleanupFamily fam snapSpacing:snapSpacing overlapPadding:(snapSpacing/2)

        local b = sfp_getFamilyBounds fam
        local nm = sfp_getFamilyDisplayName fam

        append familyData (dotNetObject "System.Collections.Hashtable")
        local fd = familyData[familyData.count]
        fd["nodes"] = fam
        fd["bounds"] = b
        fd["displayName"] = nm
    )

    -- Convert hashtable records to simple struct-like wrappers for cleaner sort/pack
    struct SFPFamilyData (nodes, bounds, displayName)
    local sortedData = #()
    for fd in familyData do append sortedData (SFPFamilyData nodes:fd["nodes"] bounds:fd["bounds"] displayName:fd["displayName"])

    qsort sortedData sfp_sortFamilyData

    local settings = dotNetObject "System.Collections.Hashtable"
    settings["hGap"] = familyHGap
    settings["vGap"] = familyVGap
    settings["margin"] = outerMargin
    settings["maxRowWidth"] = amax 800 maxRowWidth
    settings["colCount"] = amax 0 colCount

    -- Adapter struct to read hashtable values conveniently
    struct SFPSettings (hGap, vGap, margin, maxRowWidth, colCount)
    local s = SFPSettings \
        hGap:settings["hGap"] \
        vGap:settings["vGap"] \
        margin:settings["margin"] \
        maxRowWidth:settings["maxRowWidth"] \
        colCount:settings["colCount"]

    sfp_packFamilies sortedData s

    if zoomAfter do sfp_zoomExtentsSafe nodeView

    local modeText = if selectedOnly then "Selected Nodes" else "All Nodes"
    sfp_safeFormat "----------------------------------------"
    sfp_safeFormat ("Slate Family Packer complete")
    sfp_safeFormat ("Nodes processed: " + validNodes.count as string)
    sfp_safeFormat ("Families found : " + families.count as string)
    sfp_safeFormat ("Mode used      : " + modeText)
    sfp_safeFormat ("Preserve layout: " + preserveInternal as string)
    sfp_safeFormat ("Light relayout : " + lightRelayout as string)
    sfp_safeFormat "----------------------------------------"

    true
)

-- ------------------------------------------------------------
-- Rollout UI
-- ------------------------------------------------------------

try (destroyDialog ::SlateFamilyPackerRollout) catch()

rollout SlateFamilyPackerRollout "Slate Family Packer" width:340
(
    group "Target"
    (
        radiobuttons rbMode "Node Scope" labels:#("All Nodes", "Selected Nodes") columns:2 default:1
    )

    group "Family Behavior"
    (
        checkbox chkPreserve "Preserve family internal layout" checked:true
        checkbox chkLight "Light cleanup inside family" checked:false
    )

    group "Spacing"
    (
        spinner spnHGap "Family horizontal gap:" type:#integer range:[20,5000,260] scale:10
        spinner spnVGap "Family vertical gap:" type:#integer range:[20,5000,180] scale:10
        spinner spnSnap "Node snap spacing:" type:#integer range:[1,512,24] scale:1
        spinner spnMargin "Outer margin:" type:#integer range:[0,2000,60] scale:10
    )

    group "Packing"
    (
        spinner spnMaxRow "Max row width:" type:#integer range:[300,20000,2600] scale:50
        spinner spnCols "Fixed columns (0=auto width):" type:#integer range:[0,30,0] scale:1
    )

    checkbox chkZoomAfter "Zoom extents after organize" checked:true

    button btnOrganize "Organize" width:150 align:#left
    button btnZoom "Zoom Extents" width:150 align:#right
    button btnClose "Close" width:330

    on btnOrganize pressed do
    (
        local selectedOnly = (rbMode.state == 2)

        sfp_organizeSlateFamilies \
            selectedOnly:selectedOnly \
            preserveInternal:chkPreserve.checked \
            lightRelayout:chkLight.checked \
            snapSpacing:spnSnap.value \
            familyHGap:spnHGap.value \
            familyVGap:spnVGap.value \
            outerMargin:spnMargin.value \
            maxRowWidth:spnMaxRow.value \
            colCount:spnCols.value \
            zoomAfter:chkZoomAfter.checked
    )

    on btnZoom pressed do
    (
        local v = sfp_getActiveNodeView()
        if not (sfp_zoomExtentsSafe v) do
        (
            messageBox "Unable to execute Zoom Extents for the active Slate view." title:"Slate Family Packer"
        )
    )

    on btnClose pressed do
    (
        try (destroyDialog SlateFamilyPackerRollout) catch()
    )
)

createDialog SlateFamilyPackerRollout style:#(#style_titlebar, #style_sysmenu, #style_toolwindow)
