# Profile

Profile class which represents data associated with a particular datastore entry.

<br/>

## Properties

```ts
string Profile.Id
```
The id associated with the profile.
#

```ts
table Profile.Data
```
The data associated with the profile.

This table is always updated to follow the same structure as the `dataTemplate` argument given to `ProfileStoreService:GetProfileStore()`.
#

```ts
RDLScriptSignal Profile.Removed
```
A `RDLScriptSignal` that fires when the profile has been unloaded and removed.
#

<br/>

## Methods

```ts
void Profile:Update ()
```
Saves the profile's data to its ProfileStore and resolves any pending updates.
#

```ts
void Profile:Free ()
```
Updates the profile and safely unloads and removes it from the session.
> This will internally call `Profile:Update()`.
#

```ts
ProfileInfo Profile:GetInfo ()
```
Returns a `ProfileInfo` instance describing metadata for the profile.
#

```ts
bool Profile:IsLoaded ()
```
Indicates if `ProfileStoreService` is keeping track of the profile when loaded using `ProfileStore:LoadAsync`.
#

```ts
void Profile:OnPendingUpdate(function handler)
```
Assigns a function to be called when a new pending update is received.

This function is given the current state of the pending update as an argument.
Here it is expected to make the appropriate changes to `Profile.Data` while setting the pending update state back to its default values.

Any changes made to the pending update state will be saved.
The pending update table updated to follow the same structure as the `bufferTemplate` argument given to `ProfileStoreService:GetProfileStore()`.
> ⚠️ The handler function cannot yield.
#

```ts
void Profile:AddUserId (number id)
```
Associates a given user id with the profile for GDPR purposes.
#

```ts
void Profile:RemoveUserId (number id)
```
Removes a given id from the profile.

Does nothing if the given user id isn't already associated with the profile.
#