# ProfileStore

Profilestores expose methods for managing profiles.

<br/>

## Properties

```ts
string ProfileStore.Name
```
The name of the profile store.
#

<br/>

## Methods

```ts
Profile?, string? ProfileStore:LoadAsync (string id, function? lockHandler)
```
Loads the profile for a given id and session locks it. 

The method takes an optional function to handle a potential session lock.
If an existing session lock is found, the lock handler will be invoked, passing a `ProfileSessionInfo` representing the active session as an argument.
The lock handler must return either `true` or `false`.

A `ProfileSessionInfo` has 3 properties:
```ts
string JobId
int PlaceId
int StartedTime
```

If `true` is returned, `ProfileStoreService` will attempt to remotely free the profile, whether that is successful or not, the profile will have its active session forcefully overwritten and the profile returned.

If `false` is returned, the profile loading will be aborted and `nil` will be returned.
#

```ts
Profile?, string? ProfileStore:ViewAsync (string id, string? version)
```
Returns a profile for a given id.
This profile cannot be edited.
#

```ts
Profile?, string? ProfileStore:WipeAsync (string id)
```
Wipes and removes a profile. Can still be retrieved with `ProfileStore:ListVersionsAsync()` if used within 30 days.
Returns the profile that was wiped.
#

```ts
Profile?, string? ProfileStore:OverwriteAsync (string id, Profile payload)
```
Overwrites the profile at a given id with the payload profile. Used in combination with `ProfileVersionList`s to rollback or to migrate data to another key.
Returns the old profile data.
#

```ts
ProfileVersionList?, string? ProfileStore:ListVersionsAsync (string id, Enum.SortDirection sortDirection = Ascending, int minTime = 0, int maxTime = 0)
```
Returns a `ProfileVersionList` object representing all of the id's profile versions within the given time period and sorting direction.
#

```ts
Profile?, string? ProfileStore:EditAsync(string id, function transform)
```
Remotely edits a profile.

When called, the target profile's `Profile.Data` field will be passed to the transform function. Any changes made to this table is saved and applied to the target profile.

If successful, the updated profile is returned.
> ⚠️ The transform function cannot yield.

> ⚠️ Using this on loaded profiles will abort the update and return nil.
#

```ts
boolean, string? ProfileStore:PendingUpdateAsync (string id, function transform)
```
Adds data to a pending state, awaiting settlement for the next time the target profile is loaded and updated.

When called, the target profile's current pending update state is passed to the transform function. Any changes made to this table is saved and applied to the target profile.

A boolean indicating success is returned.

This function can be used on profiles regardless of if they are loaded or not, and even non-existent profiles.

> ⚠️ The transform function cannot yield.
#