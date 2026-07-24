-- This Source Code Form is subject to the terms of the MIT License.
-- Copyright (c) 2026 
-- Author C6g3. 
--
-- For the latest updates, documentation, and examples, please check the official repository:
-- GitHub: https://github.com/Psynolyn/BeamNG-propTriggers.git


local M = {}
M.drawBoxes = false
local logTag = 'propTriggers'
local triggersByVeh = {}
local propTriggerLinksDict = {}  -- [vehId][triggerId][triggerInput] = {links}
local cursorVisible = true
local initializedVehicles = false
local prevHoveredPropTrigger = { vehId = nil, triggerId = nil }

-- Find the first keyboard binding for a given action string, matching inversion state.
-- Mirrors the same function in core/vehicleTriggers.lua.
local function findKeyboardBindingForAction(actionStr, desiredInverted)
    for _, device in ipairs(core_input_bindings and core_input_bindings.bindings or {}) do
        local contents = device.contents or {}
        if contents.devicetype == 'keyboard' then
            for _, b in ipairs(contents.bindings or {}) do
                if b.action == actionStr and ((b.isInverted or false) == (desiredInverted or false)) then
                    return device.devname, b
                end
            end
        end
    end
end

local function rayPointDist(rayPos, rayDir, point)
    local d = point - rayPos
    local proj = math.max(0, d:dot(rayDir))
    return (point - (rayPos + rayDir * proj)):length()
end

-- Builds a rotation matrix from a per-axis euler triple using explicit
-- single-axis matrices multiplied in X, then Y, then Z order (M = Rx*Ry*Rz).
-- This matches the confirmed-correct convention used elsewhere in the engine
-- for vehicle-attached local rotations (see screenService.lua's box/trigger
-- rotation construction), rather than relying on quatFromEuler's internal
-- (and here, unverified) axis composition order.
local function eulerToMatrix(v, isRadians)
    local x = v.x or v[1] or 0
    local y = v.y or v[2] or 0
    local z = v.z or v[3] or 0
    if not isRadians then
        x, y, z = math.rad(x), math.rad(y), math.rad(z)
    end
    local rotX = MatrixF(true)
    local rotY = MatrixF(true)
    local rotZ = MatrixF(true)
    rotX:setFromEuler(vec3(x, 0, 0))
    rotY:setFromEuler(vec3(0, y, 0))
    rotZ:setFromEuler(vec3(0, 0, z))
    local m = rotX:copy()
    m:mul(rotY)
    m:mul(rotZ)
    return m
end

local function getNodeId(vData, nodeStr)
    if type(nodeStr) == 'number' then return nodeStr end
    if not nodeStr or type(vData.vdata.nodes) ~= 'table' then return 0 end
    local n = vData.vdata.nodes[nodeStr]
    if n and n.cid then return n.cid end
    for _, node in pairs(vData.vdata.nodes) do
        if node.id == nodeStr or node.name == nodeStr then return node.cid or 0 end
    end
    return 0
end

local function drawOBBSolid(center, ax, ay, az, r, g, b, a)
    local col = color(math.floor(r*255), math.floor(g*255), math.floor(b*255), math.floor(a*255))
    local p0 = center - ax - ay - az
    local p1 = center + ax - ay - az
    local p2 = center + ax + ay - az
    local p3 = center - ax + ay - az
    local p4 = center - ax - ay + az
    local p5 = center + ax - ay + az
    local p6 = center + ax + ay + az
    local p7 = center - ax + ay + az
    debugDrawer:drawTriSolid(p0, p1, p2, col); debugDrawer:drawTriSolid(p0, p2, p3, col)
    debugDrawer:drawTriSolid(p0, p2, p1, col); debugDrawer:drawTriSolid(p0, p3, p2, col)
    debugDrawer:drawTriSolid(p4, p5, p6, col); debugDrawer:drawTriSolid(p4, p6, p7, col)
    debugDrawer:drawTriSolid(p4, p6, p5, col); debugDrawer:drawTriSolid(p4, p7, p6, col)
    debugDrawer:drawTriSolid(p0, p1, p5, col); debugDrawer:drawTriSolid(p0, p5, p4, col)
    debugDrawer:drawTriSolid(p0, p5, p1, col); debugDrawer:drawTriSolid(p0, p4, p5, col)
    debugDrawer:drawTriSolid(p3, p2, p6, col); debugDrawer:drawTriSolid(p3, p6, p7, col)
    debugDrawer:drawTriSolid(p3, p6, p2, col); debugDrawer:drawTriSolid(p3, p7, p6, col)
    debugDrawer:drawTriSolid(p0, p3, p7, col); debugDrawer:drawTriSolid(p0, p7, p4, col)
    debugDrawer:drawTriSolid(p0, p7, p3, col); debugDrawer:drawTriSolid(p0, p4, p7, col)
    debugDrawer:drawTriSolid(p1, p2, p6, col); debugDrawer:drawTriSolid(p1, p6, p5, col)
    debugDrawer:drawTriSolid(p1, p6, p2, col); debugDrawer:drawTriSolid(p1, p5, p6, col)
