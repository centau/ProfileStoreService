------------------------------------------------------------------------
-- ProfileStoreService.lua
-- @version 0.1.0
-- @author centau_ri
------------------------------------------------------------------------

--!strict

--[[
    todo:
    pending updates
    checks for edge cases
    debugging
    proper updateasync type
    proper error messages
    clean up type annotations; a lot of hacky things were done to overcome current typechecking limitations
    ensure UpdateAsync transform functions are pure
]]

------------------------------------------------------------------------
-- Typedefs
------------------------------------------------------------------------

-- table types
type table = {[any]: any}
type Array<T> = {[number]: T}
type Map<T, U> = {[T]: U}

type ProfileData<Data, Buffer> = {Data | Buffer}

type UserDefinedMetadata = {
    CreatedTime: number;
	LoadedCount: number;
    LoadedTime: number,
    NewPendingUpdate: boolean;
	ActiveSession: ProfileSessionInfo?;
}

export type ProfileSessionInfo = {
    JobId: string;
    PlaceId: number;
    StartedTime: number;
}

-- function types
type UpdateHandler<T, U> = (data: ProfileData<T, U>, keyInfo: DataStoreKeyInfo) -> (ProfileData<T, U>?, Array<number>?, UserDefinedMetadata?)
type LockHandler = (sessionInfo: ProfileSessionInfo) -> boolean
type MetadataTransform = (metadata: UserDefinedMetadata) -> ()
type DataTransform<T> = (data: T) -> ()

-- class types
type ProfileStoreService = {
    ServiceError: RDLScriptSignal<string, string, string>;
    AutosaveEnabled: boolean;
    AutomaticRetry: boolean;
    GetProfileStore: <Data, Buffer>(ProfileStoreService, name: string, dataTemplate: Data, bufferTemplate: Buffer?) -> ProfileStore<Data, Buffer>;
}

type _ProfileStore<T, U> = ProfileStore<T, U> & {
    _DataTemplate: T;
    _BufferTemplate: U;
    _DataStore: DataStore;
    _UpdateAsync: (ProfileStore<T, U>, id: string, transform: UpdateHandler<T, U>) -> (boolean, ProfileData<T, U>?|string, DataStoreKeyInfo);
    _ProcessProfileData: (ProfileStore<T, U>, data: ProfileData<T, U>?, keyInfo: DataStoreKeyInfo?) -> (ProfileData<T, U>, Array<number>, UserDefinedMetadata)
}
export type ProfileStore<T = any, U = any> = {
    Name: string;
    LoadAsync: (ProfileStore<T, U>, id: string, lockHandler: LockHandler?, forceload: boolean?) -> (Profile<T, U>?, string?);
    ViewAsync: (ProfileStore<T, U>, id: string, version: string?) -> (Profile<T, U>?, string?);
    OverwriteAsync: (ProfileStore<T, U>, id: string, newProfile: Profile<T, U>) -> (Profile<T, U>?, string?);
    WipeAsync: (ProfileStore<T, U>, id: string) -> (Profile<T, U>?, string?);
    ListVersionsAsync: (ProfileStore<T, U>, id: string, sortDirection: Enum.SortDirection?, minTime: number?, maxTime: number?) -> (ProfileVersionList<T, U>?, string?);
    PendingUpdateAsync: (ProfileStore<T, U>, id: string, transform: DataTransform<U>) -> (boolean, string?);
}

type _Profile<T, U> = Profile<T, U> & {
    _Metadata: _ProfileInfo;
    _GetPendingUpdateHandler: (_Profile<T, U>) -> ((U) -> ())?;
    _UpdateAsync: (_Profile<T, U>, optional: MetadataTransform?) -> ();
    _Remove: (_Profile<T, U>) -> ();
    _ProfileStore: _ProfileStore<T, U>;
    _BufferData: U;
}
export type Profile<T = any, U = any> = {
    Id: string;
    Data: T;
    Removed: RDLScriptSignal<>;

    AddUserId: (id: number) -> ();
    RemoveUserId: (id: number) -> ();
    OnPendingUpdate: (Profile<T, U>, pendingData: U) -> ();
    Update: (Profile<T, U>) -> ();
    Free: (Profile<T, U>) -> ();
    GetInfo: (Profile<T, U>) -> ProfileInfo;
    IsLoaded: (Profile<T, U>) -> boolean;
}

type _ProfileInfo = ProfileInfo & {
    _Split: (ProfileInfo) -> (Array<number>, UserDefinedMetadata);
    _Clone: (ProfileInfo) -> ProfileInfo;
}
export type ProfileInfo = UserDefinedMetadata & {
    -- DataStoreKeyInfo properties
    KeyCreatedTime: number;
    UpdatedTime: number;
    Version: string;
    UserIds: Array<number>;
}

export type ProfileKeyMetadata = {
    CreatedTime: number;
	LoadedCount: number;
    TimeLoaded: number;
    ActiveSession: ProfileSessionInfo?;
}

