------------------------------------------------------------------------
-- ProfileStoreService Testing
------------------------------------------------------------------------

--!nocheck

local server = game:GetService("ServerScriptService")

-- deep
local function tablesAreEqual(a, b): boolean
    if type(a) ~= "table" or type(b) ~= "table" then warn("OPERANDS ARE NOT TABLES") end
    if #a ~= #b then return false end

    for i, v in next, a do
        if type(b[i]) == "table" and type(v) == "table" then 
            if tablesAreEqual(b[i], v) == false then return false end   
        elseif b[i] ~= v then
            return false
        end
    end

    for i, v in next, b do
        if type(a[i]) == "table" and type(v) == "table" then 
            if tablesAreEqual(a[i], v) == false then return false end   
        elseif a[i] ~= v then
            return false
        end
    end

    return true
end

-- shallow
local function tablesAreEqualType(a, b)
    for i, v in next, a do
        if type(v) ~= type(b[i]) then
            return false
        end
    end

    for i, v in next, b do
        if type(v) ~= type(a[i]) then
            return false
        end
    end

    return true
end

local function checkForError(fn, ...)
    local success, err_msg = pcall(fn, ...)
    return success == false and err_msg
end

local function freeAsync(profile)
    profile:Free()
    repeat wait() until not profile:IsLoaded()
end

local TEST, CASE, CHECK = require(script.Parent.UTest)()

local JOB_ID = game.JobId
local PLACE_ID = game.PlaceId

local expectedMetadataShape = {
    ActiveSession = nil,
    CreatedTime = os.time(),
    LoadedCount = 0,
    LoadedTime = 0,
    NewPendingUpdate = false,

    UserIds = {},
    Version = "",
    KeyCreatedTime = 0,
    UpdatedTime = 0
}
local expectedMetadataShapeWithActiveSession = table.clone(expectedMetadataShape)
expectedMetadataShapeWithActiveSession.ActiveSession = {}

local dataTemplateA = {
    Level = 1,
    Cash = 100,
    Stuff = {
        "Stick"
    }
}

local bufferTemplateA = {
    DonatedCash = 0,
    GiftedStuff = {}
}

--[[
    Test outline:
    
    Test A: General testing
        1. Getting a profilestore with incorrect arguments
        2. Getting a profilestore with correct arguments
        3. Loading a profile
        4. Verify profile has correct table shapes (data, pendingUpdateData, metadata)
        5. Check `profile:IsLoaded()`
        6. Remove profile without freeing then reload to test lock handler
        7. Free profile and check acive session
        8. Attempt to update profile, ensure error
        9. Viewing a profile and checking if free worked properly
        10. Viewing a non-existent profile
        11. EditAsync an unloaded existing profile, view profile and verify success
        12. EditAsync a loaded profile, verify error
        13. EditAsync a new profile, view profile and verify EditAsync worked
        14. WipeAsync existing profile then load profile to verify it was properly wiped
    
    Test B: Profile pending update testing
        1. Load new profile, create pending update, update profile, verify update was received, add another pending update, free profile, verify update was not processed
        2. Add another pending update to same profile, load profile and update, verify update was received
        3. Add pending update for non existent profile, view profile, confirm nil, load profile and verify pending update received

    Test C: Profile overwrite testing
        0. Load a profile, modifiy data, call update, modify data, free profile
        1. Load profile versions, check all versions
        2. Overwrite with second latest version, Load profile again, verify profile states are the same
        3. Overwrite third last version again while profile is loaded, verify that the profile is automatically removed without saving
        4. Load profile again, verify profile states are the same
        5. Test iterator

    Test D: Edge Cases, exceptions and misuse testing
        -- 1. Set datastore id to non table value then load for first time with profilestoreservice then free
        -- 2. call loadasync twice in quick succession
        -- 3. Wipe data of loaded profile then call Update
        -- 4. Set profile data to non-table, load profile
        -- 5. Set illegal keys for profile metadata, load profile
]]

local ProfileStoreService = require(server.ProfileStoreService)
ProfileStoreService.AutosaveEnabled = false

local time = os.time()

