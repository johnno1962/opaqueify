# opaqueify

Greater use of Opaque types (in preparation for SE0335/Swift 6)

This project creates an executable that can be used to prepare
sources for Swift 6 where most references to protocols need
to be prefixed with with `any` or `some`. This is been discussed
at length on the [Swift Evolution forums](https://forums.swift.org/t/pitch-elide-some-in-swift-6/63737/68)
and this project will modify the source of a swift package to
add these explicit notations essentially using the following rule:

```
not storage and only procedure arguments of a simple bare protocol type 
(no containers or closures) are elided to some, for all other references 
the any prefix will be added, including for those of system protocols.
```
This is a fairly conservative rule that should realise much of any
perform benefit to be had through increased use of `some` for
procedure arguments as they are generally the bulk of declarations.

Your milage may vary as this is still a change to your source
so you will likely have to pick though a handful of errors
when you next try to compile but the hope is this package will
save you the bulk of the typing necessary to make a conversion.
You may then want to take the migration to opaque types further.

```
Usage is: 
/path/to/executable </path/to/Package.swift> [/path/to/recent/Xcode.app]
```
This project is an experiment on a "best effort"
basis but hopefully it should save you `some` typing.

The project has been extended to support Xcode .xcproject files
instead of just Swift packages. Testing with NetNewsWire has
shown your millage may vary quite a bit but the recipe I found
works best is to delete the derived data for the project, close
and re-open it and build it then run this program specifying the 
full path to the project file and the path to an Xcode 15+ that
supports the option `-enable-upcoming-feature ExistentialAny`.
