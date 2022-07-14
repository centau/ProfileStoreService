# ProfileInfo

Represents a profile's metadata.
Retrieved through `Profile:GetInfo()`.

<br/>

## Properties

```ts
int ProfileInfo.CreatedTime
```
Time in seconds since unix epoch when the profile was created.
#

```ts
int ProfileInfo.LoadedCount
```
The amount of times the profile was successfully loaded through `ProfileStore:LoadAsync()`.
#

```ts
int ProfileInfo.LoadedTime
```
Time in seconds the profile has been loaded for.
#

```ts
bool ProfileInfo.NewPendingUpdate
```
Indicates if a new pending update is awaiting settlement after being created through `ProfileStore:PendingUpdateAsync()`.
#

```ts
ProfileSessionInfo? ProfileInfo.ActiveSession
```
A table holding information for the profile's active session, `nil` if no session exists.
#

```ts
int ProfileInfo.KeyCreatedTime
```
Time in seconds since unix epoch when the profile's key was created.
> In most cases will be the same as `ProfileInfo.CreatedTime`, may differ when `Profile:Store:OverwriteAsync` is used on a different key.
#

```ts
int ProfileInfo.UpdatedTime
```
Time in seconds since unix epoch when the profile was last updated.
#

```ts
string ProfileInfo.Version
```
Unique version id.
#

```ts
Array<number> ProfileInfo.UserIds
```
Array of user ids associated with the profile through `Profile:AddUserId()`.
#