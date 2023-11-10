# opaqueify

Greater use of Opaque types (in preparation for SE0335/Swift 6)

Stop press: [It's been announced](https://forums.swift.org/t/progress-toward-the-swift-6-language-mode/68315) SE0335 will not be included in
Swift 6 and the "elision" to existentials will not be removed
for now so the urgency behind this project has rather abated.

I've changed the source to introduce the `some` keyword mainly 
which should provide a minor speed improvement for some projects
for which it may still be useful. It's probably still worth 
running processing over your Package to realise much of the 
performance motivation behind SE0335 and see how you go..

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
performance benefit to be had through increased use of `some` for
procedure arguments as they are generally the bulk of declarations.

Your milage may vary as this is still a change to your source
so you will likely have to pick though a handful of errors
when you next try to compile but the hope is this package will
save you the bulk of the typing necessary to make a conversion.
You may then want to take the migration to opaque types further.

```
Usage is: 
/path/to/executable </path/to/Package.swift> [/path/to/recent/Xcode15.app]
```
This project is an experiment on a "best effort"
basis but hopefully it should save you `some` typing.

The project now contains an app target "Unbreak" which you can
run to invoke the script binary for you. Open your package's
Package.swift and press the "Prepare for Swift 6" button.

The project has been extended to support Xcode .xcproject files
instead of just Swift packages. Testing with NetNewsWire has
shown your millage may vary quite a bit but the recipe I found
works best is to delete the derived data for the project, close
and re-open it and build it then run this program specifying the 
full path to the project file and the path to an Xcode 15+ that
supports the option `-enable-upcoming-feature ExistentialAny`.