end

local function col(row, name, defaultIdx)
    for k, v in pairs(row) do
        if type(k) == 'string' and k:lower() == name:lower() then return v end
    end
    return row[defaultIdx]
end

local function parseTriggersTable(vehId, triggersTable, isTriggers2)
    local vData = core_vehicle_manager.getVehicleData(vehId)
    for _, row in pairs(triggersTable) do
        if type(row) == 'table' then
            local ok, err = pcall(function()
                local rawSize    = col(row, "size", 4)
                local szvec = vec3(1, 1, 1)
                if type(rawSize) == 'table' then
                    szvec = vec3(rawSize.x or rawSize[1] or 1, rawSize.y or rawSize[2] or 1, rawSize.z or rawSize[3] or 1)
                elseif type(rawSize) == 'cdata' then
                    szvec = vec3(rawSize)
                elseif type(rawSize) == 'number' then
                    szvec = vec3(rawSize, rawSize, rawSize)
                end

                local rawBT = col(row, "baseTranslation", 6)
                local btvec = vec3(0, 0, 0)
                if type(rawBT) == 'table' then
                    btvec = vec3(rawBT.x or rawBT[1] or 0, rawBT.y or rawBT[2] or 0, rawBT.z or rawBT[3] or 0)
                elseif type(rawBT) == 'cdata' then
                    btvec = vec3(rawBT)
                end

                local rawBR = col(row, "baseRotation", -1) -- No longer array indexed by default
                local brMat = MatrixF(true)
                if rawBR then
                    brMat = eulerToMatrix(rawBR, isTriggers2)
                end

                local idRef = getNodeId(vData, col(row, "idRef", -1))
                local idX   = getNodeId(vData, col(row, "idX",   -1))
                local idY   = getNodeId(vData, col(row, "idY",   -1))

                local triggerId  = col(row, "id", 1) or col(row, "name", 1)
                local targetProp = col(row, "targetProp", 2)

                if triggerId and triggerId ~= "id" and triggerId ~= "name" then
                    table.insert(triggersByVeh[vehId], {
                        idRef       = idRef,
                        idX         = idX,
                        idY         = idY,
                        baseTrans   = btvec,
                        baseRot     = brMat,
                        halfSize    = szvec * 0.5,
                        triggerType = col(row, "type", 3) or "box",
                        id          = triggerId,
                        targetProp  = targetProp,
                        action      = col(row, "action", 7) or "",
                        meshName    = col(row, "meshName", 5),
                        alpha       = 0,
                        isTriggers2 = isTriggers2,
                    })
                end
            end)
            if not ok then
                jsonWriteFile("propTriggers_debug.json", { ERROR_parseTriggersTable = tostring(err) }, true)
            end
        end
    end
end

local function getCppCenterForTrigger(beObj, vData, triggerId)
    if not vData or not vData.vdata or not vData.vdata.triggers then return nil, nil end
    for _, trg in pairs(vData.vdata.triggers) do
        if trg.name == triggerId and trg.cid ~= nil then
            local to = beObj:getTrigger(trg.cid)
            if to then
                local c = to:getCenter()
                return vec3(c), trg.cid
            end
        end
    end
    return nil, nil
end