type _ProfileVersionList<T, U> = ProfileVersionList<T, U> & {
    _Id: string;
    _DataStoreVersionPages: DataStoreVersionPages;
    _ProfileStore: _ProfileStore<T, U>;
    _CurrentPage: Array<DataStoreObjectVersionInfo>;
    _CurrentPagePosition: number;
}
export type ProfileVersionList<T, U> = {
    Index: number;
    NextAsync: (ProfileVersionList<T, U>) -> (Profile<T, U>?, string?);
}

export type RDLScriptConnection = {
    IsConnected: (RDLScriptConnection) -> boolean;
    Disconnect: (RDLScriptConnection) -> ();
}

export type RDLScriptSignal<T...> = {
    Connect: (RDLScriptSignal<T...>, callback: (T...) -> ()) -> RDLScriptConnection;
    Wait: (RDLScriptSignal<T...>) -> T...;
    _Fire: (RDLScriptSignal<T...>, T...) -> ();
    DisconnectAll: (RDLScriptSignal<T...>) -> ();
}

------------------------------------------------------------------------
-- Private variables
------------------------------------------------------------------------

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

local PLACE_ID = game.PlaceId
local JOB_ID = game.JobId

local DATA = 1
local BUFFER = 2

local SETTINGS = {
    AUTOSAVE_INTERVAL = 30,
    REMOTE_UNLOCK_TOPIC = "ProfileStoreServiceRemoteUnlock",

    SET_DELAY = 6,
    CACHE_DELAY = 4,

    RETRY_COUNT = 3,
    RETRY_DELAY = 3,

    DATA_SCOPE = "global",

    VERSION_LIST_PAGE_SIZE = 0,
}

local ERROR = {
    NON_TABLE_DATASTORE_VALUE = "",
    CORRUPTED_DATASTORE_METADATA = "",
}

local userDefinedMetadataTemplate: UserDefinedMetadata = {
    CreatedTime = -1,
    LoadedCount = 0,
    LoadedTime = 0,
    NewPendingUpdate = false,
    ActiveSession = nil,
}

local function verifyMetadata(data: UserDefinedMetadata): boolean
    local activeSession: ProfileSessionInfo? = data.ActiveSession
    if activeSession and (type(activeSession.PlaceId) ~= "number" or type(activeSession.JobId) ~= "string" or type(activeSession.StartedTime) ~= "number") then
        return false      
    elseif type(data.CreatedTime) ~= "number" or type(data.LoadedCount) ~= "number" or type(data.LoadedTime) ~= "number" or type(data.NewPendingUpdate) ~= "boolean" then
        return false
    end
    return true
end

-- TODO: remove this when luau typechecker unbreaks
local pcall = function<T..., U...>(fn: (T...) -> U..., ...: T...): (boolean, U...)
    return pcall(fn, ...)
end