do TEST "Test A"
    local testStore = ProfileStoreService:GetProfileStore("A"..time, dataTemplateA, bufferTemplateA)

    do CASE "1"
        local err_msg = checkForError(function() ProfileStoreService:GetProfileStore() end)
        CHECK(err_msg)
        err_msg = checkForError(function() ProfileStoreService:GetProfileStore("name") end)
        CHECK(err_msg)
    end

    do CASE "2"
        CHECK(testStore)
    end

    local profile = testStore:LoadAsync("A1")

    do CASE "3"
        CHECK(profile)
    end

    do CASE "4"
        CHECK(tablesAreEqual(profile.Data, dataTemplateA))
        CHECK(tablesAreEqual(profile._BufferData, bufferTemplateA))
        CHECK(tablesAreEqualType(profile._Metadata, expectedMetadataShapeWithActiveSession))
    end

    do CASE "5"
        CHECK(profile:IsLoaded())
    end

    do CASE "6"
        profile:_Remove()
        --CHECK(not profile:IsLoaded())
        profile = testStore:LoadAsync("A1", function(sessionInfo)
            CHECK(sessionInfo.JobId == JOB_ID)
            CHECK(sessionInfo.PlaceId == PLACE_ID)
            return true
        end)
        CHECK(profile)
    end

    do CASE "7"
        freeAsync(profile)
        CHECK(not profile:IsLoaded())
        CHECK(not profile:GetInfo().ActiveSession)
    end

    do CASE "8"
        CHECK(checkForError(profile.Update, profile))    
    end

    do CASE "9"
        local view = testStore:ViewAsync("A1")
        CHECK(view:GetInfo().ActiveSession == nil)
        CHECK(tablesAreEqual(view.Data, profile.Data))
        CHECK(tablesAreEqual(view._Metadata, profile._Metadata))
    end

    do CASE "10"
        CHECK(testStore:ViewAsync("A_nonexistent") == nil)
    end

    do CASE "11"
        CHECK(testStore:EditAsync("A1", function(data)
            data.Level += 1
        end))
        CHECK(testStore:ViewAsync("A1").Data.Level == 2)
    end

    do CASE "12"
        local tmp = testStore:LoadAsync("A1")
        local tmp2, err = testStore:EditAsync("A1", function() end)
        CHECK(tmp2 == nil)
        CHECK(type(err) == "string")
        tmp:Free()
    end

    do CASE "13"
        local tmp = testStore:EditAsync("A2", function(data)
            CHECK(data.Cash == dataTemplateA.Cash)
            CHECK(data.Level == dataTemplateA.Level)
            CHECK(data.Stuff[1] == dataTemplateA.Stuff[1])
            table.insert(data.Stuff, "apple")
        end)
        CHECK(tmp.Data.Stuff[2] == "apple")

        tmp = testStore:ViewAsync("A2")
        CHECK(tmp.Data.Stuff[2] == "apple")
    end

    do CASE "14"
        local tmp = testStore:WipeAsync("A1")
        CHECK(tmp.Data.Level == 2)
        local createdTime = tmp:GetInfo().CreatedTime
        tmp = testStore:LoadAsync("A1")
        CHECK(tmp.Data.Level == 1)
        CHECK(tmp:GetInfo().CreatedTime ~= createdTime)
    end
end

do TEST "B"
    local testStore = ProfileStoreService:GetProfileStore("B"..time, dataTemplateA, bufferTemplateA)

    do CASE "1" 
        local profile = testStore:LoadAsync("B1")
        CHECK(profile.Data.Cash == 100)
        local success = testStore:PendingUpdateAsync("B1", function(data)
            data.DonatedCash += 1000
        end)
        CHECK(success)
        local pendingUpdateState;
        profile:OnPendingUpdate(function(pending)
            profile.Data.Cash += pending.DonatedCash
            pending.DonatedCash = 0
            pendingUpdateState = table.clone(pending)
        end)
        profile:_UpdateAsync()
        CHECK(profile.Data.Cash == 1100)
        CHECK(tablesAreEqual(profile._BufferData, pendingUpdateState))
        CHECK(tablesAreEqual(profile._BufferData, bufferTemplateA)) -- buffer data back to normal after manual clear

        testStore:PendingUpdateAsync("B1", function(data)
            data.DonatedCash += 10
        end)

        freeAsync(profile)
        CHECK(profile.Data.Cash == 1100)
        CHECK(profile._BufferData.DonatedCash == 10)
        CHECK(profile:IsLoaded() == false)
    end

    do CASE "2"
        local success = testStore:PendingUpdateAsync("B1", function(data)
            table.insert(data.GiftedStuff, "Spanner")
        end)
        CHECK(success)

        local profile = testStore:LoadAsync("B1")
        profile:OnPendingUpdate(function(pending)
            for i, v in pending.GiftedStuff do
                profile.Data.Cash += pending.DonatedCash
                pending.DonatedCash = 0
                table.insert(profile.Data.Stuff, v)
                table.clear(pending.GiftedStuff)
            end
        end)
        profile:_UpdateAsync()
        CHECK(profile.Data.Cash == 1110)
        CHECK(profile.Data.Stuff[2] == "Spanner")
    end

    do CASE "3" 
        local success = testStore:PendingUpdateAsync("B2", function(data)
            CHECK(tablesAreEqual(data, bufferTemplateA))
            data.DonatedCash += 1
        end)
        CHECK(success)

        CHECK(testStore:ViewAsync("B2") == nil)

        local profile = testStore:LoadAsync("B2")
        profile:OnPendingUpdate(function(pending)
            profile.Data.Cash += pending.DonatedCash
            pending.DonatedCash = 0
        end)
        profile:_UpdateAsync()
        CHECK(profile.Data.Cash == 101)
        freeAsync(profile)
    end
