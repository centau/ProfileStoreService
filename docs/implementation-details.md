# Implementation Details

ProfileStoreService was designed with having a flexible yet intuitive and fool-proof API in mind.

This document keeps track of the details and thought process behind certain implementations and design.

<br/>

# Profile Data Structure

Each profile is contained within a single datastore entry like so:

```lua
[
    {}, -- Data
    {}  -- Buffer
]
```

Profile metadata is saved using the new metadata feature of DataStore 2.0.

- `Data` is accessed through the `Profile.Data` field.
- `Buffer` is not directly accessible to the programmer.
- Metadata can be accessed through a read-only `ProfileInfo` instance using `Profile:GetInfo()`.

Both `Data` and `Buffer` must be tables. Shape is decided by the user.

A profile's metadata is represented by a `ProfileInfo` instance which contains the following properties:

```ts
// ProfileStoreService defined properties
CreatedTime: number // The time the profile was first created. Persists after an overwrite
LoadCount: number // The amount of times a profile was successfully loaded through LoadAsync
LoadedTime: number // The total time in seconds the profile has been loaded for altogether
NewPendingUpdate: boolean // If a new pending update is awaiting
ActiveSession: ProfileSessionInfo? // Info on the profile's active session if any

// DataStoreService defined properties
KeyCreatedTime: number // DataStore key creation time
UpdatedTime: number // The last time the profile was updated
Version: string // DataStore key version
UserIds: Array<number> // Array of associated user ids
```

> TODO: As of now the `Data` and `Pending` templates must be followed strictly, allow key values to be of mixed type?

> TODO: Allow table keys in templates?

<br/>

# Profile Update

Updating a profile is processing of syncing its current data with its datastore.

The following process occurs during a profile update:

1. Invoke UpdateAsync.
2. Check `NewPendingUpdate` property.
    - If `true` then invoke `Profile.OnPendingUpdate`, passing the `Buffer` table as the only argument.
    - If `false` then continue.
3. Save current state of `Profile.Data`, current state of the `Buffer` table passed as an argument and save updated metadata (`LoadedTime` and `NewPendingUpdate`).

`Profile:Update()` can only be done on *loaded* profiles.

`Profile:Update()` is ran asynchronously in a separate coroutine for ease of use. Nothing is returned.
As for error handling, it is not intended for the programmer to implement any fallbacks with this method, as in the majority of cases should an error occur, there would be nothing that could be done. An error will however still fire `ProfileStoreService.ServiceError` for logging purposes.

When a profile is updated, its current active session is compared to the active session saved to the datastore. If they differ then the update is aborted and the profile is removed. This is to cover an edge-case scenario where a profile has been forceloaded onto another server and the original server failing to respond, overwriting the current session lock.

<br/>

# ProfileStore LoadAsync

Loading a profile is the processing of retrieving its data and locking it so that it cannot be edited from other servers. This allows the active server to cache the profile's data to be edited freely as there is no concern of other servers writing to the profile's data and causing conflicts.

> TODO: what to do if a player loads a profile that somehow has a session lock already for the session they are joining

> TODO: when UpdateAsync is first called multiple times on a non existent profile, the transform function passed will not be re-invoked to ensure that the latest data is being operated on. Investigate if this could cause an issue.

`LoadAsync` employs a technique known as *session locking* paired with `UpdateAsync` to ensure that only one instance of the profile can be loaded at a given time.

The profile's active session data is stored within its metadata and checked whenever a profile is loaded.