local tlib do
    --[[
        takes a value and returns a deep clone of that value
        (table keys that are tables are also deepcloned)
    ]]
    local function deepclone<T>(x: T): T
        if type(x) == "table" then
            local copy: table = table.create(#x)
            for i: any, v: any in next, x do
                copy[deepclone(i)] = deepclone(v)
            end 
            return copy :: any
        else
            return x
        end    
    end

    --[[
        compares a target table against a template table (recursive)
        any target table field that is not of the same type as the 
        template table field is set to the template table value
        (if template table value is a table, the table is deepcloned)
        will ignore entries that the target contains that the template does not contain
    ]]
    local function apprise<T>(target: any, template: T)
        if type(target) ~= "table" or type(template) ~= "table" then error("Arguments must be tables", 2) end
        for i: any, template_value: any in next, template :: any do
            local target_value: any = target[i]
            local target_type: string = type(target_value)

            if target_type ~= type(template_value) then
                target[i] = deepclone(template_value)
            elseif target_type == "table" then
                apprise(target_value, template_value)     
            end
        end
    end

    -- clears the target table and moves the contents from the template table into the target table
    local function move(target: any, template: any)
        if type(target) ~= "table" or type(template) ~= "table" then error("Arguments must be tables", 2) end
        table.clear(target)
        for i: any, v: any in next, template do
            target[i] = v
        end
    end

    local function hasTableKey(t: table): boolean
        for k, v in next, t do
            if type(k) == "table" then
                return true
            elseif type(v) == "table" and hasTableKey(v) == true then
                return true
            end
        end
        return false
    end

    tlib = table.freeze {
        deepclone = deepclone,
        apprise = apprise,
        move = move,
        hasTableKey = hasTableKey
    }
end

local MemberAccessType = table.freeze {
    -- will error when attempting to modify a member
    ReadOnly = function(class: table, index: string)
        error(string.format("Attempt to modify a read-only property %s", index), 2)
    end;

    -- will error when a nil value is referenced
    Strict = function(class: table, index: string)
        error(string.format("%s is not a valid member of %s", index, class.__type), 2)
    end;
}

-- RDL::ScriptSignal v1.0.0
local RDLScriptSignal = {} do
    type Array<T> = {[number]: T}
    type EventHandler<T...> = (T...) -> ()
    type ScriptSignal<T...> = RDLScriptSignal<T...>

    -- using arrays to reduce memory usage
    local NEXT = 1 -- connection objects double as linked lists, signal object references head of list
    local CALLBACK = 2

    type ScriptConnection = RDLScriptConnection; local Connection = {} do
        Connection.__metatable = "Locked"
        Connection.__index = Connection

        function Connection.IsConnected(self: ScriptConnection): boolean
            return self[CALLBACK] and true or false
        end

        --  removal handled in ScriptSignal::Fire
        function Connection.Disconnect(self: ScriptConnection)
            self[CALLBACK] = nil
        end

        function Connection:__tostring()
            return "ScriptSignal"
        end
    end

    -- free looped runner
    local freerunner: thread?

    -- event handler takes ownership of the runner thread and returns ownership when complete
    local function runEventHandler<T...>(fn: EventHandler<T...>, ...: T...)
        local runner: thread = freerunner :: thread
        freerunner = nil
        fn(...)
        freerunner = runner
    end

    -- looped event handler runner
    local function newrunner<T...>(fn: EventHandler<T...>, ...: T...)
        runEventHandler(fn, ...)
        repeat until runEventHandler( coroutine.yield() )
    end

    local Signal = {__metatable = "Locked"}
    Signal.__index = Signal

    function RDLScriptSignal.new<T...>(): RDLScriptSignal<T...>
        return setmetatable({}, Signal) :: any
    end

    function Signal.Connect<T...>(self: ScriptSignal<T...>, fn: EventHandler<T...>): ScriptConnection
        if type(fn) ~= "function" then
            error(string.format("Invalid argument #1 to \"ScriptSignal::Connect\" (function expected, got %s)", type(fn)), 2)
        end

        local connection: ScriptConnection = setmetatable({self[NEXT], fn}, Connection) :: any
        self[NEXT] = connection -- insert connection as head of list

        return connection
    end

    --[[
    function Signal:ConnectParallel();
    ]]

    function Signal.Wait<T...>(self: ScriptSignal<T...>): T...
        local current: thread = coroutine.running()
        local c: ScriptConnection; c = self:Connect(function(...: T...)
            c:Disconnect()
            local success: boolean, error_msg: string? = coroutine.resume(current, ...)
            if success == false then error(error_msg, 0) end
        end)
        return coroutine.yield()
    end

    function Signal._Fire<T...>(self: ScriptSignal<T...>, ...: T...)
        local prev_connection: ScriptConnection = self :: any
        local connection: ScriptConnection? = self[NEXT]
        while connection ~= nil do
            local callback: EventHandler<T...>? = connection[CALLBACK]
            if callback == nil then
                prev_connection[NEXT] = connection[NEXT] -- remove current connection from list
            else
                if freerunner == nil then freerunner = coroutine.create(newrunner) end
                local success: boolean, error_msg: string? = coroutine.resume(freerunner :: thread, callback, ...)
                if success == false then error(error_msg, 2) end
            end
            prev_connection = connection
            connection = connection[NEXT]
        end
    end

    function Signal.DisconnectAll<T...>(self: ScriptSignal<T...>)
        self[NEXT] = nil
    end

    function Signal:__tostring()
        return "RDLScriptSignal"
    end

    table.freeze(RDLScriptSignal)
end

-- error message, profile store, profile key
local serviceDebugSignal: RDLScriptSignal<string> = RDLScriptSignal.new()
local serviceErrorSignal: RDLScriptSignal<string, string, string> = RDLScriptSignal.new()

-- functions for debug logging
local service = {
    log = function<T...>(msg: string, ...: T...)
        serviceDebugSignal:_Fire(string.format(msg, ...))
    end;
    
    error = function<T...>(msg: string, profileId: string, profileStoreId: string, ...: T...)
        serviceErrorSignal:_Fire(string.format(msg, ...), profileId, profileStoreId)
    end;
}

-- wraps in a coroutine as to not disturb the calling thread
local function async<T..., U...>(fn: (T...) -> U..., ...: T...)
    local success: boolean, msg: string = coroutine.resume( coroutine.create(fn), ... )
    if success == false then error(msg, 2) end
end

-- retry protected call, automatically retries function call if it errors
local function rpcall<T..., U...>(fn: (T...) -> (U...), ...: T...): (boolean, ...any)
    local tuple
    for i = 1, SETTINGS.RETRY_COUNT do
        tuple = { pcall(fn, ...) }
        if tuple[1] == true then
            return true, select(2, unpack(tuple))
        else
            task.wait(SETTINGS.RETRY_DELAY)
        end
    end

    return false, select(2, unpack(tuple))
end

-- returns internal reference id for `loadedProfiles` given the profile name and profilestore name
local function toInternalRef(profileId: string, storeName: string): string
    return "__"..storeName.."__"..profileId
end

local loadedProfiles: Map<string, Profile> = {}

------------------------------------------------------------------------
-- Cross-server coms
------------------------------------------------------------------------

type RemoteUnlockRequest = {
    ProfileRef: string;
    JobId: string;
}

local function handleRemoteUnlock(msg: {Data: RemoteUnlockRequest, Sent: number})
    if msg.Data.JobId == JOB_ID then
        local profile: Profile? = loadedProfiles[msg.Data.ProfileRef]
        if profile ~= nil then
            profile:Free()
        end
    end
end

MessagingService:SubscribeAsync(SETTINGS.REMOTE_UNLOCK_TOPIC, handleRemoteUnlock)

local function attemptRemoteUnlockAsync(profileRef: string, jobId: string)
    MessagingService:PublishAsync(SETTINGS.REMOTE_UNLOCK_TOPIC, {ProfileRef = profileRef, JobId = jobId} :: RemoteUnlockRequest)
end

------------------------------------------------------------------------
-- Profile Class
------------------------------------------------------------------------

local ProfileSessionInfo do
    ProfileSessionInfo = {__type = "ProfileSessionInfo"}
    ProfileSessionInfo.__index = MemberAccessType.Strict

    function ProfileSessionInfo.new(): ProfileSessionInfo
        return table.freeze(setmetatable({
            JobId = JOB_ID,
            PlaceId = PLACE_ID,
            StartedTime = os.time()
        }, ProfileSessionInfo)) :: any
    end

    function ProfileSessionInfo.init(t: {JobId: string, PlaceId: number, StartedTime: number}): ProfileSessionInfo
        return table.freeze(setmetatable(t, ProfileSessionInfo)) :: any
    end
    
    setmetatable(ProfileSessionInfo, {__index = MemberAccessType.Strict, __newindex = MemberAccessType.Strict})

    table.freeze(ProfileSessionInfo)
end

local ProfileInfo do
    ProfileInfo = {__type = "ProfileInfo"}
    ProfileInfo.__index = ProfileInfo

    function ProfileInfo._Split(self: _ProfileInfo): (Array<number>, UserDefinedMetadata)
        return self.UserIds, {
            CreatedTime = self.CreatedTime,
            LoadedCount = self.LoadedCount,
            LoadedTime = self.LoadedTime,
            NewPendingUpdate = self.NewPendingUpdate,
            ActiveSession = self.ActiveSession
        }
    end

    function ProfileInfo._Clone(self: _ProfileInfo): ProfileInfo
        local clone: typeof(self) = table.clone(self)
        clone.UserIds = table.freeze( table.clone(clone.UserIds) )
        return table.freeze(clone)
    end

    function ProfileInfo.new(keyInfo: DataStoreKeyInfo): ProfileInfo
        local userDef: UserDefinedMetadata = keyInfo:GetMetadata()
        local self: _ProfileInfo = setmetatable({
                CreatedTime = userDef.CreatedTime,
                LoadedCount = userDef.LoadedCount,
                LoadedTime = userDef.LoadedTime,
                NewPendingUpdate = userDef.NewPendingUpdate,
                ActiveSession = userDef.ActiveSession,

                KeyCreatedTime = keyInfo.CreatedTime,
                UpdatedTime = keyInfo.UpdatedTime,
                Version = keyInfo.Version,
                UserIds = keyInfo:GetUserIds()
            }, ProfileInfo) :: any
        return self
    end

    setmetatable(ProfileInfo, {
        __newindex = MemberAccessType.Strict,
        __index = function(self, index: any)
            return if index == "ActiveSession" then nil else error(string.format("%s is not a valid member of %s", index, self.__type), 2)
        end,
    })

    table.freeze(ProfileInfo)
end

local Profile do
    Profile = {__type = "Profile"}
    Profile.__index = Profile

    -- TODO: change to __newindex magic if frozen table rfc is fully implemented
    local pendingUpdateHandlers = {} :: Map<_Profile<any, any>, (any) -> ()>

    function Profile._GetPendingUpdateHandler<T, U>(self: _Profile<T, U>): ((U) -> ())?
        return pendingUpdateHandlers[self] or function() end
    end

    function Profile._Remove<T, U>(self: _Profile<T, U>)
        loadedProfiles[toInternalRef(self.Id, self._ProfileStore.Name)] = nil
        self.Removed:_Fire()
    end

    function Profile._UpdateAsync<T, U>(self: _Profile<T, U>, optional: MetadataTransform?)
        if self:IsLoaded() == false then error("Attempt to update an unloaded profile", 2) end

        local success: boolean, data: ProfileData<T, U>?|string, keyInfo: DataStoreKeyInfo
        = self._ProfileStore:_UpdateAsync(self.Id, function(cloudData: ProfileData<T, U>, cloudKeyInfo: DataStoreKeyInfo)
            if cloudData == nil then return end

            local cloudMetadata: UserDefinedMetadata = cloudKeyInfo:GetMetadata()
            if verifyMetadata(cloudMetadata) == false then
                service.error(self.Id, self._ProfileStore.Name, ERROR.CORRUPTED_DATASTORE_METADATA)
                return
            end

            -- check for active session change
            local cloudActiveSession: ProfileSessionInfo? = cloudMetadata.ActiveSession
            if cloudActiveSession == nil or cloudActiveSession.JobId ~= JOB_ID or cloudActiveSession.PlaceId ~= PLACE_ID then -- TODO: is place id check necessary?
                service.error("active session has changed", self.Id, self._ProfileStore.Name)
                return
            end

            cloudMetadata.LoadedTime += os.time() - cloudKeyInfo.UpdatedTime
            if optional then optional(cloudMetadata) end

            -- if optional transform removed active session
            -- (do not handle pending updates when freeing)
            if cloudMetadata.NewPendingUpdate == true and cloudMetadata.ActiveSession ~= nil then
                local handler: DataTransform<U>? = self:_GetPendingUpdateHandler()
                if handler then
                    handler(cloudData[BUFFER] :: U)
                    cloudMetadata.NewPendingUpdate = false
                end
            end
            
            cloudData[DATA] = self.Data -- cloudData.PendingUpdate was modified, so set cloudData.Data then return that
            return cloudData, self._Metadata.UserIds, cloudMetadata
        end)

        if success == false then -- UpdateAsync call errored in some way
            service.error(data :: string, self.Id, self._ProfileStore.Name)
            return
        end

        if data == nil then -- UpdateAsync call was aborted
            self:_Remove() -- if no key info exists then the update was manually aborted
            return
        end

        -- reflect state of buffer in the datastore
        tlib.move(self._BufferData, (data :: any)[BUFFER])
        -- reflect state of metadata in the datastore
        local metadataUpdated: UserDefinedMetadata = keyInfo:GetMetadata()
        local metadata: _ProfileInfo = self._Metadata
        metadata.LoadedTime = metadataUpdated.LoadedTime
        metadata.NewPendingUpdate = metadataUpdated.NewPendingUpdate
        metadata.ActiveSession = metadataUpdated.ActiveSession
        metadata.UpdatedTime = keyInfo.UpdatedTime
        metadata.Version = keyInfo.Version
    end

    function Profile.new<T, U>(id: string, data: ProfileData<T, U>, keyInfo: DataStoreKeyInfo, store: ProfileStore<T, U>): Profile<T, U>
        local self: _Profile<T, U> = setmetatable({}, Profile) :: any
        self._Metadata = ProfileInfo.new(keyInfo) :: _ProfileInfo
        self._ProfileStore = store :: _ProfileStore<T, U>
        self._BufferData = data[BUFFER] :: U

        self.Id = id
        self.Data = data[DATA] :: T
        self.Removed = RDLScriptSignal.new()

        return table.freeze(self)
    end

    function Profile.OnPendingUpdate<T, U>(self: _Profile<T, U>, handler: (U) -> ())
        pendingUpdateHandlers[self] = handler
    end

    function Profile.GetInfo<T, U>(self: _Profile<T, U>): ProfileInfo
        return self._Metadata:_Clone()
    end

    function Profile.Update<T, U>(self: _Profile<T, U>, _optional: MetadataTransform?)
        if not self:IsLoaded() then error("Attempted to update an unloaded profile", 2) end
        async(Profile._UpdateAsync, self, _optional)
    end

    function Profile.Free<T, U>(self: _Profile<T, U>)
        if not self:IsLoaded() then return error("Attempt to free an unloaded profile", 2) end
        service.log("Freeing profile")
        async(function()
            --self.Freeing:_Fire()
            self:_UpdateAsync(function(metadata: UserDefinedMetadata)
                metadata.ActiveSession = nil
                service.log("Profile freed")
            end)
            self:_Remove()
        end)
    end

    function Profile:AddUserId(id: number)
        local userIds: Array<number> = self._Metadata.UserIds
        if not table.find(userIds, id) then table.insert(userIds, id) end
    end

    function Profile:RemoveUserId(id: number)
        local userIds: Array<number> = self._Metadata.UserIds
        local i: number? = table.find(userIds, id)
        if i then table.remove(userIds, i) end
    end

    function Profile.IsLoaded<T, U>(self: _Profile<T, U>): boolean
        return loadedProfiles[toInternalRef(self.Id, self._ProfileStore.Name)] and true or false
    end

    function Profile.__tostring(): string
        return "Profile"
    end

    setmetatable(Profile, {__index = MemberAccessType.Strict, __newindex = MemberAccessType.Strict})

    table.freeze(Profile)
end

------------------------------------------------------------------------
-- ProfileStore Class
------------------------------------------------------------------------

local ProfileStore do
    ProfileStore = {}
    ProfileStore.__index = ProfileStore

    local ProfileVersionList do
        ProfileVersionList = {}
        ProfileVersionList.__index = ProfileVersionList

        function ProfileVersionList.new<T, U>(id: string, pages: DataStoreVersionPages, profileStore: ProfileStore<T, U>): _ProfileVersionList<T, U>
            local self: _ProfileVersionList<T, U> = setmetatable({}, ProfileVersionList) :: any
            self._Id = id
            self._DataStoreVersionPages = pages
            self._ProfileStore = profileStore :: _ProfileStore<T, U>
            self._CurrentPage = pages:GetCurrentPage()
            self._CurrentPagePosition = 1
            self.Index = 1
            return self
        end

        function ProfileVersionList.NextAsync<T, U>(self: _ProfileVersionList<T, U>): (Profile<T, U>?, string?)
            local versionInfo: DataStoreObjectVersionInfo? = self._CurrentPage[self._CurrentPagePosition]

            if versionInfo == nil then
                if self._DataStoreVersionPages.IsFinished == true then return nil, nil end
                local success: boolean, err: string? = pcall(self._DataStoreVersionPages.AdvanceToNextPageAsync, self._DataStoreVersionPages)
                if success == false then return nil, err end
                self._CurrentPage = self._DataStoreVersionPages:GetCurrentPage()
                self._CurrentPagePosition = 1
                versionInfo = self._CurrentPage[1]
            end
    
            local profile: Profile<T, U>?, err: string? = self._ProfileStore:ViewAsync(self._Id, (versionInfo :: DataStoreObjectVersionInfo).Version)
            if err == nil then -- dont increment unless the profile was successfully retrieved
                self._CurrentPagePosition += 1
                self.Index += 1
            end

            return profile, err
        end

        function ProfileVersionList.__iter<T, U>(self: _ProfileVersionList<T, U>)
            return next, self._CurrentPage, nil
        end

        function ProfileVersionList.__tostring(): string
            return "ProfileVersionList"
        end

        setmetatable(ProfileVersionList, {__index = MemberAccessType.Strict, __newindex = MemberAccessType.Strict})

        table.freeze(ProfileVersionList)
    end

    --[[
        this function takes the current (ProfileData?, DataStoreKeyInfo?) and returns the profile's components: (Data, UserIds, UserDefinedMetaData)
        handles the case where no data exists or if the profile was only partially initialized from `ProfileStore:PendingUpdateAsync()`.
        if no data or game data exists, will set `CreatedTime` to `os.time()` and `NewPendingUpdate` to `true` and return empty tables for ProfileData and UserIds to be apprised later
    ]]
    function ProfileStore._ProcessProfileData<T, U>(self: _ProfileStore<T, U>, data: ProfileData<T, U>?, keyInfo: DataStoreKeyInfo): (ProfileData<T, U>, Array<number>, UserDefinedMetadata)
        -- TODO: revise this method
        if data == nil or keyInfo:GetMetadata().CreatedTime == -1 then
            local newData: ProfileData<T, U> = {tlib.deepclone(self._DataTemplate), data and data[BUFFER] or tlib.deepclone(self._BufferTemplate)}
            local newMetadata: UserDefinedMetadata = tlib.deepclone(userDefinedMetadataTemplate)
            newMetadata.NewPendingUpdate = data and keyInfo:GetMetadata().CreatedTime == -1 and true or false
            newMetadata.CreatedTime = os.time()
            return newData, {}, newMetadata
        else
            return data, keyInfo:GetUserIds(), keyInfo:GetMetadata()
        end
    end

    function ProfileStore._UpdateAsync<T, U>(self: _ProfileStore<T, U>, id: string, updateHandler: UpdateHandler<T, U>): (boolean, ProfileData<T, U>|string, DataStoreKeyInfo?)
        return (rpcall :: any)(self._DataStore.UpdateAsync, self._DataStore, id, updateHandler) -- TODO: resolve type error
    end

    -- TODO: inspect typechecker behaviour when bufferTemplate arg is omitted.
    function ProfileStore.new<T, U>(name: string, dataTemplate: T, bufferTemplate: U): ProfileStore<T, U>
        if type(dataTemplate) ~= "table" then error("Data template must be a table", 2) end
        if type(bufferTemplate) ~= "table" then error("Buffer template must be a table", 2) end

        local self: _ProfileStore<T, U> = setmetatable({}, ProfileStore) :: any
        self._DataStore = DataStoreService:GetDataStore(name, SETTINGS.DATA_SCOPE)
        self._DataTemplate = dataTemplate
        self._BufferTemplate = bufferTemplate
        self.Name = name
        return self
    end

    function ProfileStore.LoadAsync<T, U>(self: _ProfileStore<T, U>, id: string, lockHandler: LockHandler?, _forceload: boolean?): (Profile<T, U>?, string?)
        local lockHandlerAction: boolean, targetJobId: string;
        local success: boolean, data: ProfileData<T, U>?|string, keyInfo: DataStoreKeyInfo? = self:_UpdateAsync(id, function(cloudData: ProfileData<T, U>?, cloudKeyInfo: DataStoreKeyInfo?)
            if cloudData and type(cloudData) ~= "table" then
                service.error("non table data", id, self.Name)
                cloudData = {}
            end

            local data: ProfileData<T, U>, userIds: Array<number>, userMetadata: UserDefinedMetadata = self:_ProcessProfileData(cloudData, cloudKeyInfo)

            if verifyMetadata(userMetadata) == false then
                service.error(ERROR.CORRUPTED_DATASTORE_METADATA, id, self.Name)
                data, userIds, userMetadata = self:_ProcessProfileData(nil, nil)
            end
    
            local activeSessionData: ProfileSessionInfo? = userMetadata.ActiveSession and table.freeze(userMetadata.ActiveSession) or nil
            if activeSessionData == nil or _forceload == true then
                --if _forceload == true then warn("Forceloading...") end
                tlib.apprise(data[DATA], self._DataTemplate)
                tlib.apprise(data[BUFFER], self._BufferTemplate)
                tlib.apprise(userMetadata, userDefinedMetadataTemplate)
                userMetadata.LoadedCount += 1
                userMetadata.ActiveSession = ProfileSessionInfo.new()
                
                return data, userIds, userMetadata
            else
                lockHandlerAction = lockHandler and lockHandler(activeSessionData) or false
                targetJobId = activeSessionData.JobId
                return nil
            end
        end)

        if success == false then -- if datastore fail
            service.error("ProfileStore could not load profile: "..data::any, self.Name, id)
            return nil, data :: string
        end

        if data == nil then -- locked profile
            if lockHandlerAction == true then
                attemptRemoteUnlockAsync(toInternalRef(id, self.Name), targetJobId)
                task.wait(SETTINGS.SET_DELAY) -- wait to prevent request queuing
                return self:LoadAsync(id, lockHandler, true) -- forceload
            else
                return nil, "could not ret" -- fail to retrieve profile
            end
        end

        local profile: Profile<T, U> = Profile.new(id, data :: ProfileData<T, U>, keyInfo :: DataStoreKeyInfo, self)

        loadedProfiles[toInternalRef(id, self.Name)] = profile

        return profile
    end

    function ProfileStore.PendingUpdateAsync<T, U>(self: _ProfileStore<T, U>, id: string, transform: (data: U) -> ()): (boolean, string?)
        local success: boolean, data: ProfileData<T, U>?|string = self:_UpdateAsync(id, function(cloudData: ProfileData<T, U>, cloudKeyInfo: DataStoreKeyInfo?)
            local userIds: Array<number>, userMetadata: UserDefinedMetadata;
            if cloudKeyInfo == nil then
                cloudData = {{}, {}} :: any
                userIds = {}
                userMetadata = {} :: UserDefinedMetadata
            else
                userIds = cloudKeyInfo:GetUserIds()
                userMetadata = cloudKeyInfo:GetMetadata()
            end
            
            tlib.apprise(userMetadata, userDefinedMetadataTemplate)
            tlib.apprise(cloudData[BUFFER], self._BufferTemplate)
            transform(cloudData[BUFFER] :: U)
            userMetadata.NewPendingUpdate = true

            return cloudData, userIds, userMetadata
        end)

        if success == false then
            service.error(data :: string, id, self.Name)
            return false, data :: string
        end

        return true, nil
    end

    function ProfileStore.EditAsync<T, U>(self: _ProfileStore<T, U>, id: string, transform: DataTransform<T>): (Profile<T, U>?, string?)
        local success: boolean, data: ProfileData<T, U>?|string, keyinfo: DataStoreKeyInfo? = self:_UpdateAsync(id, function(cloudData: ProfileData<T, U>?, cloudKeyInfo: DataStoreKeyInfo?)
            local data: ProfileData<T, U>, userIds: Array<number>, userMetadata: UserDefinedMetadata = self:_ProcessProfileData(cloudData, cloudKeyInfo)

            if userMetadata.ActiveSession ~= nil then
                service.error("Cannot edit an active profile!", id, self.Name)
                warn("CANNOT EDIT ACTIVE PROFILE")
                return nil
            end

            tlib.apprise(data[DATA], self._DataTemplate)
            tlib.apprise(userMetadata, userDefinedMetadataTemplate)
            transform(data[DATA] :: T)

            return data, userIds, userMetadata
        end)
        
        if success == false then 
            service.error("Error while editing profile", id, self.Name)
            return nil, data :: string
        end

        if data then
            return Profile.new(id, data :: ProfileData<T, U>, keyinfo :: DataStoreKeyInfo, self), nil
        else
            return nil, "profile was loaded"
        end
    end
    
    function ProfileStore.ViewAsync<T, U>(self: _ProfileStore<T, U>, id: string, version: string?): (Profile<T, U>?, string?)
        local ds: DataStore = self._DataStore
        local success: boolean, data: ProfileData<T, U>?|string, keyInfo: DataStoreKeyInfo
        if version then
            success, data, keyInfo = pcall(ds.GetVersionAsync, ds, id, version)
        else
            success, data, keyInfo = pcall(ds.GetAsync, ds, id)
        end
        
        if success == false then
            service.error(data :: string, id, self.Name)
            return nil, data :: string
        end

        if data == nil or keyInfo:GetMetadata().CreatedTime == -1 then -- no profile game data exists
            return nil, nil
        end

        local profile: Profile<T, U> = Profile.new(id, data :: ProfileData<T, U>, keyInfo, self)
        table.freeze(profile.Data :: any)
        return profile
    end

    function ProfileStore.OverwriteAsync<T, U>(self: _ProfileStore<T, U>, id: string, profile: Profile<T, U>): (Profile<T, U>?, string?)
        local oldData: ProfileData<T, U>?, oldKeyInfo: DataStoreKeyInfo;
        local success: boolean, data: ProfileData<T, U>?|string = self:_UpdateAsync(id, function(cloudData: ProfileData<T, U>?, cloudKeyInfo: DataStoreKeyInfo)
            oldData, oldKeyInfo = cloudData, cloudKeyInfo;

            local profileInfo: _ProfileInfo = profile:GetInfo() :: _ProfileInfo
            local userIds: Array<number>, userMetadata: UserDefinedMetadata = profileInfo:_Split()
            userMetadata.ActiveSession = nil

            return {profile.Data, (profile :: _Profile<T, U>)._BufferData} :: ProfileData<T, U>, userIds, userMetadata
        end)

        if success == false then
            service.error("ProfileStore could not overwrite profile", id, self.Name)
            return nil, data :: string
        end

        if oldData == nil then
            return nil, nil
        else
            return Profile.new(id, oldData, oldKeyInfo, self), nil
        end
    end

    function ProfileStore.WipeAsync<T, U>(self: _ProfileStore<T, U>, id: string): (Profile<T, U>?, string?)
        local success: boolean, data: ProfileData<T, U>?|string, keyInfo: DataStoreKeyInfo = rpcall(self._DataStore.RemoveAsync, self._DataStore, id)
        if success == false then
            service.error("ProfileStore could not wipe profile", id, self.Name)
            return nil, data :: string
        end

        if data == nil then
            return nil, nil
        else
            return Profile.new(id, data :: ProfileData<T, U>, keyInfo, self)
        end
    end

    function ProfileStore.ListVersionsAsync<T, U>(self: _ProfileStore<T, U>, id: string, sortDir: Enum.SortDirection, timeMin: number, timeMax: number): (ProfileVersionList<T, U>?, string?)
        local success: boolean, data: DataStoreVersionPages?|string = pcall(self._DataStore.ListVersionsAsync, self._DataStore, id, sortDir, timeMin, timeMax, SETTINGS.VERSION_LIST_PAGE_SIZE)

        if success == false then
            service.error("ProfileStore could not retrieve versions for profile", id, self.Name)
            return nil, data :: string
        end

        return ProfileVersionList.new(id, data :: DataStoreVersionPages, self)
    end

    function ProfileStore.__tostring(): string
        return "ProfileStore"
    end

    setmetatable(ProfileStore, {__index = MemberAccessType.Strict, __newindex = MemberAccessType.Strict})

    table.freeze(ProfileStore)
end

------------------------------------------------------------------------
-- ProfileStoreService Class
------------------------------------------------------------------------

local ProfileStoreServiceProxy: ProfileStoreService = newproxy(true) do
    local ProfileStoreService = getmetatable(ProfileStoreServiceProxy :: any)
    ProfileStoreService.__index = ProfileStoreService
    ProfileStoreService.__newindex = ProfileStoreService

    ProfileStoreService.AutosaveEnabled = true
    ProfileStoreService.AutomaticRetry = true

    ProfileStoreService.ServiceDebug = serviceDebugSignal
    ProfileStoreService.ServiceError = serviceErrorSignal

    function ProfileStoreService:GetProfileStore<T, U>(name: string, dataTemplate: T, bufferTemplate: U?): ProfileStore<T, U>
        if type(dataTemplate) ~= "table" then error("Data template must be a table", 2) end
        if bufferTemplate and type(bufferTemplate) ~= "table" then error("Buffer template must be a table", 2) end
        if tlib.hasTableKey(dataTemplate :: any) or tlib.hasTableKey(bufferTemplate :: any) then error("Templates cannot have table key", 2) end
        return ProfileStore.new(name, dataTemplate, bufferTemplate or {} :: any)
    end

    function ProfileStoreService.__tostring(): string
        return "ProfileStoreService"
    end

    do
        local elapsed: number = 0
        game:GetService("RunService").Heartbeat:Connect(function(dt: number)
            elapsed += dt
            while elapsed >= SETTINGS.AUTOSAVE_INTERVAL do
                elapsed -= SETTINGS.AUTOSAVE_INTERVAL
    
                if ProfileStoreServiceProxy.AutosaveEnabled == false then return end
    
                for id: string, profile: Profile<any, any> in next, loadedProfiles do
                    (profile :: _Profile<any, any>):_UpdateAsync()
                    task.wait()
                end
            end
        end)
    end

    setmetatable(ProfileStoreService, {__index = MemberAccessType.Strict, __newindex = MemberAccessType.Strict})
end

return ProfileStoreServiceProxy