end

do TEST "C"
    local testStore = ProfileStoreService:GetProfileStore("C"..time, dataTemplateA, bufferTemplateA)

    do CASE "Setup"
        local profile = testStore:LoadAsync("C1") -- v1
        profile.Data.Cash = 500 
        profile:_UpdateAsync() -- v2
        profile.Data.Cash = 750 
        freeAsync(profile) -- v3
        CHECK(profile:IsLoaded() == false)
    end

    do CASE "1"
        local versionList = testStore:ListVersionsAsync("C1")
        local i = 0
        repeat local profile = versionList:NextAsync()
            i += 1
            if i == 3 then
                CHECK(profile.Data.Cash == 750)
            elseif i == 2 then
                CHECK(profile.Data.Cash == 500)
            elseif i == 1 then
                CHECK(profile.Data.Cash == 100)
            end
        until profile == nil
        CHECK(i == 4)
    end

    local profile

    do CASE "2"
        local versionList = testStore:ListVersionsAsync("C1")
        local version = versionList:NextAsync() -- 1
        testStore:OverwriteAsync("C1", version) -- v4
        profile = testStore:LoadAsync("C1", function() return true end) -- v5
        CHECK(profile.Data.Cash == 100)
    end

    do CASE "3"
        local versionList = testStore:ListVersionsAsync("C1")
        versionList:NextAsync() -- 1
        local version = versionList:NextAsync() -- 2
        testStore:OverwriteAsync("C1", version) -- v6
        local currentVer = profile:GetInfo().Version
        profile:_UpdateAsync() -- v6 (unchanged)
        CHECK(profile:IsLoaded() == false) -- ensure that profile will be removed
        CHECK(profile.Data.Cash == 100)
        CHECK(profile:GetInfo().Version == currentVer)
    end

    do CASE "4"
        profile = testStore:LoadAsync("C1") -- v7
        CHECK(profile.Data.Cash == 500)
        freeAsync(profile) -- v8
    end

    do CASE "5"
        local versionList = testStore:ListVersionsAsync("C1")
        local count = 0
        for i, v in versionList do
            count += 1
        end
        CHECK(count == 8)
    end
end

do TEST "D"
    local testStore = ProfileStoreService:GetProfileStore("D"..time, dataTemplateA, bufferTemplateA)   

    do CASE "1"
        testStore._DataStore:SetAsync("D1", 10)
        local profile = testStore:LoadAsync("D1")
        CHECK(profile)
        freeAsync(profile)
    end

    do CASE "2"
        local p1
        task.spawn(function()
            -- TODO: sometimes p1 returns nil and p2 returns the profile, investigate why
            p1 = testStore:LoadAsync("D1")
        end)

        local p2 = testStore:LoadAsync("D1")
        CHECK(p1)
        CHECK(not p2)
        p1:Free()
    end

    do CASE "3"
        local profile = testStore:LoadAsync("D2")
        profile.Data.Cash = 1000
        testStore:WipeAsync("D2")
        profile:_UpdateAsync()
        CHECK(not profile:IsLoaded())
    end

    do CASE "4"
        testStore._DataStore:SetAsync("D2", 1)
        local profile = testStore:LoadAsync("D2")
        CHECK(profile.Data.Cash == 100)
        profile.Data.Cash = 110
        freeAsync(profile)
    end

    do CASE "5"
        testStore._DataStore:UpdateAsync("D2", function()
            return {}, {}, {test = true, LoadedCount = true}
        end)
        local profile = testStore:LoadAsync("D2")
        CHECK(profile)
        CHECK(rawget(profile._Metadata, "test") == nil)
        CHECK(type(profile._Metadata.LoadedCount) == "number")
        CHECK(profile.Data.Cash == 100)
    end
end

TEST "END" 

return nil