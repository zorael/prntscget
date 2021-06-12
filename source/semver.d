/++
    SemVer information about the current release.

    Contains only definitions, no code. Helps importing projects tell what
    features are available.
 +/
module prntscget.semver;


/// SemVer versioning of this build.
enum PrntscgetSemVer
{
    majorVersion = 0,  /// SemVer major version of the program.
    minorVersion = 1,  /// SemVer minor version of the program.
    patchVersion = 1,  /// SemVer patch version of the program.
}


/// Pre-release SemVer subversion of this build.
enum PrntscgetSemVerPrerelease = string.init;
