# ProfileStoreService

ProfileStoreService encapsulates DataStoreService, providing a more intuitive and safer way of handling data.

<br/>

## Properties

```c#
RDLScriptSignal ProfileStoreService.ServiceError <string, errorMsg, string profileId, string profileStoreName>
```
Returns a script signal that fires when an error occurs in any of this service's methods.
#

<br/>

## Methods

```c#
ProfileStore<T, U> ProfileStoreService:GetProfileStore<Data, Buffer> (string name, T dataTemplate, U bufferTemplate)
```
Returns a ProfileStore instance with the given name and data templates.
#