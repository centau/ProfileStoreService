# ProfileVersionList

Represents a list of all versions for a given profile.

<br/>

## Properties

```c#
int ProfileVersionList.Index
```
The current position in the version list.
#

<br/>

## Methods

```c#
Profile?, string? ProfileVersionList:NextAsync ()
```
Returns the next profile version in the list. Returns nil if there are no more versions.
#

<br/>

## Iterators

```c#
for index: int, version: DataStoreObjectVersionInfo in ProfileVersionList do
```
When used as an iterator, the `ProfileVersionList` acts as an array of `DataStoreObjectVersionInfo`s that you can use the second argument of `ProfileStore:ViewAsync()` to check. This will always start at the beginning, regardless of `ProfileVersionList.Index`.
#