-- Build a string-keyed event links dictionary from the propTriggerEventLinks jbeam section.
-- This replicates how the game's processTriggerEventLinks builds triggerEventLinksDict,
-- but uses string trigger IDs (matching propTriggers entries) instead of numeric cids.
local function buildPropTriggerEventLinks(vehId)
    local vData = core_vehicle_manager.getVehicleData(vehId)
    if not vData or not vData.vdata then return end
    propTriggerLinksDict[vehId] = {}
    local linksTable = vData.vdata.propTriggerEventLinks
    if not linksTable then return end

    for _, lnk in pairs(linksTable) do
        if type(lnk) == 'table' then
            local tId = col(lnk, "triggerId", 1)
            local tIn = col(lnk, "triggerInput", 2)
            local iAc = col(lnk, "inputAction", 3)

            if tId and tId ~= "triggerId" and tIn and iAc then
                -- Parse namespace:action format just like triggerEventLinks2
                local namespace, inputActionName = string.match(iAc, "^(%a+):(.*)")
                if namespace == nil then
                    inputActionName = iAc
                    namespace = 'vehicle'
                end

                local entry = {
                    triggerId   = tId,
                    triggerInput = tIn,
                    inputAction = inputActionName,
                    namespace   = namespace,
                    version     = 2,
                    isInverted  = col(lnk, "invert", -1) or false,
                }

                if not propTriggerLinksDict[vehId][tId] then propTriggerLinksDict[vehId][tId] = {} end
                if not propTriggerLinksDict[vehId][tId][tIn] then propTriggerLinksDict[vehId][tId][tIn] = {} end
                table.insert(propTriggerLinksDict[vehId][tId][tIn], entry)
            end
        end
    end
end

-- Execute a single propTrigger event link, replicating the core executeLink logic.
local function executePropLink(vehId, lnk, actionValue)
    local vData = core_vehicle_manager.getVehicleData(vehId)
    if not vData or not vData.vdata then return 0 end

    local value = actionValue
    if lnk.isInverted then value = -value end

    if lnk.namespace == 'vehicle' then
        if not vData.vdata.inputActions or not vData.vdata.inputActions[lnk.inputAction] then
            log('E', logTag, 'input action not found: ' .. tostring(lnk.inputAction))
            return 0
        end
        return core_input_actions.executeCommand(vData.vdata.inputActions[lnk.inputAction], value, vehId)
    elseif lnk.namespace == 'common' then
        -- Check if this common action has a Lua binding in the vehicle's inputActions
        if vData.vdata.inputActions and vData.vdata.inputActions[lnk.inputAction] then
            return core_input_actions.executeCommand(vData.vdata.inputActions[lnk.inputAction], value, vehId)
        end
        -- Otherwise invoke C++ actionmap binding
        local triggeredCount = ActionMap.triggerBindingByNameDigital(lnk.inputAction, actionValue > 0.9, os.clockhp(), vehId)
        return triggeredCount or 0
    end
    return 0
end

-- Fire all propTriggerEventLinks for a given trigger ID and action string.
local function firePropTriggerEvent(vehId, triggerId, actionStr, actionValue)
    local vehLinks = propTriggerLinksDict[vehId]
    if not vehLinks then return end
    local trgLinks = vehLinks[triggerId]
    if not trgLinks then return end
    local actionLinks = trgLinks[actionStr]
    if not actionLinks then return end
    for _, lnk in ipairs(actionLinks) do
        executePropLink(vehId, lnk, actionValue)
    end
end

local cachedOBJs = {}

local function loadOBJ(filepath)
    if cachedOBJs[filepath] then return cachedOBJs[filepath] end
    
    local f = io.open(filepath, "r")
    if not f then
        log('E', logTag, "Could not open OBJ file: " .. tostring(filepath))
        return nil
    end

    local verts = {}
    local tris = {}

    for line in f:lines() do
        local type, rest = line:match("^%s*(%S+)%s+(.*)$")
        if type == "v" then
            local x, y, z = rest:match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
            if x and y and z then
                table.insert(verts, vec3(tonumber(x), tonumber(y), tonumber(z)))
            end
        elseif type == "f" then
            local faceVerts = {}
            for vstr in rest:gmatch("%S+") do
                local vidx = vstr:match("^(%d+)")
                if vidx then
                    table.insert(faceVerts, tonumber(vidx))
                end
            end
            -- Triangulate simple polygons (fan triangulation)
            if #faceVerts >= 3 then
                for i = 2, #faceVerts - 1 do
                    local v1 = verts[faceVerts[1]]
                    local v2 = verts[faceVerts[i]]
                    local v3 = verts[faceVerts[i+1]]
                    if v1 and v2 and v3 then
                        table.insert(tris, {v1, v2, v3})
                    end
                end
            end
        end
    end
    f:close()

    cachedOBJs[filepath] = tris
    return tris