Should an active session exist when the loading of a profile is attempted, ProfileStoreService will attempt to resolve this through the use of a lock handler (optional secondary parameter of `LoadAsync`, the lock handler receives a single argument, the profile's active session, which the programmer can use to determine whether to unlock the profile or not). If `false` is returned then the profile loading will be aborted, returning nil. If `true` is returned then the following process occurs:

1. `UpdateAsync` call finishes.
2. The locking server is told to free the profile through `MessagingService`.
3. Yield for a few seconds to prevent datastore request queuing and give the locking server time to potentially free the profile.
4. Invoke `UpdateAsync` again, attempting to load profile.
5. If the session lock is now removed, load the profile as normal.
    If the session lock still persists, forceload the profile by apply a new session lock on top of it, overwriting the previous session lock.

In the case of `5`, where the profile is forceloaded, if for some reason the original locking server was still active, the next time it attempts to update the profile, it will see that its current session lock differs to the session lock stored in the datastore, abort the update and remove the profile. This will result in dataloss, although this situation should never arise.

`ProfileService` by loleris employs 4 options a lock handler can take:
1. `Repeat`
2. `Cancel`
3. `ForceLoad`
4. `Steal`

In `ProfileStoreService` a lock handler only has 2 options; return `true` (forceload), and return `false` (abort).

Returning `true` is a combination of `Repeat`, `ForceLoad` and `Steal` from `ProfileService`.
When designing `ProfileStoreService`, no reason was seen to have them as distinct actions.

Known causes for encountering an existing session lock when using `LoadAsync`:
1. An active server crashes, leaving a dead session lock.
2. An attempt to load a profile was made while a profile is still loaded.

> TODO: All of the above cases can be solved through forceloading. Is there a case where distinct lock handler actions seen in `ProfileService` is needed?

<br/>

# ProfileStore EditAsync

The purpose of `ProfileStore:EditAsync()` is to provide an easy way to edit the data of unloaded profiles. Without this method the programmer would have to manually edit the datastore key or load then free a profile just to make a change.

In the case where the programmer wants to use ProfileStoreService features and have a profile that may be read and wrote to and from multiple servers, this method would allow them to do so. This would be useful for things such as in-game groups/organisations where actions from players across servers will update group data, such as promotions/some collective currrency. This would otherwise be painful to do using `ProfileStore:LoadAsync()`

Using `EditAsync` on a new key will automatically initialize a profile just like `LoadAsync`. `EditAsync` also returns the current value stored in the datastore to avoid having to invoke `ViewAsync` after. This way the programmer may never have to use `LoadAsync` on a profile and can manage it solely using `EditAsync`.

> TODO: Rename this to `UpdateAsync`? Conflicts with existing datastore names and may cause confusion as functionality is slightly different even though the name seems more appropriate than "EditAsync" in this case.

> TODO: way to edit the `ProfileInfo.UserIds` field.

<br/>

# Profile Remote Updating

Profiles need a way to be remotely updated from external servers to allow for things such as:
- Giving gifts
- Sending mail
- Sending currency
- etc

If other servers were to directly modify a profile's data, it would be too awkward to keep track of changes 
so that those changes can be handled appropriately; e.g. create a prompt when a gift is received.

So when other servers want to remote update a profile they must write to a buffer that the main server can read from and handle when appropriate.

The process of remotely updating a profile would look like:
1. call `ProfileStore::PendingUpdateAsync(id, function)`, this method will modify the `Buffer` field and set the profile's `NewPendingUpdate` metadata field to true.
3. Each time the profile is loaded, updated through an autosave, or `Profile:Update()`, it will check its `NewPendingUpdate` status in the datastore, if it is `true` then it is set to `false` and if a pending update handler was assigned, it will be called with the `Pending` table as an argument where it can then be modified.

The pending update data table will follow and automatically update using a template table just like `Profile.Data` does.

Profiles can still recieve remote updates before their creation.
The datastore will be created with the `Data` and `Buffer` field initialized to empty tables. The profile's metadata will be initialized based on the internal metadata template but with its `CreatedTime` property set to `-1` to indicate that the profile has never been properly instantiated.

> TODO: Use messaging service to propogate the update faster?

> TODO: Allow ViewAsync for partially instantiated profiles? how to define such behaviour?

> TODO: handle pending updates on profile free?

> TODO: Better method of update handling, current method is subject to unexpected behaviour given that `GlobalDataStore:UpdateAsync` transform functions may be called multiple times; unsafe to perform actions based on update data in these functions.

<br/>

# ProfileStore OverwriteAsync


The main purpose of `OverwriteAsync` is to rollback profile data.

Profile data, metadata and pending data are all overwritten.

If the payload profile has an active session, it is removed automatically to prevent an edge case scenario where data was rollbacked to an older version that was still in the same session as the current profile, causing ProfileStoreService to be unable to detect that the profile's data was rollbacked.

<br/>

# Exception Handling

    
`ProfileStoreService` attempts to save the programmer from having to implement their own exception handling. Although there are cases where the programmer needs to know if an operation was successful, such as in the case of using `ProfileStore:OverwriteAsync()` to rollback player data.

A syntax was needed where the programmer is not forced to write code that is not necessary for the purpose they want to achieve, should they not care about exceptions.

For example,
Loading a profile:
```lua
local profile: Profile? = ProfileStore:LoadAsync(id)

if profile == nil then
    player:Kick("Could not load profile")
end
```
Here, an exception occuring does not affect the operation of the code. If the profile successfully loads then continue, else kick the player.

A return type the same as `pcall` could be used to detect exceptions, but it would force the programmer to include code that is not necessary for its purpose.

```lua
-- redundant variable
local success: boolean, profile: Profile? = ProfileStore:LoadAsync(id)

if profile == nil then
    player:Kick("Could not load profile")
end
```

A return type the same as `loadstring` and `loadfile` seen in the lua standard library seems to be the most suitable for this purpose: 

`() -> (Profile, nil) | () -> (nil, string)` or just `() -> (Profile?, string?)`.

This allows the first example to work, while giving the programmer to ability to check if an exception has occured too.

```lua
local profile: Profile?, err: string? = ProfileStore:LoadAsync(id)

if profile == nil then
    player:Kick(err)
end
```

If a DataStoreService error occurs, the error message from that error will be returned with its error code included in the message, if a ProfileStoreService error occurs, an error message will be returned with no error code included.

In addition to this, `ProfileStoreService.ServiceError` is an event signal (mimics `RBXScriptSignal` and can be treated as one) that also fires with 3 arguments:
1. The error message
2. The profile ID
3. The profilestore name

This signal is intended for use in logging purposes.

<br/>

## Illegal State Handling
#

Illegal states are states that cannot occur naturally. They only occur from deliberate tampering such as editing the profile with external APIs or severe datastore failure.

Handled illegal states:
- Profile datastore data is a non-table value.
    - Error raised and profile data re-initialized, metadata untouched.
- Profile datastore metadata corrupted
    - Error raised and both profile data and metadata re-initialized.