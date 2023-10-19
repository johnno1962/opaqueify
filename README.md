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

Your milage may very much vary as this is still a change to your
code so you will likely have to pick though a handful of errors
when you next try to compile but the hope is this package will
save you the bulk of the typing necessary to make a conversion.
You may want to then take the migration to opaque types further.

```
Usage is: /path/to/executable </path/to/project's/Package.swift>
```
This project is very much an experiement on a "best effort"
basis but hopefully it should save you some time.