end

local function loadMeshTriggersOBJ(vehId)
    local triggers = triggersByVeh[vehId]
    if not triggers then return end
    
    local vData = core_vehicle_manager.getVehicleData(vehId)
    if not vData then return end
    
    local vehDir = vData.dir or vData.vehicleDirectory
    if not vehDir then return end
    
    for _, trg in ipairs(triggers) do
        if trg.targetProp and trg.targetProp ~= "" then
            if vData.vdata.props then
                for _, prop in pairs(vData.vdata.props) do
                    if prop.mesh == trg.targetProp then
                        trg._targetPropId = prop.pid
                        if not trg.meshName or trg.meshName == "" then
                            trg.meshName = prop.mesh
                        end
                        break
                    end
                end
            end
            if not trg._targetPropId then
                log('E', logTag, "Trigger " .. tostring(trg.id) .. " targetProp '" .. tostring(trg.targetProp) .. "' not found in vehicle props!")
            end
        end

        if trg.triggerType == "mesh" and trg.meshName then
            local meshNameStr = type(trg.meshName) == "table" and trg.meshName[1] or trg.meshName
            if type(meshNameStr) == "string" then
                local meshPath = meshNameStr
                if not meshPath:lower():match("%.obj$") then
                    meshPath = meshPath .. ".obj"
                end
                
                if not meshPath:match("^/?vehicles/") then
                    if string.sub(meshPath, 1, 1) == "/" then
                        meshPath = string.sub(meshPath, 2)
                    end
                    meshPath = vehDir .. meshPath
                end
                if string.sub(meshPath, 1, 1) == "/" then
                    meshPath = string.sub(meshPath, 2)
                end
                trg._debugMeshPath = meshPath
                local verts = loadOBJ(meshPath)
                trg.meshVerts = verts
                
                if verts and #verts > 0 then
                    local minB = vec3(math.huge, math.huge, math.huge)
                    local maxB = vec3(-math.huge, -math.huge, -math.huge)
                    for _, tri in ipairs(verts) do
                        for i=1, 3 do
                            local v = tri[i]
                            minB.x = math.min(minB.x, v.x)
                            minB.y = math.min(minB.y, v.y)
                            minB.z = math.min(minB.z, v.z)
                            maxB.x = math.max(maxB.x, v.x)
                            maxB.y = math.max(maxB.y, v.y)
                            maxB.z = math.max(maxB.z, v.z)
                        end
                    end
                    local extents = maxB - minB
                    local objCenter = (maxB + minB) * 0.5
                    
                    local meshScale = trg.halfSize * 2
                    trg._meshScale = meshScale
                    trg.halfSize = vec3(extents.x * meshScale.x, extents.y * meshScale.y, extents.z * meshScale.z) * 0.5
                    trg._meshBoxCenterOffset = vec3(objCenter.x * meshScale.x, objCenter.y * meshScale.y, objCenter.z * meshScale.z)
                end
            else
                log('E', logTag, "Trigger " .. tostring(trg.id) .. " has an invalid meshName. Did you forget to add the mesh string at column 7 in your JBeam?")
            end
        end
    end
end

local function loadTriggersFromJBeam(vehId)
    local vData = core_vehicle_manager.getVehicleData(vehId)
    if not vData or not vData.vdata then return end
    triggersByVeh[vehId] = {}
    if vData.vdata.propTriggers then parseTriggersTable(vehId, vData.vdata.propTriggers, false) end
    if vData.vdata.triggers2    then parseTriggersTable(vehId, vData.vdata.triggers2,    true)  end
    buildPropTriggerEventLinks(vehId)
    loadMeshTriggersOBJ(vehId)
end



local function onVehicleSpawned(vehId)
    loadTriggersFromJBeam(vehId)
end

local function onVehicleDestroyed(vehId)
    triggersByVeh[vehId] = nil
    propTriggerLinksDict[vehId] = nil
end

local function onVehicleSwitched(oldVeh, newVeh, player)
    if newVeh then loadTriggersFromJBeam(newVeh) end
end

local function onCursorVisibilityChanged(visible)
    cursorVisible = visible
end

local function onPreRender(dt)
    if not cursorVisible then return end
    local ray = getCameraMouseRay()
    if not ray then return end
    
    local propTriggers_globalActionsToDraw = nil
    local im = ui_imgui
    if im.GetIO().WantCaptureMouse then return end

    if not initializedVehicles then
        initializedVehicles = true
        for i = 0, be:getObjectCount()-1 do
            local v = be:getObject(i)
            if v then loadTriggersFromJBeam(v:getID()) end
        end
    end

    for vehId, triggers in pairs(triggersByVeh) do
        local ok, err = pcall(function()
            local beObj = be:getObjectByID(vehId)
            local stObj = scenetree.findObject(vehId)
            if not beObj or not stObj then return end

            local rawRefPhys = beObj:getNodePosition(beObj:getRefNodeId())
            if not rawRefPhys then return end
            local pRefNodePhys = vec3(rawRefPhys)

            local currentRefPos = stObj:getPosition()
            if not currentRefPos then return end

            local vData = core_vehicle_manager.getVehicleData(vehId)
            


            local hoveredId   = nil
            local closestDist = math.huge

            for _, trg in ipairs(triggers) do
                local center, ax, ay, az



                if trg._targetPropId then
                    local propObj = beObj:getProp(trg._targetPropId)
                    if not propObj then goto skip_trg end
                    local worldMat = propObj:getLiveTransformWorld()
                    
                    local tempMat = MatrixF(true)
                    tempMat:setColumn(0, worldMat:getColumn(0))
                    tempMat:setColumn(1, worldMat:getColumn(1))
                    tempMat:setColumn(2, worldMat:getColumn(2))
                    tempMat:mul(trg.baseRot)
                    
                    ax = tempMat:getColumn(0)
                    ay = tempMat:getColumn(1)
                    az = tempMat:getColumn(2)
                    
                    local baseCenter = worldMat:getColumn(3) + vec3(currentRefPos)
                    center = baseCenter + ax*trg.baseTrans.x + ay*trg.baseTrans.y + az*trg.baseTrans.z
                elseif trg.targetProp and trg.targetProp ~= "" then
                    goto skip_trg
                else
                    local rawPRef = beObj:getNodePosition(trg.idRef)
                    if not rawPRef then goto skip_trg end
                    local pRef = vec3(rawPRef)

                    local refMat = stObj:getRefNodeMatrix()
                    if not refMat then goto skip_trg end

                    local offsetFromRef = pRef - pRefNodePhys
                    local pRefWorld = vec3(refMat:getPosition()) + offsetFromRef

                    local mat = MatrixF(true)

                    if trg.idX == 0 or trg.idY == 0 then
                        mat:setPosition(pRefWorld)
                    else
                        local rawPX = beObj:getNodePosition(trg.idX)
                        local rawPY = beObj:getNodePosition(trg.idY)
                        if not rawPX or not rawPY then goto skip_trg end

                        local pX = vec3(rawPX)
                        local pY = vec3(rawPY)
                        trg._pX = { x=pX.x, y=pX.y, z=pX.z }
                        trg._pY = { x=pY.x, y=pY.y, z=pY.z }

                        local dirX = (pX - pRef):normalized()
                        local dirY = (pY - pRef):normalized()

                        if trg.triggerType == "mesh" then
                            local refRotX = refMat:getColumn(0)
                            local refRotY = refMat:getColumn(1)
                            local refRotZ = refMat:getColumn(2)

                            if not trg._meshInitialLocalDirX then
                                trg._meshInitialLocalDirX = vec3(dirX:dot(refRotX), dirX:dot(refRotY), dirX:dot(refRotZ))
                                trg._meshInitialLocalDirY = vec3(dirY:dot(refRotX), dirY:dot(refRotY), dirY:dot(refRotZ))
                            end

                            dirX = (refRotX * trg._meshInitialLocalDirX.x + refRotY * trg._meshInitialLocalDirX.y + refRotZ * trg._meshInitialLocalDirX.z):normalized()
                            dirY = (refRotX * trg._meshInitialLocalDirY.x + refRotY * trg._meshInitialLocalDirY.y + refRotZ * trg._meshInitialLocalDirY.z):normalized()
                        end

                        local dirZ = dirX:cross(dirY):normalized()
                        dirY = dirZ:cross(dirX):normalized()

                        if dirX:squaredLength() < 0.0001 then dirX = vec3(1, 0, 0) end
                        if dirY:squaredLength() < 0.0001 then dirY = vec3(0, 1, 0) end
                        if dirZ:squaredLength() < 0.0001 then dirZ = vec3(0, 0, 1) end

                        mat:setColumn(0, dirX)
                        mat:setColumn(1, dirZ)
                        mat:setColumn(2, dirY)
                        mat:setPosition(pRefWorld)
                    end

                    mat:mul(trg.baseRot)

                    local worldTrans = mat:getColumn(0) * trg.baseTrans.x
                                     + mat:getColumn(1) * trg.baseTrans.y
                                     + mat:getColumn(2) * trg.baseTrans.z
                    mat:setPosition(mat:getPosition() + worldTrans)

                    center = mat:getPosition()
                    ax = mat:getColumn(0)
                    ay = mat:getColumn(1)
                    az = mat:getColumn(2)
                end
                local hx, hy, hz = trg.halfSize.x, trg.halfSize.y, trg.halfSize.z

                if trg._prevDrawCenter then
                    local hitCenter = trg._prevDrawCenter
                    if trg._meshBoxCenterOffset then
                        hitCenter = hitCenter + trg._prevAx * trg._meshBoxCenterOffset.x
                                              + trg._prevAy * trg._meshBoxCenterOffset.y
                                              + trg._prevAz * trg._meshBoxCenterOffset.z
                    end
                    local hitDist = intersectsRay_OBB(ray.pos, ray.dir, hitCenter, trg._prevAx*hx, trg._prevAy*hy, trg._prevAz*hz)
                    if hitDist < 5 and hitDist < closestDist then
                        closestDist = hitDist
                        hoveredId = trg.id
                    end
                end

                trg._prevAx = ax; trg._prevAy = ay; trg._prevAz = az
                trg._center = center
                trg._ax = ax; trg._ay = ay; trg._az = az



                ::skip_trg::
            end


            for _, trg in ipairs(triggers) do
                if not trg._center then goto skip_draw end

                local drawCenter = trg._center
                trg._prevDrawCenter = drawCenter
                local hx, hy, hz = trg.halfSize.x, trg.halfSize.y, trg.halfSize.z
                local maxH = math.max(hx, hy, hz)
                local isHovered = (hoveredId == trg.id)
                local rDist = rayPointDist(ray.pos, ray.dir, drawCenter)
                
                local coreDist = math.max(0.03, maxH)
                local fadeDist = math.max(0.30, maxH + 0.27)
                local proximity = 1 - math.max(0, math.min(1, (rDist - coreDist) / (fadeDist - coreDist)))
                
                local tr, tg, tb = 0.35, 0.51, 0.76
                local targetAlpha = 0.28 * proximity

                if isHovered and im.IsMouseDown(0) then
                    tr, tg, tb, targetAlpha = 0.10, 1.00, 0.40, 1.00
                elseif isHovered then
                    tr, tg, tb, targetAlpha = 0.10, 0.75, 0.30, 0.28
                end

                trg.alpha = trg.alpha + (targetAlpha - trg.alpha) * math.min(1, dt * 10)

                if trg.triggerType == "sphere" then
                    if trg.alpha < 0.004 then goto skip_draw end
                    local cF = ColorF(tr, tg, tb, trg.alpha)
                    debugDrawer:drawSphere(drawCenter, hx, cF)
                elseif trg.triggerType == "mesh" then
                    if trg.meshVerts then
                        if trg.alpha < 0.004 then goto skip_draw end
                        local col = color(math.floor(tr*255), math.floor(tg*255), math.floor(tb*255), math.floor(trg.alpha*255))
                        local sx = trg._meshScale and trg._meshScale.x or (hx * 2)
                        local sy = trg._meshScale and trg._meshScale.y or (hy * 2)
                        local sz = trg._meshScale and trg._meshScale.z or (hz * 2)
                        local ax, ay, az = trg._ax, trg._ay, trg._az
                        for i=1, #trg.meshVerts do
                            local tri = trg.meshVerts[i]
                            local tv1, tv2, tv3 = tri[1], tri[2], tri[3]
                            
                            local v1 = drawCenter + ax*(tv1.x*sx) + ay*(tv1.y*sy) + az*(tv1.z*sz)
                            local v2 = drawCenter + ax*(tv2.x*sx) + ay*(tv2.y*sy) + az*(tv2.z*sz)
                            local v3 = drawCenter + ax*(tv3.x*sx) + ay*(tv3.y*sy) + az*(tv3.z*sz)
                            
                            debugDrawer:drawTriSolid(v1, v2, v3, col)
                        end
                    end
                else
                    if trg.alpha < 0.004 then goto skip_draw end
                    drawOBBSolid(drawCenter, trg._ax*hx, trg._ay*hy, trg._az*hz, tr, tg, tb, trg.alpha)
                end

                ::skip_draw::
            end

            -- ── Show title + key binding legend on hover (like native triggers) ──
            local actionsListToDraw = nil
            if hoveredId then
                local vehLinks = propTriggerLinksDict[vehId]
                if vehLinks and vehLinks[hoveredId] and vehLinks[hoveredId]['action0'] then
                    local lnk = vehLinks[hoveredId]['action0'][1]
                    if lnk then
                        local vData = extensions.core_vehicle_manager.getVehicleData(vehId)
                        local actionName = lnk.inputAction
                        
                        local action = nil
                        if vData and vData.vdata and vData.vdata.inputActions then
                            action = vData.vdata.inputActions[actionName]
                        end
                        if not action and core_input_actions and core_input_actions.getActiveActions then
                            local activeActions = core_input_actions.getActiveActions()
                            if activeActions then action = activeActions[actionName] end
                        end

                        if action then
                            local actionStr = actionName
                            if lnk.namespace == 'vehicle' and action.vehicle then
                                actionStr = action.vehicle .. '__' .. actionStr
                            end

                            local desiredInverted = lnk.isInverted == true
                            local keyboardDev, keyboardBinding = findKeyboardBindingForAction(actionStr, desiredInverted)

                            local actionItem = {}
                            if type(action) == 'table' then
                                for k, v in pairs(action) do actionItem[k] = v end
                            end
                            actionItem.action = actionStr
                            actionItem.label = action.title

                            if keyboardBinding and keyboardDev then
                                actionItem.bindings = {{ device = keyboardDev, control = keyboardBinding.control }}
                            end
                            actionsListToDraw = { actionItem }
                        end
                    end
                end
            end

            -- Instead of updating the UI immediately here (which gets overwritten by subsequent vehicles), we save it
            if actionsListToDraw then
                propTriggers_globalActionsToDraw = actionsListToDraw
            end

            -- ── Click handling ──
            if hoveredId and cursorVisible then
                if im.IsMouseClicked(0) then
                    for _, trg in ipairs(triggers) do
                        if trg.id == hoveredId then
                            firePropTriggerEvent(vehId, trg.id, 'action0', 1)
                            break
                        end
                    end
                end

                if im.IsMouseReleased(0) then
                    for _, trg in ipairs(triggers) do
                        if trg.id == hoveredId then
                            -- Legacy: still execute hardcoded action string if present
                            if trg.action and trg.action ~= "" then
                                beObj:queueLuaCommand(string.format('%s', trg.action))
                            end
                            firePropTriggerEvent(vehId, trg.id, 'action0', 0)
                            break
                        end
                    end
                end
            end
        end)

        if not ok then
            log('E', logTag, 'Error in onPreRender for vehicle ' .. tostring(vehId) .. ': ' .. tostring(err))
        end
    end

    if extensions.ui_bindingsLegend then
        if propTriggers_globalActionsToDraw then
            extensions.ui_bindingsLegend.addActions('propTriggers', propTriggers_globalActionsToDraw, { priority = 11, hideConstant = true })
        else
            extensions.ui_bindingsLegend.addActions('propTriggers', {})
        end
    end
end

local function onExtensionLoaded()
end

local function onExtensionUnloaded()
end

M.onExtensionLoaded         = onExtensionLoaded
M.onExtensionUnloaded       = onExtensionUnloaded
M.onPreRender               = onPreRender
M.onVehicleSpawned          = onVehicleSpawned
M.onVehicleDestroyed        = onVehicleDestroyed
M.onVehicleSwitched         = onVehicleSwitched
M.onCursorVisibilityChanged = onCursorVisibilityChanged
return M
